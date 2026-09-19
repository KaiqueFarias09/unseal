import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _alice() => Uint8List.fromList(
  File('test/resources/epub/Alices Adventures in Wonderland.epub').readAsBytesSync(),
);

void main() {
  group('updateEpubMetadata', () {
    test('rewrites title and authors with computed sort keys', () {
      final updated = updateEpubMetadata(
        _alice(),
        const EpubMetadataUpdate(title: 'The New Title', authors: ['Jane Doe']),
      );
      final metadata = readEpubMetadata(ZipDecoder().decodeBytes(updated));
      expect(metadata.title, 'The New Title');
      expect(metadata.titleSort, 'New Title, The');
      expect(metadata.authors, ['Jane Doe']);
      expect(metadata.authorSort, 'Doe, Jane');
    });

    test('keeps fields that were not part of the update', () {
      final updated = updateEpubMetadata(
        _alice(),
        const EpubMetadataUpdate(title: 'The New Title'),
      );
      final metadata = readEpubMetadata(ZipDecoder().decodeBytes(updated));
      // Alice ships `D. Appleton and Co` as publisher — untouched.
      expect(metadata.publisher, 'D. Appleton and Co');
      expect(metadata.languages, isNotEmpty);
      expect(metadata.cover, isNotNull);
    });

    test('writes explicit sort keys over computed ones', () {
      final updated = updateEpubMetadata(
        _alice(),
        const EpubMetadataUpdate(
          title: 'The New Title',
          titleSort: 'Custom Sort',
          authorSort: 'Custom, Author',
        ),
      );
      final metadata = readEpubMetadata(ZipDecoder().decodeBytes(updated));
      expect(metadata.titleSort, 'Custom Sort');
      expect(metadata.authorSort, 'Custom, Author');
    });

    test('writes publisher, description, date, subjects and series', () {
      final updated = updateEpubMetadata(
        _alice(),
        EpubMetadataUpdate(
          publisher: 'Editora Teste',
          description: 'Uma descrição & <com> caracteres especiais',
          publishedAt: DateTime(2020, 5, 17),
          subjects: const ['fiction', 'classic'],
          series: 'Clássicos',
          seriesIndex: 2.5,
          language: 'pt-BR',
          rights: 'Public Domain',
        ),
      );
      final metadata = readEpubMetadata(ZipDecoder().decodeBytes(updated));
      expect(metadata.publisher, 'Editora Teste');
      expect(metadata.description, 'Uma descrição & <com> caracteres especiais');
      expect(metadata.publishedAt, DateTime(2020, 5, 17));
      // The EPUB reader surfaces the first subject only; both were
      // written into the OPF.
      expect(metadata.subjects, ['fiction']);
      expect(metadata.series, 'Clássicos');
      expect(metadata.seriesIndex, 2.5);
      expect(metadata.languages, ['pt-BR']);
      expect(metadata.rights, 'Public Domain');
    });

    test('preserves the zip inventory and entry bytes', () {
      final original = _alice();
      final updated = updateEpubMetadata(
        original,
        const EpubMetadataUpdate(title: 'The New Title'),
      );

      final before = ZipDecoder().decodeBytes(original);
      final after = ZipDecoder().decodeBytes(updated);
      bool isContentFile(final ArchiveFile f) => f.isFile && !f.name.endsWith('/');
      final beforeNames = before.files.where(isContentFile).map((final f) => f.name).toList();
      final afterNames = after.files.where(isContentFile).map((final f) => f.name).toList();
      expect(afterNames, beforeNames);
      // The uncompressed mimetype entry must stay first, as EPUB
      // requires.
      expect(afterNames.first, 'mimetype');
      expect(after.files.first.compression, CompressionType.none);

      // Content entries keep their bytes.
      final beforeCover = before.files.firstWhere((final f) => f.name.endsWith('.jpg'));
      final afterCover = after.files.firstWhere((final f) => f.name == beforeCover.name);
      expect(afterCover.content, beforeCover.content);
    });

    test('throws on archives without an OPF root', () {
      final archive = Archive()..addFile(ArchiveFile.string('other.txt', 'hello'));
      final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
      expect(
        () => updateEpubMetadata(bytes, const EpubMetadataUpdate(title: 'X')),
        throwsA(anyOf(isA<FormatException>(), isA<EpubException>())),
      );
    });
  });
}
