import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Parity tests ported from the e_livre_viewer suite, originally
/// ported from calibre `src/pyj/read_book/test_cfi.pyj`
/// (cfi_escaping, cfi_roundtripping, cfi_with_range_wrappers).
const String page = '''
<html xmlns="http://www.w3.org/1999/xhtml">
  <head><title>t</title></head>
  <body>
    <p id="p1">alpha beta</p>
    <p id="p2">one <b>two</b> three</p>
    <p id="p3">calibre &amp; eLivre — quotes</p>
    <div id="wrap"><p id="p4">nested text here</p></div>
  </body>
</html>
''';

void main() {
  group('escaping (calibre cfi_escaping)', () {
    test('reserved characters survive a round trip', () {
      expect(unescapeFromCfi(escapeForCfi('^^')), '^^');
      expect(escapeForCfi(';'), '^;');
      expect(escapeForCfi('[]()'), r'^[^]^(^)');
    });

    test('simple CFI serialization escapes id assertions', () {
      final cfi = EpubCfi.simple(steps: [2, 4, 2], charOffset: 1, idAssertion: r'we^ird[id];');
      final serialized = cfi.encode();
      expect(serialized, r'epubcfi(/2/4/2:1[we^^ird^[id^]^;])');
      final parsed = EpubCfi.parse(serialized);
      expect(parsed.idAssertion, cfi.idAssertion);
      expect(parsed.steps, cfi.steps);
      expect(parsed.charOffset, cfi.charOffset);
      expect(parsed.encode(), serialized);
    });
  });

  group('EpubCfiDocument (calibre cfi_roundtripping)', () {
    final document = EpubCfiDocument.parse(page);

    test('encode from a character position and decode back', () {
      for (final needle in ['alpha beta', 'two', 'three', 'nested text here']) {
        final offset = document.indexOfText(needle)!;
        final cfi = document.cfiForOffset(offset);
        expect(document.offsetForCfi(cfi), offset, reason: needle);
      }
    });

    test('picks up the id assertion of the enclosing element', () {
      final cfi = document.cfiForOffset(document.indexOfText('alpha beta')!);
      expect(cfi.idAssertion, 'p1');
      final nested = document.cfiForOffset(document.indexOfText('nested text here')!);
      expect(nested.idAssertion, 'p4');
    });

    test('reaches positions through inline elements', () {
      final two = document.indexOfText('two')!;
      final cfi = document.cfiForOffset(two);
      expect(document.offsetForCfi(cfi), two);
      expect(cfi.idAssertion, 'p2');
    });

    test('decodes entities into the text space', () {
      final at = document.indexOfText('calibre & eLivre')!;
      final cfi = document.cfiForOffset(at);
      expect(document.offsetForCfi(cfi), at);
    });
  });

  group('EpubCfiDocument messy real-world text', () {
    // Regression: the Shakespeare complete-works edition carries a
    // Mobipocket artifact — escaped markup as literal text — and the
    // Dracula Oxford edition escapes a URL in a footnote. Decoding
    // `&lt;`/`&amp;` before the XML parse turned both into bogus tags
    // (XmlParserException), so those books silently lost CFI support.
    const pseudoMarkup =
        '<html><body><p>word &lt;&lt;span id="filepos0042723319"&gt; more</p></body></html>';
    const escapedUrl =
        '<html><body><p>collected at &lt;http://fleursdumal.org/poem/186&gt;. End</p></body></html>';

    test('escaped pseudo-markup stays text and matches documentText', () {
      final document = EpubCfiDocument.parse(pseudoMarkup);
      expect(document.text, contains('<<span id="filepos0042723319">'));
      expect(document.text, documentText(pseudoMarkup));
    });

    test('escaped URL parses and round-trips', () {
      final document = EpubCfiDocument.parse(escapedUrl);
      expect(document.text, contains('<http://fleursdumal.org/poem/186>'));
      final at = document.indexOfText('fleursdumal')!;
      expect(document.offsetForCfi(document.cfiForOffset(at)), at);
    });

    test('entities the XML parser cannot resolve still decode', () {
      const html = '<html><body><p>a&nbsp;b — done.</p></body></html>';
      final document = EpubCfiDocument.parse(html);
      expect(document.text, 'a\u00A0b — done.');
      expect(document.text, documentText(html));
    });

    test('offset-space parity on mixed predefined and named entities', () {
      const html =
          '<html><body><p>calibre &amp; eLivre &lt;always&gt;, '
          'say &quot;hi&quot;/&apos;bye&apos;&nbsp;– done.</p></body></html>';
      final document = EpubCfiDocument.parse(html);
      expect(document.text, documentText(html));
    });
  });

  group('EpubCfi.compare (calibre cfi_sort_key)', () {
    test('compares steps before offsets', () {
      final early = EpubCfi.simple(steps: [2, 4], charOffset: 100);
      final late = EpubCfi.simple(steps: [2, 6], charOffset: 0);
      expect(EpubCfi.compare(early, late), lessThan(0));
      expect(EpubCfi.compare(late, early), greaterThan(0));
    });

    test('same steps order by offset', () {
      final a = EpubCfi.simple(steps: [2, 4, 2], charOffset: 10);
      final b = EpubCfi.simple(steps: [2, 4, 2], charOffset: 20);
      expect(EpubCfi.compare(a, b), lessThan(0));
      expect(EpubCfi.compare(a, a), 0);
    });
  });
}
