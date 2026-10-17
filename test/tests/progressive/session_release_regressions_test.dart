import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;
import 'package:test/test.dart';
import 'package:unseal/src/features/mobi/header/mobi_header.dart';
import 'package:unseal/src/features/mobi/reader/mobi8_session_scan.dart';
import 'package:unseal/src/features/mobi/reader/mobi8_structure.dart';
import 'package:unseal/src/features/mobi/reader/mobi_text_store.dart';
import 'package:unseal/src/features/progressive/mobi_session_header.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _imageBook(final Uint8List image) => buildPdb('Images', [
  buildMobiRecord0(compressionType: 1, textRecordCount: 1, firstImageIndex: 2),
  Uint8List.fromList(utf8.encode('<html><body><p>hello</p><img recindex="1"/></body></html>')),
  image,
]);

final class _ObservedSource implements ZipByteSource {
  _ObservedSource(this.bytes);
  final Uint8List bytes;
  final List<(int, int)> reads = [];
  @override
  int get length => bytes.length;
  @override
  Uint8List read(final int offset, final int count) {
    reads.add((offset, count));
    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  void close() {}
}

Uint8List _flowsBook() {
  final main = '<html><body>body</body></html>';
  final first = 'a {color: blue;}/*${'x' * (2200 << 10)}*/';
  final second = 'b {color: red;}/*${'y' * (2200 << 10)}*/';
  final record0 = buildMobiRecord0(
    compressionType: 1,
    textRecordCount: 1,
    mobiVersion: 8,
    title: 'Synthetic flow regression with full KF8 header',
    fdstCount: 3,
    firstImageIndex: 3,
  );
  final header = ByteData.sublistView(record0);
  for (final offset in [0xF8, 0xFC, 0x100, 0x104]) {
    header.setUint32(offset, 0xFFFFFFFF);
  }
  header.setUint32(0xC0, 2);
  final fdst = ByteData(12 + 3 * 8);
  fdst.buffer.asUint8List().setAll(0, 'FDST'.codeUnits);
  fdst.setUint32(4, 12);
  fdst.setUint32(8, 3);
  var start = 0;
  for (final (i, value) in [main, first, second].indexed) {
    fdst.setUint32(12 + i * 8, start);
    start += value.length;
    fdst.setUint32(16 + i * 8, start);
  }
  return buildPdb('Flows', [
    record0,
    Uint8List.fromList('$main$first$second'.codeUnits),
    fdst.buffer.asUint8List(),
  ]);
}

void main() {
  test('MOBI images resolve on the first chapter load before any resource request', () async {
    final session = await BookSession.open(_imageBook(tinyPng));
    addTearDown(session.dispose);
    final path = session.book.readingOrder.first.name;
    final source = (await session.loadDocumentSource(path))!;
    final image = html.parseFragment(source).querySelector('img')!;
    expect(image.attributes['src'], 'image00001.png');
    expect(await session.loadResource(image.attributes['src']!), tinyPng);
    expect(await session.loadDocumentSource(path), source);
  });

  test('MOBI chapter links name a document containing their anchor', () async {
    final session = await BookSession.open(
      File('test/resources/books/mobi/alice-old-pg.mobi').readAsBytesSync(),
    );
    addTearDown(session.dispose);
    final documents = <String, String>{};
    for (final section in session.book.readingOrder) {
      documents[section.name] = (await session.loadDocumentSource(section.name))!;
    }
    var checked = 0;
    for (final entry in documents.entries) {
      for (final link in html.parseFragment(entry.value).querySelectorAll('a[href]')) {
        final target = Uri.parse(link.attributes['href']!);
        if (!target.fragment.startsWith('filepos')) continue;
        final destination = target.path.isEmpty ? entry.key : target.path;
        expect(documents[destination], isNotNull, reason: '$destination exists');
        final targetDocument = html.parseFragment(documents[destination]!);
        expect(
          targetDocument.querySelector('[id="${target.fragment}"]'),
          isNotNull,
          reason: '${entry.key} -> $target',
        );
        checked++;
      }
    }
    expect(checked, greaterThan(20));
  });

  test('MOBI refuses oversized header covers before reading their full record', () async {
    final largeImage = Uint8List(64 << 10)..setAll(0, tinyPng);
    final source = _ObservedSource(_imageBook(largeImage));
    final engine = await SessionEngine.openSource(
      source,
      policy: const SessionPolicy(coverMaxBytes: 1024),
    );
    addTearDown(engine.close);
    expect((engine.book as MobiBook).cover.isEmpty, isTrue);
    expect(source.reads.every((final read) => read.$2 <= 1024), isTrue);
    expect(await engine.resource('image00001.png'), largeImage);
  });

  test('KF8 serving plan releases flow text between requests', () {
    final source = _ObservedSource(_flowsBook());
    final pdb = PdbRandomAccess.open(source);
    addTearDown(pdb.close);
    final header = MobiHeader.parse(pdb.record(0), pdb.ident);
    final indexes = Mobi8Indexes.read(pdb: pdb, header: header, textOffset: 1);
    final scan = Mobi8SessionScan(flowSpans: indexes.flowTable.skip(1).toList());
    final store = MobiTextStore.build(
      pdb: pdb,
      header: header,
      textOffset: 1,
      onRecord: (_, _, bytes) => scan.addRecord(bytes),
    );
    final plan = Mobi8ServingPlan(
      pdb: pdb,
      header: header,
      store: store,
      indexes: indexes,
      resourceOffsets: const [],
      scan: scan,
      flow0Start: 0,
      textOffset: 1,
    );
    final first = plan.flowContent(1);
    expect(first, startsWith('a {color: blue;}'));
    expect(plan.flowContent(2), startsWith('b {color: red;}'));
    final before = source.reads.length;
    expect(plan.flowContent(1), first);
    expect(
      source.reads.length,
      greaterThan(before),
      reason: 'a flow released by the engine must not remain resident in its format serving plan',
    );
  });
}
