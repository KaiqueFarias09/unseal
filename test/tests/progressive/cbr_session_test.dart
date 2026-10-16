import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/platform/io/zip_byte_source_io.dart';
import 'package:unseal/unseal.dart';

import '../../support/rar_fixtures.dart';

Uint8List _bytes(final String name) =>
    Uint8List.fromList(File('test/resources/$name').readAsBytesSync());

const storedCbr = 'books/comic/synthetic-stored-pages.cbr';
const method29Cbr = 'books/comic/american-beauty-trading-cards-1909.cbr';
const rar5CompressedCbr = 'books/comic/rar5/rar5-comic-utf8.cbr';

/// Opens the session for [bytes] only when the eager parse opens too,
/// asserting the same outcome class both ways — the open-time parity
/// contract for adversarial CBR bytes.
void _expectSessionMatchesEager(final Uint8List bytes) {
  Object? eagerOutcome;
  try {
    eagerOutcome = (Unseal.parse(bytes) as ComicBook).pageCount;
  } on UnsealException catch (error) {
    eagerOutcome = error;
  }

  try {
    final engine = SessionEngine.openBytes(bytes);
    addTearDown(engine.close);
    expect(eagerOutcome, isA<int>(), reason: 'session opened; the eager parse must open too');
    expect((engine.book as ComicBook).pageCount, eagerOutcome, reason: 'page count parity');
  } on UnsealException {
    expect(eagerOutcome, isA<UnsealException>(), reason: 'session failed typed; eager too');
  }
}

