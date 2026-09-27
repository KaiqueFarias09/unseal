import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:unseal/src/foundation/archive/archive_access.dart';

/// Probe: cost of lazy zip decode (central directory only) versus full
/// materialization, and the cost of inflating a single entry on demand.
Future<void> main() async {
  final path = Platform.environment['PROBE_BOOK'] ?? 'test/resources/books/epub/mahabharata.epub';
  final bytes = File(path).readAsBytesSync();
  stdout.writeln('book: $path (${bytes.length ~/ 1024} KiB compressed)');

  _rss('start');

  final sw = Stopwatch()..start();
  final archive = ZipDecoder().decodeBytes(bytes);
  final lazyDecodeMs = sw.elapsedMilliseconds;
  final entryCount = archive.files.length;
  stdout.writeln('lazy decode (no inflate): ${lazyDecodeMs}ms, $entryCount entries');
  _rss('after lazy decode');

  sw.reset();
  var declaredTotal = 0;
  for (final file in archive.files) {
    if (file.isFile) declaredTotal += file.size;
  }
  stdout.writeln(
    'inventory walk: ${sw.elapsedMicroseconds / 1000}ms, '
    'declared uncompressed total ${declaredTotal ~/ 1024} KiB',
  );

  // Inflate the largest entry only, with the same bounded guard as
  // decodeBookZip.
  ArchiveFile? largest;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (largest == null || file.size > largest.size) largest = file;
  }
  if (largest == null) return;
  sw.reset();
  final output = _CapOutputStream(math.min(maxZipEntryUncompressedBytes, largest.size));
  final rawStream = largest.rawContent!.getStream(decompress: false);
  if (largest.compression == CompressionType.deflate) {
    Inflate.stream(rawStream, output: output);
  } else {
    output.writeStream(rawStream);
  }
  final content = output.getBytes();
  final singleMs = sw.elapsedMilliseconds;
  final crcOk = getCrc32(content) == largest.crc32;
  stdout.writeln(
    'single-entry inflate "${largest.name}": ${singleMs}ms, '
    '${content.length ~/ 1024} KiB, crc ok=$crcOk',
  );
  _rss('after single inflate');

  // Second inflate of a different entry, measuring the steady state.
  final second = archive.files.where((f) => f.isFile && f != largest).toList();
  if (second.isNotEmpty) {
    final target = second[second.length ~/ 2];
    sw.reset();
    final output2 = _CapOutputStream(math.min(maxZipEntryUncompressedBytes, target.size));
    final raw2 = target.rawContent!.getStream(decompress: false);
    if (target.compression == CompressionType.deflate) {
      Inflate.stream(raw2, output: output2);
    } else {
      output2.writeStream(raw2);
    }
    stdout.writeln(
      'second inflate "${target.name}": ${sw.elapsedMilliseconds}ms, '
      '${output2.getBytes().length ~/ 1024} KiB',
    );
  }
  _rss('after second inflate');

  // Full materialization for comparison.
  sw.reset();
  final full = decodeBookZip(bytes);
  stdout.writeln('full decodeBookZip (all inflated): ${sw.elapsedMilliseconds}ms');
  _rss('after full decode');
  var fullTotal = 0;
  for (final file in full.files) {
    if (file.isFile) fullTotal += file.content.length;
  }
  stdout.writeln('full decompressed total: ${fullTotal ~/ 1024} KiB');
  _rss('end');
}

void _rss(final String label) {
  stdout.writeln('  rss[$label]: current=${ProcessInfo.currentRss ~/ 1024} KiB');
}

/// OutputStream that silently caps output at [maxBytes], so a probe
/// inflate can stop caring about huge declared sizes.
final class _CapOutputStream extends OutputStream {
  _CapOutputStream(this.maxBytes)
    : _buffer = Uint8List(math.min(maxBytes, 0x10000)),
      super(byteOrder: ByteOrder.littleEndian);

  Uint8List _buffer;
  final int maxBytes;

  @override
  int length = 0;

  void _grow(final int required) {
    if (required <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < required) {
      capacity = math.min(maxBytes, capacity * 2);
    }
    final grown = Uint8List(capacity);
    grown.setRange(0, length, _buffer);
    _buffer = grown;
  }

  @override
  void writeByte(final int value) {
    _grow(length + 1);
    _buffer[length++] = value;
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    final count = length ?? bytes.length;
    _grow(this.length + count);
    _buffer.setRange(this.length, this.length + count, bytes);
    this.length += count;
  }

  @override
  void writeStream(final InputStream stream) {
    writeBytes(stream.toUint8List());
  }

  @override
  void writeBackReference(final int distance, final int count) {
    _grow(length + count);
    final source = length - distance;
    if (distance >= count) {
      _buffer.setRange(length, length + count, _buffer, source);
    } else {
      var from = source;
      var to = length;
      final end = length + count;
      while (to < end) {
        _buffer[to++] = _buffer[from++];
      }
    }
    length += count;
  }

  @override
  void clear() => length = 0;

  @override
  void flush() {}

  @override
  Uint8List subset(int start, [int? end]) {
    if (start < 0) start = length + start;
    end ??= length;
    if (end < 0) end = length + end;
    return Uint8List.view(_buffer.buffer, _buffer.offsetInBytes + start, end - start);
  }

  @override
  Uint8List getBytes() => subset(0, length);
}
