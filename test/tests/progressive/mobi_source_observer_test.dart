import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/src/platform/io/zip_byte_source_io.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

/// Observes the actual source boundary, independently of SessionMetrics.
final class _SourceObserver implements ZipByteSource {
  _SourceObserver(this.delegate);

  final ZipByteSource delegate;
  final List<(int offset, int count)> reads = [];
  var bytesRead = 0;
  var closed = false;

  @override
  int get length => delegate.length;

  @override
  Uint8List read(final int offset, final int count) {
    final bytes = delegate.read(offset, count);
    reads.add((offset, count));
    bytesRead += bytes.length;
    return bytes;
  }

  @override
  void close() {
    closed = true;
    delegate.close();
  }
}

/// Known record boundaries come from the fixture inputs and PDB table width,
/// never from the production record-span index or session counters.
(Uint8List, List<(int, int)>) _largeStoredBook() {
  const chapters = 20;
  final records = <Uint8List>[
    buildMobiRecord0(
      compressionType: 1,
      textRecordCount: chapters,
      firstImageIndex: chapters + 1,
      title: 'Independent source observer',
    ),
    for (var i = 0; i < chapters; i++)
      Uint8List.fromList(
        utf8.encode(
          '${i == 0 ? '<html><body>' : '<mbp:pagebreak/>'}'
          '<p>Chapter $i ${'text ' * (60 << 10)}</p>'
          '${i == chapters - 1 ? '</body></html>' : ''}',
        ),
      ),
    tinyPng,
  ];
  final textRanges = <(int, int)>[];
  var offset = 78 + records.length * 8;
  for (var i = 0; i < records.length; i++) {
    if (i >= 1 && i <= chapters) textRanges.add((offset, records[i].length));
    offset += records[i].length;
  }

  return (buildPdb('Observed stored MOBI', records), textRanges);
}

void main() {
  test('MOBI source observes the open scan, first section, cache hit and cold reread', () async {
    final (bytes, textRanges) = _largeStoredBook();
    final source = _SourceObserver(MemoryZipByteSource(bytes));
    final engine = await SessionEngine.openSource(
      source,
      policy: const SessionPolicy(cacheBytes: 1 << 20, coverMaxBytes: 0),
    );
    addTearDown(engine.close);
    final openReads = List<(int, int)>.of(source.reads);
    final openBytes = source.bytesRead;
    expect(engine.book.files.html, isEmpty);
    expect(engine.book.readingOrder, hasLength(20));
    for (final range in textRanges) {
      expect(
        openReads.where((final read) => read == range),
        hasLength(1),
        reason: 'open scans each known stored record exactly once without retaining its content',
      );
    }
    expect(
      openBytes,
      greaterThanOrEqualTo(textRanges.fold<int>(0, (final total, final r) => total + r.$2)),
    );
    expect(openReads.any((final read) => read.$2 == source.length), isFalse);

    final firstPath = engine.book.readingOrder.first.name;
    final first = await engine.documentSource(firstPath);
    expect(first, contains('Chapter 0'));
    expect(first, isNot(contains('Chapter 1 ')));
    final firstReads = source.reads.sublist(openReads.length);
    expect(firstReads.where(textRanges.contains).toList(), [textRanges.first]);
    expect(source.bytesRead - openBytes, lessThan(textRanges.first.$2 + 1024));

    final warmReadCount = source.reads.length;
    final warmByteCount = source.bytesRead;
    expect(await engine.documentSource(firstPath), first);
    expect(source.reads, hasLength(warmReadCount));
    expect(source.bytesRead, warmByteCount, reason: 'the chapter cache hit issues no source read');

    for (final item in engine.book.readingOrder.skip(1)) {
      await engine.documentSource(item.name);
    }
    final beforeReload = source.reads.length;
    final bytesBeforeReload = source.bytesRead;
    expect(await engine.documentSource(firstPath), first);
    expect(source.reads.sublist(beforeReload), [textRanges.first]);
    expect(source.bytesRead - bytesBeforeReload, textRanges.first.$2);
    engine.close();
    expect(source.closed, isTrue);
  });

  test(
    'real AZW3 file reads are observed independently across open and cached section access',
    () async {
      final source = _SourceObserver(
        FileZipByteSource.open('test/resources/books/mobi/alice-kf8-pg.azw3'),
      );
      final engine = await SessionEngine.openSource(source);
      addTearDown(engine.close);
      expect(engine.book.format, BookFormat.azw3);
      expect(engine.book.files.html, isEmpty);
      final openCalls = source.reads.length;
      final openBytes = source.bytesRead;
      expect(openCalls, greaterThan(3));
      expect(openBytes, greaterThan(1024));
      expect(source.reads.any((final read) => read.$2 == source.length), isFalse);

      final first = await engine.documentSource(engine.book.readingOrder.first.name);
      expect(first, isNotEmpty);
      expect(source.reads.length, greaterThanOrEqualTo(openCalls));
      expect(source.bytesRead, greaterThanOrEqualTo(openBytes));
      final warmCalls = source.reads.length;
      final warmBytes = source.bytesRead;
      expect(await engine.documentSource(engine.book.readingOrder.first.name), first);
      expect(source.reads, hasLength(warmCalls));
      expect(source.bytesRead, warmBytes);
    },
  );
}
