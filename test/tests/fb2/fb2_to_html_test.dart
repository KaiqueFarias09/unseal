import 'package:e_livre/src/features/fb2/utils/fb2_to_html.dart';
import 'package:test/test.dart';
import 'package:xml/xml.dart';

void main() {
  Fb2Bodies convertBodiesFrom(
    final String xml, [
    final Map<String, String> binaries = const {},
  ]) {
    final root = XmlDocument.parse(
      '<FictionBook xmlns:l="http://www.w3.org/1999/xlink">$xml</FictionBook>',
    ).rootElement;
    return convertBodies(root.findElements('body').toList(), 'Book', binaries);
  }

  group('block elements', () {
    test('converts poems, stanzas and verse lines', () {
      final result = convertBodiesFrom('''
<body xmlns:l="http://www.w3.org/1999/xlink"><p>x</p>
<poem><stanza><v>line <strong>one</strong></v><v>line two</v><empty-line/></stanza></poem>
</body>''');
      final html = result.files['index.html'] ?? '';
      expect(html, contains('<blockquote class="poem">'));
      expect(html, contains('<p class="stanza">'));
      expect(html, contains('line <strong>one</strong>'));
      expect(html, contains('line two<br/>'));
      expect(html, contains('<br/>'));
    });

    test('converts subtitle, epigraph, cite and text-author', () {
      final result = convertBodiesFrom('''
<body>
<subtitle>a subtitle</subtitle>
<epigraph><p>motto</p></epigraph>
<cite><p>quoted</p></cite>
<p>body</p><text-author>the author</text-author>
</body>''');
      final html = result.files['index.html'] ?? '';
      expect(html, contains('<p class="subtitle"><b>a subtitle</b></p>'));
      expect(html, contains('<blockquote class="epigraph">'));
      expect(html, contains('<blockquote><p>quoted</p></blockquote>'));
      expect(html, contains('<p class="text-author">the author</p>'));
    });

    test('converts tables with cells and headers', () {
      // FB2 schema wraps cell content in block elements (<p>).
      final result = convertBodiesFrom('''
<body><table><tr><th><p>h</p></th><td><p>d</p></td></tr></table></body>''');
      final html = result.files['index.html'] ?? '';
      expect(
        html,
        contains('<table><tr><th><p>h</p></th><td><p>d</p></td></tr></table>'),
      );
    });

    test('keeps unknown leaf text and recurses unknown containers', () {
      final result = convertBodiesFrom('''
<body><custom>plain</custom><wrapper><p>inner</p></wrapper></body>''');
      final html = result.files['index.html'] ?? '';
      expect(html, contains('<p>plain</p>'));
      expect(html, contains('<p>inner</p>'));
    });

    test('style elements keep their inline content', () {
      final result = convertBodiesFrom(
        '<body><p>a <style>styled</style> b</p></body>',
      );
      expect(result.files['index.html'] ?? '', contains('a styled b'));
    });
  });

  group('inline elements', () {
    test('converts emphasis, strong, strikethrough, sub, sup and code', () {
      final result = convertBodiesFrom('''
<body><p>
<emphasis>e</emphasis><strong>s</strong><strikethrough>st</strikethrough>
<sub>sb</sub><sup>sp</sup><code>cd</code>
</p></body>''');
      final html = result.files['index.html'] ?? '';
      expect(html, contains('<em>e</em>'));
      expect(html, contains('<strong>s</strong>'));
      expect(html, contains('<s>st</s>'));
      expect(html, contains('<sub>sb</sub>'));
      expect(html, contains('<sup>sp</sup>'));
      expect(html, contains('<code>cd</code>'));
    });

    test('keeps CDATA sections as text', () {
      final result = convertBodiesFrom(
        '<body><p><![CDATA[raw <b> text]]></p></body>',
      );
      expect(result.files['index.html'] ?? '', contains('raw &lt;b&gt; text'));
    });

    test('escapes markup in text nodes', () {
      final result = convertBodiesFrom('<body><p>a &lt; b &amp; c</p></body>');
      expect(result.files['index.html'] ?? '', contains('a &lt; b &amp; c'));
    });
  });

  group('links', () {
    test('same-body anchors stay local', () {
      final result = convertBodiesFrom('''
<body><section id="s1"><title>One</title></section>
<p>see <a l:href="#s1">one</a></p></body>''');
      expect(result.files['index.html'] ?? '', contains('href="#s1"'));
    });

    test('cross-body anchors resolve to the target file', () {
      final result = convertBodiesFrom('''
<body><p>see <a l:href="#n1">note</a></p></body>
<body name="notes"><section id="n1"><title>Note</title></section></body>''');
      expect(
        result.files['index.html'] ?? '',
        contains('href="notes.html#n1"'),
      );
      expect(result.files['notes.html'], isNotNull);
    });

    test('missing targets fall back to a local anchor', () {
      final result = convertBodiesFrom(
        '<body><p><a l:href="#gone">x</a></p></body>',
      );
      expect(result.files['index.html'] ?? '', contains('href="#gone"'));
    });

    test('external hrefs pass through', () {
      final result = convertBodiesFrom(
        '<body><p><a l:href="https://example.com/a?b=1">site</a></p></body>',
      );
      expect(
        result.files['index.html'] ?? '',
        contains('href="https://example.com/a?b=1"'),
      );
    });

    test('links without href render as typed spans', () {
      final result = convertBodiesFrom(
        '<body><p><a type="note">x</a></p></body>',
      );
      expect(
        result.files['index.html'] ?? '',
        contains('<span class="fb2-a" data-type="note">x</span>'),
      );
    });
  });

  group('images', () {
    test('resolve binary references through the extension map', () {
      final result = convertBodiesFrom(
        '<body><p><image l:href="#cover.jpg"/></p></body>',
        {'cover.jpg': 'cover.jpg.jpg'},
      );
      expect(
        result.files['index.html'] ?? '',
        contains('<img src="cover.jpg.jpg" alt="cover.jpg"/>'),
      );
    });

    test('skip references without a binary target', () {
      final result = convertBodiesFrom(
        '<body><p><image l:href="cover.jpg"/><image l:href="#"/></p></body>',
      );
      expect(result.files['index.html'] ?? '', isNot(contains('<img')));
    });
  });

  group('navigation', () {
    test('builds nested nav points from section titles', () {
      final result = convertBodiesFrom('''
<body>
<section id="a"><title>Alpha</title>
  <section id="a1"><title>Alpha one</title><p>t</p></section>
  <section id="a2"><title>Alpha two</title><p>t</p></section>
</section>
<section id="b"><title>Beta</title><p>t</p></section>
</body>''');
      final points = result.navigation.navPoints;
      expect(points, hasLength(2));
      expect(points.first.label, 'Alpha');
      expect(points.first.content, 'index.html#a');
      expect(points.first.subNavPoints.map((final p) => p.label).toList(), [
        'Alpha one',
        'Alpha two',
      ]);
      expect(points.last.label, 'Beta');
    });

    test('generates ids for sections without one', () {
      final result = convertBodiesFrom(
        '<body><section><title>T</title><p>t</p></section></body>',
      );
      expect(result.navigation.navPoints.single.id, 'fb2-section-1');
    });

    test('titles anchor to their parent section id', () {
      final result = convertBodiesFrom(
        '<body><section id="s9"><title>T</title><p>t</p></section></body>',
      );
      expect(result.files['index.html'] ?? '', contains('<h3 id="title-s9"'));
    });

    test('notes bodies are excluded from the toc', () {
      final result = convertBodiesFrom('''
<body><section id="m"><title>Main</title></section></body>
<body name="notes"><section id="n"><title>Note</title></section></body>''');
      expect(result.navigation.navPoints.map((final p) => p.label), ['Main']);
    });
  });
}
