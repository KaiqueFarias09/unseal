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
  });
}
