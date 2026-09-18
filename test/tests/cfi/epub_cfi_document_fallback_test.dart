import 'package:e_livre/src/features/cfi/epub_cfi_document.dart';
import 'package:e_livre/src/foundation/text/canonical_document_text.dart';
import 'package:test/test.dart';

/// Tag-soup sections rejected by the strict XML parser fall back to an HTML5 parse using
/// `html5_parser`; the fallback tree must produce exactly the [DocumentTextScanner.scan] offset space.
void main() {
  // Every fixture below must parse and share the documentText space.
  group('EpubCfiDocument HTML5 fallback', () {
    const soups = <String, String>{
      'bare ampersand': '<html><body><p>AT&T and R&D; labs</p></body></html>',
      'stray less-than': '<html><body><p>3 < 4 and a < b, done.</p></body></html>',
      'unclosed void elements':
          '<html><body><p>one<br>two<img src="a.png">three<hr>four</p></body></html>',
      'mismatched close tags':
          '<html><body><p>alpha <our>beta</our> gamma</p><p>delta</p></body></html>',
      'named entities decode like documentText':
          '<html><body><p>caf&eacute; &nbsp; &mdash; end</p></body></html>',
      'xml five decode into text':
          '<html><body><p>see &lt;b&gt;bold&lt;/b&gt; &amp; quot&quot;ed&quot;</p></body></html>',
      'script and style skipped':
          '<html><body><style>p { color: red }</style><p>visible</p>'
          '<script>var x = "<p>not text</p>";</script></body></html>',
      'id assertion survives':
          '<html><body><p>intro</p><div id="chap"><p>target text here</p></div></body></html>',
      'numeric c1 control maps to replacement char':
          '<html><body><p>dash &#151; end &#x97;</p></body></html>',
      'malformed numeric refs stay literal':
          '<html><body><p>oops &#; and &#xZZ; done</p></body></html>',
    };

    for (final entry in soups.entries) {
      test('${entry.key}: parses and matches documentText', () {
        final document = EpubCfiDocument.parse(entry.value);
        expect(document.text, DocumentTextScanner(entry.value).scan());
      });
    }

    test('bare ampersand keeps both tokens', () {
      expect(EpubCfiDocument.parse(soups['bare ampersand']!).text, contains('AT&T and R&D; labs'));
    });

    test('named entities decode exactly like documentText', () {
      expect(
        EpubCfiDocument.parse(soups['named entities decode like documentText']!).text,
        'café \u00A0 \u2014 end',
      );
    });

    test('stray < agrees between the tree and documentText', () {
      // Both the HTML5 tokenizer and documentText keep '< ' as literal
      // text, so the CFI and search offset spaces stay aligned even in
      // tag-soup sections.
      const source = '<html><body><p>3 < 4 and a < b, done.</p></body></html>';
      expect(EpubCfiDocument.parse(source).text, '3 < 4 and a < b, done.');
    });

    test('escaped markup decodes to literal text, not elements', () {
      expect(
        EpubCfiDocument.parse(soups['xml five decode into text']!).text,
        'see <b>bold</b> & quot"ed"',
      );
    });

    test('script/style content never enters the text space', () {
      expect(EpubCfiDocument.parse(soups['script and style skipped']!).text, 'visible');
    });

    test('build/resolve roundtrip through the fallback tree', () {
      const source =
          '<html><body><p>first alpha</p><div id="mid"><p>second '
          'bravo charlie</p></div><p>third delta</p></body></html>';
      final document = EpubCfiDocument.parse(source);
      final at = document.text.indexOf('bravo');
      final cfi = document.cfiForOffset(at);
      expect(cfi.idAssertion, 'mid');
      expect(document.offsetForCfi(cfi), at);
    });

    test('well-formed documents keep taking the strict path', () {
      const source =
          '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
          '<p>clean &lt;em&gt;text&lt;/em&gt; here</p></body></html>';
      final document = EpubCfiDocument.parse(source);
      expect(document.text, 'clean <em>text</em> here');
      final cfi = document.cfiForOffset(2);
      expect(document.offsetForCfi(cfi), 2);
    });
  });
}
