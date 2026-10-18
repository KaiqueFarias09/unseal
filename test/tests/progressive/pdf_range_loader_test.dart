import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/src/features/progressive/byte_source.dart';
import 'package:unseal/src/features/progressive/pdf_range_loader.dart';
import 'package:unseal/src/features/progressive/session_metrics.dart';
import 'package:unseal/src/features/progressive/session_policy.dart';

/// A source over an in-memory buffer that records every served range.
final class RecordingSource {
  RecordingSource(this.bytes, {this.policy = const SessionPolicy()});

  final Uint8List bytes;
  final SessionPolicy policy;
  final List<({int offset, int count})> reads = <({int offset, int count})>[];
  var closed = false;

  int get totalBytes => reads.fold(0, (final total, final read) => total + read.count);

  Future<Uint8List> readRange(final int offset, final int count) async {
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    reads.add((offset: offset, count: count));

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  PdfRangeLoader loader({final SessionMetricsCounter? counter}) =>
      PdfRangeLoader(readRange: readRange, length: bytes.length, policy: policy, counter: counter);
}

Uint8List _pattern(final int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = i & 0xFF;
  }

  return bytes;
}

void main() {
  group('PdfRangeLoader', () {
    test('serves demanded ranges from exactly one fetch', () async {
      final source = RecordingSource(_pattern(256 << 10));
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      final first = await loader.drive(() => resident.read(1000, 64 << 10));
      expect(first.length, 64 << 10);
      expect(source.reads, hasLength(1));
      expect(source.reads.first, (offset: 1000, count: 64 << 10));

      // The same window again is resident — no wire traffic.
      final second = await loader.drive(() => resident.read(1000, 64 << 10));
      expect(second, equals(first));
      expect(source.reads, hasLength(1));

      // Overlapping windows only fetch their missing spans.
      await loader.drive(() => resident.read(0, 128 << 10));
      expect(source.reads, hasLength(3));
      expect(source.reads[1], (offset: 0, count: 1000));
      expect(source.reads[2], (
        offset: (64 << 10) + 1000,
        count: (128 << 10) - ((64 << 10) + 1000),
      ));
      expect(loader.fetchedBytes, 128 << 10);
      expect(loader.fetchedUniqueBytes, 128 << 10);
    });

    test('splits a read across ranges and copies bytes out', () async {
      final source = RecordingSource(_pattern(1 << 20));
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      final seeded = await loader.drive(() => resident.read(4096, 8192));
      // Mutating the copy must not corrupt the store.
      seeded[0] = 0xAA;

      final again = await loader.drive(() => resident.read(4096, 8192));
      expect(again[0], isNot(0xAA));

      // A read spanning resident and missing bytes demands only the
      // missing pieces.
      final spanned = await loader.drive(() => resident.read(0, 32 << 10));
      expect(spanned[4096], 4096 & 0xFF);
      expect(source.reads, hasLength(3));
      expect(source.reads[1], (offset: 0, count: 4096));
      expect(source.reads[2], (offset: 8192 + 4096, count: (32 << 10) - (8192 + 4096)));
    });

    test('enforces the per-request cap before allocating', () async {
      final source = RecordingSource(
        _pattern(1 << 20),
        policy: const SessionPolicy(rangeRequestBytes: 96 << 10),
      );
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      await expectLater(
        loader.drive(() => resident.read(0, 1 << 20)),
        throwsA(isA<ByteSourceLimitExceededException>()),
      );
      expect(source.reads, isEmpty);
    });

    test('short answers fail typed', () async {
      final bytes = _pattern(1 << 20);
      final loader = PdfRangeLoader(
        readRange: (final offset, final count) async =>
            Uint8List.sublistView(bytes, offset, offset + count - 1),
        length: bytes.length,
      );
      final resident = PdfResidentByteSource(loader);

      await expectLater(
        loader.drive(() => resident.read(0, 64 << 10)),
        throwsA(isA<ByteSourceShortReadException>()),
      );
    });

    test('evicts oldest unpinned ranges down to the budget and refetches', () async {
      final bytes = _pattern(2 << 20);
      final source = RecordingSource(
        bytes,
        policy: const SessionPolicy(cacheBytes: 1 << 20, rangeRequestBytes: 1 << 20),
      );
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      await loader.drive(() => resident.read(0, 1 << 20));
      final afterFirst = loader.residentBytes;
      expect(afterFirst, lessThanOrEqualTo(1 << 20));

      // The next step pushes past the budget; the oldest range evicts.
      await loader.drive(() => resident.read(1 << 20, 256 << 10));
      expect(loader.evictedBytes, greaterThan(0));

      // Reading the evicted span again refetches it.
      await loader.drive(() => resident.read(0, 4096));
      expect(source.reads.last, (offset: 0, count: 4096));
      expect(loader.resumeCount, greaterThan(0));
    });

    test('metrics counter sees every fetched span', () async {
      final counter = SessionMetricsCounter();
      final source = RecordingSource(_pattern(256 << 10));
      final loader = source.loader(counter: counter);

      await loader.drive(() => PdfResidentByteSource(loader).read(0, 128 << 10));
      expect(counter.toWire()['containerReads'], loader.fetchCount);
      expect(counter.toWire()['sourceBytesRead'], loader.fetchedBytes);
    });

    test('coverage reports merged all-time fetches', () async {
      final source = RecordingSource(_pattern(1 << 20));
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      await loader.drive(() => resident.read(0, 64 << 10));
      await loader.drive(() => resident.read(32 << 10, 64 << 10));
      final coverage = loader.coverage();
      expect(coverage, hasLength(1));
      expect(coverage.first.$1, 0);
      expect(coverage.first.$2, 96 << 10);
    });

    test('out-of-bounds reads throw RangeError like the memory source', () async {
      final source = RecordingSource(_pattern(1024));
      final loader = source.loader();
      final resident = PdfResidentByteSource(loader);

      expect(() => resident.read(0, 1025), throwsRangeError);
      expect(() => resident.read(-1, 4), throwsRangeError);
    });
  });
}
