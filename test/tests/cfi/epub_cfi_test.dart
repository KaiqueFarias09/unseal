import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('EpubCfi.parse', () {
    test('parses the canonical Moby Dick example from the spec', () {
      final cfi = EpubCfi.parse('epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)');
      expect(cfi.isRange, isFalse);
      expect(cfi.start.segments, hasLength(2));
      expect(cfi.start.segments[0].steps.map((final s) => s.index), [6, 4]);
      expect(cfi.start.segments[0].steps[1].assertion, 'chap01ref');
      expect(cfi.start.segments[1].steps.map((final s) => s.index), [4, 10, 3]);
      expect(cfi.start.segments[1].steps.map((final s) => s.assertion), ['body01', 'para05', null]);
      final last = cfi.start.segments[1].steps.last;
      expect(last.isText, isTrue);
      expect(last.charOffset, 10);
    });

    test('parses ranges', () {
      final cfi = EpubCfi.parse('epubcfi(/6/4!/4/2,/1:0,/3:15)');
      expect(cfi.isRange, isTrue);
      expect(cfi.start.segments, hasLength(2));
      expect(cfi.start.segments[0].steps.map((final s) => s.index), [6, 4]);
      expect(cfi.start.segments[1].steps.map((final s) => s.index), [4, 2]);
      expect(cfi.rangeStart!.segments.single.steps.single.index, 1);
      expect(cfi.rangeStart!.segments.single.steps.single.charOffset, 0);
      expect(cfi.rangeEnd!.segments.single.steps.single.index, 3);
      expect(cfi.rangeEnd!.segments.single.steps.single.charOffset, 15);
    });

    test('parses side bias inside assertions', () {
      final cfi = EpubCfi.parse('epubcfi(/6/4!/4/1:5[some text;s=b])');
      expect(cfi.start.segments[1].steps.last.assertion, 'some text');
      expect(cfi.start.segments[1].steps.last.side, 'b');
      expect(cfi.start.segments[1].steps.last.charOffset, 5);
      expect(cfi.encode(), 'epubcfi(/6/4!/4/1:5[some text;s=b])');
    });

    test('requires the EPUB CFI scheme wrapper', () {
      expect(() => EpubCfi.parse('/6/4!/4/1:1'), throwsFormatException);
    });

    test('rejects malformed CFIs', () {
      expect(() => EpubCfi.parse('epubcfi(/6/4'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4!)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4!/x)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4, /6/4)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/06/4)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4:1/2)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4[bad,assertion])'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4[bad^xescape])'), throwsFormatException);
    });

    test('rejects temporal and spatial terminators', () {
      expect(() => EpubCfi.parse('epubcfi(/6/4!/4/2~10.5)'), throwsFormatException);
      expect(() => EpubCfi.parse('epubcfi(/6/4!/4/2@10:20)'), throwsFormatException);
    });
  });

  group('EpubCfi.encode', () {
    test('round-trips through parse and encode', () {
      const canonical = 'epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)';
      expect(EpubCfi.parse(canonical).encode(), canonical);

      const range = 'epubcfi(/6/4!/4/2,/1:0,/3:15)';
      expect(EpubCfi.parse(range).encode(), range);
    });

    test('escapes every reserved assertion delimiter, including commas', () {
      final cfi = EpubCfi.simple(steps: [2], idAssertion: r'we^ird[id],value;');
      const encoded = r'epubcfi(/2[we^^ird^[id^]^,value^;])';
      expect(cfi.encode(), encoded);
      expect(EpubCfi.parse(encoded).idAssertion, r'we^ird[id],value;');
    });

    test('supports the spec range form with an empty start subpath', () {
      const encoded = 'epubcfi(/6/4!/4/2,,/1:2)';
      final cfi = EpubCfi.parse(encoded);
      expect(cfi.rangeStart!.segments, isEmpty);
      expect(cfi.encode(), encoded);
    });

    test('rejects side bias on ranges', () {
      expect(() => EpubCfi.parse('epubcfi(/6/4!/4/2,/1:0[;s=a],/3:2)'), throwsFormatException);
    });

    test('cannot represent a half-range', () {
      expect(
        () => EpubCfi(
          start: EpubCfiPath(
            segments: [
              EpubCfiSegment(steps: [EpubCfiStep(index: 2)]),
            ],
          ),
          rangeStart: EpubCfiPath(segments: const []),
        ),
        throwsArgumentError,
      );
    });
  });

  group('resolve and build on a real book', () {
    final book = parseEpubBook(
      File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
    );

    test('generates a CFI for a content offset and resolves it back', () {
      // Skip cover/title sections: pick the first one with real text.
      var sectionIndex = -1;
      var sectionPath = '';
      var text = '';
      for (var i = 0; i < book.readingOrder.length; i++) {
        final section = book.readingOrder[i];
        final file = book.files.html.firstWhere(
          (final f) => f.path == section.name,
          orElse: () => throw StateError('missing ${section.name}'),
        );
        if (file.plainText.length > 100) {
          sectionIndex = i;
          sectionPath = section.name;
          text = file.plainText;
          break;
        }
      }
      expect(sectionIndex, greaterThanOrEqualTo(0), reason: 'fixture too small for the test');

      for (final offset in [0, text.length ~/ 2, text.length - 1]) {
        final cfi = book.buildEpubCfi(contentIndex: sectionIndex, offsetInText: offset);
        final parsed = EpubCfi.parse(cfi);
        final location = book.resolveCfi(parsed);

        expect(location, isNotNull);
        expect(location!.contentIndex, sectionIndex);
        expect(location.contentPath, sectionPath);
        expect(location.charOffset, isNotNull);
        expect(location.textExcerpt, isNotNull);
      }
    });

    test('resolves hand-written CFIs into the right section', () {
      // /6/2 targets the first spine item; /4 targets its XHTML body.
      final location = book.resolveCfi(EpubCfi.parse('epubcfi(/6/2!/4)'));
      expect(location, isNotNull);
      expect(location!.contentIndex, 0);
      expect(location.charOffset, 0);
      expect(location.textExcerpt, isNotNull);
    });

    test('returns null for CFIs outside the book', () {
      expect(book.resolveCfi(EpubCfi.parse('epubcfi(/6/9999!/2)')), isNull);
    });

    test('does not reinterpret a local path as a complete book CFI', () {
      expect(book.resolveCfi(EpubCfi.parse('epubcfi(/4/2/1:0)')), isNull);
    });

    test('throws when building past the end of a section', () {
      expect(
        () => book.buildEpubCfi(contentIndex: 0, offsetInText: 1 << 20),
        throwsA(isA<RangeError>()),
      );
    });
  });
}