void main() {
  group('CBR session × eager parity', () {
    final fixtures = [storedCbr, method29Cbr, rar5CompressedCbr];

    for (final fixture in fixtures) {
      test('inventory, cover and per-page bytes match the eager parse: $fixture', () {
        final bytes = _bytes(fixture);
        final engine = SessionEngine.openBytes(bytes);
        addTearDown(engine.close);
        final header = engine.book as ComicBook;
        final full = Unseal.parse(bytes) as ComicBook;

        expect(header.format, BookFormat.cbr);
        expect(header.pageCount, full.pageCount, reason: 'page count');
        expect(
          [for (final page in header.pages) page.path],
          [for (final page in full.pages) page.path],
          reason: 'natural page order',
        );
        expect(
          [for (final page in header.pages) page.name],
          [for (final page in full.pages) page.name],
          reason: 'page names',
        );
        expect(header.readingDirection, full.readingDirection, reason: 'reading direction');
        for (final page in header.pages) {
          expect(page.content, isEmpty, reason: 'placeholder pages carry no bytes');
        }
        for (var i = 0; i < full.pages.length; i++) {
          expect(engine.resource(header.pages[i].path), full.pages[i].content, reason: 'page $i');
          expect(
            engine.resourceLength(header.pages[i].path),
            full.pages[i].content.length,
            reason: 'resource length of page $i',
          );
        }
        if (!header.cover.isEmpty) {
          expect(header.cover.content, full.cover.content, reason: 'cover bytes');
        }
        expect(engine.resource(full.cover.path), full.cover.content, reason: 'cover loadable');
      });
    }

    test('RAR 5 sessions keep ComicInfo metadata parity', () {
      final bytes = buildRar5Files({
        'ComicInfo.xml': comicInfoXml.codeUnits,
        'b.jpg': tinyJpegPage,
        'a.jpg': tinyJpegPage,
      });
      final engine = SessionEngine.openBytes(Uint8List.fromList(bytes));
      addTearDown(engine.close);
      final header = engine.book as ComicBook;
      final full = Unseal.parse(Uint8List.fromList(bytes)) as ComicBook;

      expect(header.format, BookFormat.cbr);
      expect(header.pageCount, full.pageCount);
      expect(
        [for (final page in header.pages) page.path],
        [for (final page in full.pages) page.path],
        reason: 'ComicInfo excluded from pages; natural order preserved',
      );
      expect(header.metadata.title, full.metadata.title);
      expect(header.readingDirection, full.readingDirection);
      expect(header.readingDirection, ComicReadingDirection.rightToLeft);
      expect(engine.resource('a.jpg'), tinyJpegPage);
    });

    test('RAR 5 compressed pages decode identically out of order and on reread', () {
      final bytes = _bytes(rar5CompressedCbr);
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final full = Unseal.parse(bytes) as ComicBook;
      final header = engine.book as ComicBook;
      expect(header.pageCount, full.pageCount, reason: 'UTF-8 fixture carries 2 image pages');

      // Out-of-order, then re-read: the same bytes every time.
      final order = [1, 0, 1, 0];
      for (final index in order) {
        expect(
          engine.resource(header.pages[index].path),
          full.pages[index].content,
          reason: 'page ${header.pages[index].path}',
        );
      }
    });

    test('two RAR 5 sessions keep their pages isolated', () {
      final bytes = _bytes(rar5CompressedCbr);
      final one = SessionEngine.openBytes(bytes);
      addTearDown(one.close);
      final two = SessionEngine.openBytes(bytes);
      addTearDown(two.close);

      final path = (one.book as ComicBook).pages.last.path;
      final first = one.resource(path);
      final second = two.resource(path);
      expect(first, second, reason: 'same bytes from both sessions');
      expect(first, (Unseal.parse(bytes) as ComicBook).pages.last.content);
    });

    test('method-29 pages load through the shared decoder', () {
      final bytes = _bytes(method29Cbr);
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);
      final header = engine.book as ComicBook;

      expect(header.pageCount, 24);
      for (final page in header.pages) {
        expect(engine.resource(page.path), isNotNull, reason: page.path);
      }
    });

    test('file-backed CBR sessions match the eager parse', () {
      final temp = Directory.systemTemp.createTempSync('unseal-cbr');
      addTearDown(() => temp.deleteSync(recursive: true));
      final path = '${temp.path}/book.cbr';
      File(path).writeAsBytesSync(_bytes(storedCbr));

      final engine = SessionEngine.openSource(FileZipByteSource.open(path));
      addTearDown(engine.close);
      final header = engine.book as ComicBook;
      final full = Unseal.parse(_bytes(storedCbr)) as ComicBook;

      expect(header.pageCount, full.pageCount);
      expect(
        [for (final page in header.pages) page.path],
        [for (final page in full.pages) page.path],
      );
      expect(engine.resource(header.pages.first.path), full.pages.first.content);
    });
  });

  group('CBR adversarial sessions', () {
    test('truncated mid-data matches the eager outcome', () {
      final full = buildRar4(['a.jpg', 'b.jpg']);
      // Truncate inside b.jpg's data block.
      _expectSessionMatchesEager(Uint8List.sublistView(full, 0, full.length - 11));
    });

    test('truncated mid-header matches the eager outcome', () {
      final full = buildRar4(['a.jpg', 'b.jpg']);
      // Cut into b.jpg's fixed header fields.
      _expectSessionMatchesEager(Uint8List.sublistView(full, 0, 60));
    });

    test('a huge declared unpacked size is a bomb rejection at open', () {
      final bomb = Uint8List.fromList(
        buildRar4Files({'a.jpg': tinyJpegPage}, declaredUnpackedSize: (512 << 20) + 1),
      );

      expect(
        () => SessionEngine.openBytes(bomb),
        throwsA(isA<InvalidBookException>()),
        reason: 'the container guard rejects before any payload is decoded',
      );
      expect(
        BookSession.open(bomb),
        throwsA(isA<InvalidBookException>()),
        reason: 'the public open crosses the isolate typed',
      );
    });

    test('solid stored entries still open, like the eager parse', () {
      final bytes = Uint8List.fromList(buildRar4(['a.jpg', 'b.jpg'], flags: 0x8000 | 0x0010));

      _expectSessionMatchesEager(bytes);
    });

    test('undecodable compressed entries fail the open typed, naming the entry', () {
      final bytes = Uint8List.fromList(buildRar4(['a.jpg'], method: 0x33));
      // Pinned eager parity: the whole parse throws ComicException.
      expect(() => Unseal.parse(bytes), throwsA(isA<ComicException>()));
      expect(
        () => SessionEngine.openBytes(bytes),
        throwsA(
          isA<ComicException>().having(
            (final error) => error.message,
            'message',
            contains('a.jpg'),
          ),
        ),
      );
    });

    test('RAR 5 compressed pages fail the open typed, like the eager parse', () {
      final bytes = Uint8List.fromList(buildRar5(['001.jpg'], method: 3));

      expect(() => Unseal.parse(bytes), throwsA(isA<ComicException>()));
      expect(() => SessionEngine.openBytes(bytes), throwsA(isA<ComicException>()));
    });

    test('not-a-RAR and empty bytes are typed rejections', () {
      // Printable garbage detects as txt: the session gate refuses it
      // typed instead of reaching the RAR reader.
      expect(
        () => SessionEngine.openBytes(Uint8List.fromList('NOTARAR!'.codeUnits)),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
      expect(() => SessionEngine.openBytes(Uint8List(0)), throwsA(isA<EmptyBytesException>()));
      expect(
        BookSession.open(Uint8List.fromList('NOTARAR!'.codeUnits)),
        throwsA(isA<SessionUnsupportedFormatException>()),
      );
    });

    test('no untyped errors leak through BookSession for hostile CBRs', () async {
      final hostile = <Uint8List>[
        Uint8List(0),
        Uint8List.fromList('NOTARAR!'.codeUnits),
        Uint8List.fromList(buildRar4(['a.jpg'], method: 0x33)),
        Uint8List.fromList(buildRar5(['001.jpg'], method: 3)),
        Uint8List.sublistView(buildRar4(['a.jpg']), 0, 9),
        Uint8List.fromList([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00, 0xFF, 0xFF]),
      ];

      for (final bytes in hostile) {
        await expectLater(
          BookSession.open(bytes),
          throwsA(isA<UnsealException>()),
          reason: 'hostile bytes of length ${bytes.length}',
        );
      }
    });
  });

  group('CBR cache policy', () {
    test('pages stay correct when the LRU evicts under a tiny budget', () {
      // Four ~380 KiB stored pages overflow the 1 MiB effective
      // minimum budget several times over.
      final bytes = Uint8List.fromList(
        buildRar4Files({
          'a.jpg': fatJpegPage(380 << 10),
          'b.jpg': fatJpegPage(380 << 10),
          'c.jpg': fatJpegPage(380 << 10),
          'd.jpg': fatJpegPage(380 << 10),
        }),
      );
      final full = Unseal.parse(bytes) as ComicBook;
      final engine = SessionEngine.openBytes(
        bytes,
        policy: const SessionPolicy(cacheBytes: 1 << 20),
      );
      addTearDown(engine.close);

      var loaded = 0;
      for (var pass = 0; pass < 2; pass++) {
        for (final page in full.pages) {
          expect(engine.resource(page.path), page.content, reason: '${page.path} pass $pass');
          loaded++;
        }
      }
      expect(loaded, 8, reason: 'every page reloaded exactly through the LRU');
    });
  });

  group('byteLength and loadBytesRange', () {
    test('the engine reports the container length and clamps slices', () {
      final bytes = _bytes(storedCbr);
      final engine = SessionEngine.openBytes(bytes);
      addTearDown(engine.close);

      expect(engine.byteLength, bytes.length);
      expect(engine.bytesRange(0, 16), bytes.sublist(0, 16), reason: 'normal slice');
      expect(
        engine.bytesRange(bytes.length - 5, 100),
        bytes.sublist(bytes.length - 5),
        reason: 'EOF-clamped slice',
      );
      expect(engine.bytesRange(bytes.length, 4), isEmpty, reason: 'empty tail slice');
      expect(
        engine.bytesRange(0, 1 << 30),
        bytes,
        reason: 'oversized slices clamp to the whole container',
      );
    });

    test('range caps honor the policy', () {
      final bytes = _bytes(method29Cbr);
      final engine = SessionEngine.openBytes(
        bytes,
        policy: const SessionPolicy(rangeMaxBytes: 1 << 16),
      );
      addTearDown(engine.close);

      expect(engine.bytesRange(0, 1 << 17).length, 1 << 16, reason: 'clamped to the policy cap');
    });

    test('invalid ranges throw RangeError', () {
      final engine = SessionEngine.openBytes(_bytes(storedCbr));
      addTearDown(engine.close);

      expect(() => engine.bytesRange(-1, 4), throwsA(isA<RangeError>()));
      expect(() => engine.bytesRange(0, -1), throwsA(isA<RangeError>()));
      expect(() => engine.bytesRange(_bytes(storedCbr).length + 1, 4), throwsA(isA<RangeError>()));
    });
  });

  group('CBR session lifecycle', () {
    test('cancelPending fails queued page loads typed and the session stays usable', () async {
      final session = await BookSession.openFile('test/resources/$method29Cbr');
      addTearDown(session.dispose);
      final paths = [for (final page in (session.book as ComicBook).pages) page.path];

      // Issue every page load in one synchronous block: the isolate
      // cannot answer before the cancel drains the queue.
      final loads = [for (final path in paths) session.loadResource(path)];
      session.cancelPending();

      for (final load in loads) {
        await expectLater(load, throwsA(isA<SessionCancelledException>()));
      }
      expect(await session.loadResource(paths.first), isNotNull, reason: 'still usable');
    });
  });
}
