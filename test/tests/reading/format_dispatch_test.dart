import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:koni_archive/koni_archive.dart' as koni;
import 'package:test/test.dart';
import 'package:unseal/src/features/reading/book_dispatch.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('Unseal dispatches the new synchronous formats', () {
    final txt = Unseal.parse(Uint8List.fromList('A title\n\nBody'.codeUnits));
    final html = Unseal.parse(
      Uint8List.fromList('<!doctype html><html><head><title>HTML</title></head></html>'.codeUnits),
    );
    final txtz = Unseal.parse(_zip({'book.txt': 'TXTZ body'}));
    final htmlz = Unseal.parse(_zip({'index.html': '<title>HTMLZ</title>'}));
    final docx = Unseal.parse(_zip({'word/document.xml': _docxDocument}));
    final odt = Unseal.parse(_zip({'content.xml': _odtContent}));

    expect(txt.format, BookFormat.txt);
    expect(html.format, BookFormat.html);
    expect(txtz.format, BookFormat.txtz);
    expect(htmlz.format, BookFormat.htmlz);
    expect(docx.format, BookFormat.docx);
    expect(odt.format, BookFormat.odt);
    expect(Unseal.readMetadataSync(_zip({'content.xml': _odtContent})).format, BookFormat.odt);
  });

  test('Unseal keeps CB7 on its asynchronous path', () async {
    final sink = koni.BytesBuilderSink();
    final writer = koni.Archive.create(sink, format: const koni.SevenZWriteFormat());
    await writer.addBytes(koni.ArchiveEntrySpec(path: 'page1.png'), Uint8List.fromList(_png));
    await writer.close();
    await sink.close();

    final bytes = sink.takeBytes();
    final book = await Unseal.read(bytes);
    var executorCalled = false;
    final dispatched = await BookDispatch.openFromBytes(
      bytes,
      execute: (final _, final _) async {
        executorCalled = true;
        throw StateError('CB7 must not use the synchronous executor');
      },
    );
    final metadata = await BookDispatch.readMetadataFromBytes(
      bytes,
      execute: (final _, final _) async {
        executorCalled = true;
        throw StateError('CB7 metadata must not use the synchronous executor');
      },
    );

    expect(book.format, BookFormat.cb7);
    expect(dispatched.format, BookFormat.cb7);
    expect(metadata.format, BookFormat.cb7);
    expect(executorCalled, isFalse);
  });

  test('Unseal keeps CBC on its asynchronous path', () async {
    final nestedComic = _zipBytes({'page.png': _png});
    final bytes = _zipBytes({
      'comics.txt': utf8.encode('nested.cbz:Nested comic\n'),
      'nested.cbz': nestedComic,
    });
    var executorCalled = false;

    final book = await BookDispatch.openFromBytes(
      bytes,
      execute: (final _, final _) async {
        executorCalled = true;
        throw StateError('CBC must not use the synchronous executor');
      },
    );
    final metadata = await BookDispatch.readMetadataFromBytes(
      bytes,
      execute: (final _, final _) async {
        executorCalled = true;
        throw StateError('CBC metadata must not use the synchronous executor');
      },
    );

    expect(book.format, BookFormat.cbc);
    expect(metadata.format, BookFormat.cbc);
    expect(executorCalled, isFalse);
  });

  test('Reading dispatches synchronous work through the injected executor', () async {
    final bytes = Uint8List.fromList('A title\n\nBody'.codeUnits);
    var parseExecutions = 0;
    var metadataExecutions = 0;

    final book = await BookDispatch.openFromBytes(
      bytes,
      execute: (final parse, final source) async {
        parseExecutions++;
        expect(source, same(bytes));

        return parse();
      },
    );
    final metadata = await BookDispatch.readMetadataFromBytes(
      bytes,
      execute: (final read, final source) async {
        metadataExecutions++;
        expect(source, same(bytes));

        return read();
      },
    );

    expect(book.format, BookFormat.txt);
    expect(metadata.format, BookFormat.txt);
    expect(parseExecutions, 1);
    expect(metadataExecutions, 1);
  });
}

Uint8List _zip(final Map<String, String> entries) {
  return _zipBytes(entries.map((final key, final value) => MapEntry(key, utf8.encode(value))));
}

Uint8List _zipBytes(final Map<String, List<int>> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }

  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

const _docxDocument =
    '''<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:body><w:p><w:r><w:t>DOCX body</w:t></w:r></w:p><w:sectPr/></w:body>
</w:document>''';

const _odtContent = '''<office:document-content
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0"
    xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">
  <office:body><office:text><text:p>ODT body</text:p></office:text></office:body>
</office:document-content>''';

const List<int> _png = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
