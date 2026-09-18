import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Regression tests for CFI escaping, document round-tripping, entity handling, and ordering.
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
  group('assertion escaping', () {
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

  group('EpubCfiDocument round-tripping', () {
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

    test('uses spec element indexes rather than counting whitespace nodes', () {
      final cfi = document.cfiForOffset(document.indexOfText('alpha beta')!);
      expect(cfi.steps, [4, 2, 1]);
      expect(cfi.encode(), startsWith('epubcfi(/4/2[p1]/1:'));
    });

    test('resolves a final element step to the start of its text', () {
      final secondParagraph = EpubCfi.parse('epubcfi(/4/4)');
      expect(document.offsetForCfi(secondParagraph), document.indexOfText('one'));
    });

    test('rejects character offsets beyond the addressed chunk', () {
      expect(document.offsetForCfi(EpubCfi.parse('epubcfi(/4/2/1:999)')), isNull);
    });

    test('uses ID assertions to correct a stale element index', () {
      final stale = EpubCfi.parse('epubcfi(/4/8[p1]/1:2)');
      expect(document.offsetForCfi(stale), document.indexOfText('alpha beta')! + 2);
    });

    test('decodes entities into the text space', () {
      final at = document.indexOfText('calibre & eLivre')!;
      final cfi = document.cfiForOffset(at);
      expect(document.offsetForCfi(cfi), at);
    });
  });

  group('EpubCfiDocument character-data chunks', () {
    test('comments do not split a character-data CFI step', () {
      final document = EpubCfiDocument.parse(
        '<html><head/><body><p id="p">ab<!-- ignored -->cd</p></body></html>',
      );
      final offset = document.indexOfText('cd')! + 1;
      final cfi = document.cfiForOffset(offset);

      expect(cfi.steps, [4, 2, 1]);
      expect(cfi.charOffset, 3);
      expect(document.offsetForCfi(cfi), offset);
    });

    test('validates requested document offsets', () {
      final document = EpubCfiDocument.parse('<html><body><p>x</p></body></html>');
      expect(() => document.cfiForOffset(-1), throwsRangeError);
      expect(() => document.cfiForOffset(2), throwsRangeError);
    });

    test('represents the only position in an empty body', () {
      final document = EpubCfiDocument.parse('<html><head/><body/></html>');
      final cfi = document.cfiForOffset(0);
      expect(cfi.encode(), 'epubcfi(/4)');
      expect(document.offsetForCfi(cfi), 0);
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
      expect(document.text, DocumentTextScanner(pseudoMarkup).scan());
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
      expect(document.text, DocumentTextScanner(html).scan());
    });

    test('offset-space parity on mixed predefined and named entities', () {
      const html =
          '<html><body><p>calibre &amp; eLivre &lt;always&gt;, '
          'say &quot;hi&quot;/&apos;bye&apos;&nbsp;– done.</p></body></html>';
      final document = EpubCfiDocument.parse(html);
      expect(document.text, DocumentTextScanner(html).scan());
    });
  });

  group('EpubCfi.compare', () {
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

    test('ranges compare by expanded start and then end locations', () {
      final early = EpubCfi.parse('epubcfi(/4/2,/1:1,/1:5)');
      final lateStart = EpubCfi.parse('epubcfi(/4/2,/1:2,/1:5)');
      final lateEnd = EpubCfi.parse('epubcfi(/4/2,/1:1,/1:6)');

      expect(EpubCfi.compare(early, lateStart), lessThan(0));
      expect(EpubCfi.compare(early, lateEnd), lessThan(0));
    });

    test('implicit and explicit zero text offsets compare equally', () {
      final implicit = EpubCfi.parse('epubcfi(/4/2/1)');
      final explicit = EpubCfi.parse('epubcfi(/4/2/1:0)');
      expect(EpubCfi.compare(implicit, explicit), 0);
    });
  });
}
