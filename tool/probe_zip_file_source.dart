import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:unseal/src/foundation/archive/archive_access.dart';

/// Probe 2: file-backed lazy zip source — decode the central directory
/// from an InputFileStream, inflate single entries by re-seeking, and
/// verify CRCs. If this works, the VM session isolate never holds the
/// whole compressed book in memory.
Future<void> main() async {
  final path = Platform.environment['PROBE_BOOK'] ?? 'test/resources/books/epub/mahabharata.epub';
  final expected = File(path).readAsBytesSync();

  final stream = InputFileStream(path);
  final sw = Stopwatch()..start();
  final archive = ZipDecoder().decodeStream(stream);
  stdout.writeln(
    'file-backed lazy decode: ${sw.elapsedMilliseconds}ms, ${archive.files.length} entries',
  );
  stdout.writeln('rss after lazy decode: ${ProcessInfo.currentRss ~/ 1024} KiB');

  var verified = 0;
  var inflatedBytes = 0;
  for (final file in archive.files) {
    if (!file.isFile) continue;
    sw.reset();
    final output = _BoundedOutputStream(math.min(maxZipEntryUncompressedBytes, file.size));
    final rawContent = file.rawContent;
    if (rawContent == null) continue;
    final rawStream = rawContent.getStream(decompress: false);
    if (file.compression == CompressionType.deflate) {
      Inflate.stream(rawStream, output: output);
    } else {
      output.writeStream(rawStream);
    }
    final content = output.getBytes();
    if (file.crc32 != null && getCrc32(content) != file.crc32) {
      stdout.writeln('CRC MISMATCH at ${file.name}');
      return;
    }
    verified++;
    inflatedBytes += content.length;
  }
  stdout.writeln(
    'verified $verified entries, $inflatedBytes bytes total — '
    'total inflate time measured cumulatively',
  );
  stdout.writeln('rss after all inflates: ${ProcessInfo.currentRss ~/ 1024} KiB');

  // Byte-for-byte parity with the in-memory path for one entry.
  final target = archive.files.firstWhere((f) => f.isFile && f.name.endsWith('.opf'));
  final fileBacked = _inflateOne(archive, target.name);
  final inMemoryArchive = ZipDecoder().decodeBytes(expected);
  final inMemory = _inflateOne(inMemoryArchive, target.name);
  stdout.writeln(
    'opf parity file-backed vs in-memory: '
    '${fileBacked.length == inMemory.length && fileBacked.join() == inMemory.join()}',
  );
  await stream.close();
}

Uint8List _inflateOne(final Archive archive, final String name) {
  final file = archive.files.firstWhere((f) => f.isFile && f.name == name);
  final output = _BoundedOutputStream(math.min(maxZipEntryUncompressedBytes, file.size));
  final rawStream = file.rawContent!.getStream(decompress: false);
  if (file.compression == CompressionType.deflate) {
    Inflate.stream(rawStream, output: output);
  } else {
    output.writeStream(rawStream);
  }
  return output.getBytes();
}

final class _BoundedOutputStream extends OutputStream {
  _BoundedOutputStream(this.maxBytes)
    : _buffer = Uint8List(math.min(maxBytes, 0x8000)),
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
    if (length + 1 > maxBytes) throw StateError('bound');
    _grow(length + 1);
    _buffer[length++] = value;
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    final count = length ?? bytes.length;
    if (this.length + count > maxBytes) throw StateError('bound');
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
    if (length + count > maxBytes) throw StateError('bound');
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
