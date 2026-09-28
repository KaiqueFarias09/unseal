import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('BookSession over the isolate transport', () {
    const fixture = 'test/resources/books/epub/elements-of-chemistry.epub';

    test('openFile exposes the header and loads content on demand', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      expect(session.isProgressive, isTrue);
      expect(session.book, isA<EpubBook>());
      expect(session.book.files.html, isEmpty);

      final first = session.book.readingOrder.first;
      final chapter = await session.loadResource(first.name);
      expect(chapter, isNotNull);
      expect(chapter!, isNotEmpty);

      final text = await session.loadDocumentText(first.name);
      expect(text, isNotNull);
    });

    test('bytes and file opens deliver identical content', () async {
      final bytes = File(fixture).readAsBytesSync();
      final fromFile = await BookSession.openFile(fixture);
      final fromBytes = await BookSession.open(bytes);
      addTearDown(fromFile.dispose);
      addTearDown(fromBytes.dispose);

      final path = fromFile.book.readingOrder.first.name;
      expect(await fromBytes.loadResource(path), await fromFile.loadResource(path));
      expect((fromBytes.book as EpubBook).spinePaths, (fromFile.book as EpubBook).spinePaths);
    });

    test('concurrent requests all complete', () async {
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      final paths = [for (final item in session.book.readingOrder.take(8)) item.name];
      final loaded = await Future.wait([for (final path in paths) session.loadResource(path)]);

      for (final bytes in loaded) {
        expect(bytes, isNotNull);
      }
    });

    test('cancelPending fails an in-flight request with the typed error', () async {
      final session = await BookSession.openFile('test/resources/books/epub/mahabharata.epub');
      addTearDown(session.dispose);

      // A whole-book search is the slowest op: safely in flight when the
      // cancel lands.
      final slow = session.search('xyzzy', maxMatches: 500);
      session.cancelPending();

      await expectLater(slow, throwsA(isA<SessionCancelledException>()));

      // New requests remain valid after a cancel.
      final after = await session.loadResource(session.book.readingOrder.first.name);
      expect(after, isNotNull);
    });

    test('dispose drains pending requests and fails new ones typed', () async {
      final session = await BookSession.openFile('test/resources/books/epub/mahabharata.epub');

      final pending = session.search('the', maxMatches: 5);
      session.dispose();

      await expectLater(pending, throwsA(isA<SessionClosedException>()));
      await expectLater(
        session.loadResource(session.book.readingOrder.first.name),
        throwsA(isA<SessionClosedException>()),
      );
    });

    test('a broken container surfaces the parse failure through the session', () async {
      final bytes = Uint8List.fromList(<int>[0x50, 0x4b, 0x03, 0x04, 9, 9, 9, 9]);

      await expectLater(BookSession.open(bytes), throwsA(isA<UnsealException>()));
    });
  });

  group('BookSession over comics', () {
    test('comic sessions list pages and materialize them on demand', () async {
      const fixture = 'test/resources/books/comic/halfpenny-surprise-1895.cbz';
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      final book = session.book as ComicBook;
      expect(book.pageCount, greaterThan(0));
      final page = await session.loadResource(book.pages.first.path);
      expect(page, isNotNull);
      expect(page, isNotEmpty);
    });

    test('CBR sessions open from bytes and files and load pages', () async {
      const fixture = 'test/resources/books/comic/synthetic-stored-pages.cbr';
      final bytes = File(fixture).readAsBytesSync();
      final fromBytes = await BookSession.open(bytes);
      addTearDown(fromBytes.dispose);
      final fromFile = await BookSession.openFile(fixture);
      addTearDown(fromFile.dispose);

      for (final session in [fromBytes, fromFile]) {
        final book = session.book as ComicBook;
        expect(book.format, BookFormat.cbr);
        expect(book.pageCount, greaterThan(0));
        expect(await session.loadResource(book.pages.first.path), isNotNull);
      }
      expect(
        (fromBytes.book as ComicBook).pages.first.path,
        (fromFile.book as ComicBook).pages.first.path,
      );
    });
  });

  group('BookSession container range ops', () {
    test('byteLength and loadBytesRange serve clamped raw slices', () async {
      const epubFixture = 'test/resources/books/epub/elements-of-chemistry.epub';
      const cbrFixture = 'test/resources/books/comic/synthetic-stored-pages.cbr';

      for (final fixture in [epubFixture, cbrFixture]) {
        final bytes = File(fixture).readAsBytesSync();
        final session = await BookSession.openFile(fixture);
        addTearDown(session.dispose);

        expect(session.byteLength, bytes.length, reason: fixture);
        expect(await session.loadBytesRange(0, 16), bytes.sublist(0, 16), reason: fixture);
        expect(
          await session.loadBytesRange(bytes.length - 5, 100),
          bytes.sublist(bytes.length - 5),
          reason: 'EOF clamp of $fixture',
        );
      }
    });

    test('invalid ranges cross the isolate as RangeError', () async {
      const fixture = 'test/resources/books/comic/synthetic-stored-pages.cbr';
      final session = await BookSession.openFile(fixture);
      addTearDown(session.dispose);

      await expectLater(session.loadBytesRange(-1, 4), throwsA(isA<RangeError>()));
      await expectLater(session.loadBytesRange(0, -4), throwsA(isA<RangeError>()));
      await expectLater(
        session.loadBytesRange(session.byteLength + 1, 4),
        throwsA(isA<RangeError>()),
      );
    });

    test('sessions opened together stay isolated', () async {
      const epub = 'test/resources/books/epub/elements-of-chemistry.epub';
      const cbz = 'test/resources/books/comic/halfpenny-surprise-1895.cbz';
      const cbr = 'test/resources/books/comic/synthetic-stored-pages.cbr';

      final sessions = await Future.wait([
        BookSession.openFile(epub),
        BookSession.openFile(cbz),
        BookSession.openFile(cbr),
      ]);
      addTearDown(sessions[0].dispose);
      addTearDown(sessions[1].dispose);
      addTearDown(sessions[2].dispose);

      // Interleave one load per session, then retire the CBR session:
      // the other two keep serving.
      final epubPath = (sessions[0].book as EpubBook).readingOrder.first.name;
      final cbzPath = (sessions[1].book as ComicBook).pages.first.path;
      final cbrPath = (sessions[2].book as ComicBook).pages.first.path;
      expect(await sessions[0].loadResource(epubPath), isNotNull);
      expect(await sessions[2].loadResource(cbrPath), isNotNull);
      expect(await sessions[1].loadResource(cbzPath), isNotNull);

      sessions[2].dispose();
      await expectLater(sessions[2].loadResource(cbrPath), throwsA(isA<SessionClosedException>()));
      expect(await sessions[0].loadResource(epubPath), isNotNull);
      expect(await sessions[1].loadResource(cbzPath), isNotNull);
    });
  });

  test('unsupported formats provide the typed fallback signal for byte and file opens', () async {
    const fixtures = <String>['test/resources/books/txt/synthetic.txt'];

    for (final fixture in fixtures) {
      final bytes = File(fixture).readAsBytesSync();
      await expectLater(
        BookSession.open(bytes),
        throwsA(isA<SessionUnsupportedFormatException>()),
        reason: 'byte open of $fixture',
      );
      await expectLater(
        BookSession.openFile(fixture),
        throwsA(isA<SessionUnsupportedFormatException>()),
        reason: 'file open of $fixture',
      );
    }
  });
}
