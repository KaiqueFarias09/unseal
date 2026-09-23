import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';
import 'chm_lzx.dart';

const _maxChmBytes = 128 * 1024 * 1024;
const _maxEntries = 10000;
const _maxEntryBytes = 16 * 1024 * 1024;
const _maxExpandedBytes = 128 * 1024 * 1024;
const _maxDecodedFrames = 8192;

/// Bounded ITSF directory and stream reader. Names are the virtual CHM paths.
final class ChmArchive {
  /// Validates the ITSF header and directory without expanding stored streams.
  ChmArchive(this.bytes) {
    if (bytes.length < 96 || bytes.length > _maxChmBytes || _ascii(0, 4) != 'ITSF') {
      throw const InvalidBookException('Invalid CHM ITSF header.');
    }
    final version = _u32(4);
    if (version != 2 && version != 3) {
      throw const FormatNotSupportedException('Unsupported CHM ITSF version.');
    }
    final headerLength = _u32(8);
    if (headerLength < (version == 3 ? 96 : 88)) {
      throw const InvalidBookException('Invalid CHM ITSF header length.');
    }
    final directoryOffset = _u64(0x48);
    final directoryLength = _u64(0x50);
    _dataOffset = version == 3 ? _u64(0x58) : directoryOffset + directoryLength;
    _range(directoryOffset, directoryLength);
    if (_ascii(directoryOffset, 4) != 'ITSP') {
      throw const InvalidBookException('Missing CHM ITSP directory.');
    }
    final itspLength = _u32(directoryOffset + 8);
    final chunkSize = _u32(directoryOffset + 16);
    final firstChunk = _i32(directoryOffset + 32);
    final lastChunk = _i32(directoryOffset + 36);
    final chunkCount = _u32(directoryOffset + 44);
    if (itspLength < 84 ||
        chunkSize < 64 ||
        chunkSize > 65536 ||
        firstChunk < 0 ||
        lastChunk < firstChunk ||
        chunkCount > 65536 ||
        lastChunk >= chunkCount ||
        itspLength + chunkCount * chunkSize > directoryLength) {
      throw const InvalidBookException('Invalid CHM ITSP chunk bounds.');
    }
    final chunksStart = directoryOffset + itspLength;
    final seen = <int>{};
    var chunk = firstChunk;
    while (chunk != -1) {
      if (chunk < firstChunk || chunk > lastChunk || !seen.add(chunk)) {
        throw const InvalidBookException('Cyclic or invalid CHM directory chain.');
      }
      final start = chunksStart + chunk * chunkSize;
      if (_ascii(start, 4) != 'PMGL') {
        throw const InvalidBookException('Invalid CHM PMGL listing.');
      }
      final free = _u32(start + 4);
      final next = _i32(start + 16);
      final end = start + chunkSize - free;
      if (free > chunkSize - 20 || end > bytes.length) {
        throw const InvalidBookException('Invalid CHM PMGL free space.');
      }
      var cursor = start + 20;
      while (cursor < end) {
        final nameLength = _encInt(cursor, end);
        cursor = nameLength.$2;
        if (nameLength.$1 == 0 || nameLength.$1 > 4096 || cursor + nameLength.$1 > end) {
          throw const InvalidBookException('Invalid CHM directory name.');
        }
        final name = utf8.decode(
          bytes.sublist(cursor, cursor + nameLength.$1),
          allowMalformed: true,
        );
        cursor += nameLength.$1;
        final section = _encInt(cursor, end);
        final position = _encInt(section.$2, end);
        final length = _encInt(position.$2, end);
        cursor = length.$2;
        if (section.$1 > 1 ||
            length.$1 > _maxEntryBytes ||
            position.$1 + length.$1 > _maxExpandedBytes ||
            (section.$1 == 0 && _dataOffset + position.$1 + length.$1 > bytes.length)) {
          throw const InvalidBookException('CHM entry exceeds supported bounds.');
        }
        if (entries.length >= _maxEntries || entries.containsKey(name.toLowerCase())) {
          throw const InvalidBookException('Too many or duplicate CHM entries.');
        }
        entries[name.toLowerCase()] = ChmEntry(name, section.$1, position.$1, length.$1);
      }
      if (cursor != end) throw const InvalidBookException('Malformed CHM PMGL entry.');
      chunk = next;
    }
    if (entries.isEmpty) throw const InvalidBookException('CHM directory is empty.');
  }

  /// Source container bytes.
  final Uint8List bytes;

  /// Entries keyed by case-insensitive virtual path.
  final Map<String, ChmEntry> entries = <String, ChmEntry>{};
  late final int _dataOffset;
  _ChmCompressed? _compressed;

  /// Number of LZX frames expanded while reading this archive.
  ///
  /// Exposed from this internal adapter for resource-limit regression tests.
  int get decodedLzxFrames => _compressed?.decodedFrames ?? 0;

  /// Finds a virtual entry by path.
  ChmEntry? entry(final String name) => entries[name.toLowerCase()];

  /// Reads a bounded entry from section 0 or LZX-compressed section 1.
  Uint8List read(final ChmEntry entry) {
    if (entry.length == 0) return Uint8List(0);
    if (entry.section == 0) {
      final start = _dataOffset + entry.offset;
      _range(start, entry.length);
      return Uint8List.sublistView(bytes, start, start + entry.length);
    }
    return (_compressed ??= _ChmCompressed(this)).read(entry);
  }

  String _ascii(final int start, final int count) {
    _range(start, count);
    return ascii.decode(bytes.sublist(start, start + count), allowInvalid: true);
  }

  int _u32(final int at) {
    _range(at, 4);
    return ByteData.sublistView(bytes).getUint32(at, Endian.little);
  }

  int _i32(final int at) {
    _range(at, 4);
    return ByteData.sublistView(bytes).getInt32(at, Endian.little);
  }

  int _u64(final int at) {
    _range(at, 8);
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(at + 4, Endian.little) != 0) {
      throw const InvalidBookException('CHM 64-bit offset exceeds supported bounds.');
    }
    return view.getUint32(at, Endian.little);
  }

  void _range(final int start, final int length) {
    if (start < 0 || length < 0 || start > bytes.length || length > bytes.length - start) {
      throw const InvalidBookException('CHM offset exceeds file bounds.');
    }
  }

  (int, int) _encInt(final int start, final int end) {
    var cursor = start;
    var value = 0;
    for (var i = 0; i < 10; i++) {
      if (cursor >= end) throw const InvalidBookException('Truncated CHM ENCINT.');
      final byte = bytes[cursor++];
      value = (value << 7) | (byte & 0x7f);
      if (value > _maxExpandedBytes) throw const InvalidBookException('Oversized CHM ENCINT.');
      if (byte & 0x80 == 0) return (value, cursor);
    }
    throw const InvalidBookException('Invalid CHM ENCINT.');
  }
}

/// One CHM virtual directory entry.
final class ChmEntry {
  /// Creates an entry from a validated PMGL record.
  const ChmEntry(this.name, this.section, this.offset, this.length);

  /// Virtual path in the CHM directory.
  final String name;

  /// Data section, either uncompressed 0 or LZX-compressed 1.
  final int section;

  /// Offset within the selected data section.
  final int offset;

  /// Uncompressed byte length.
  final int length;
}

final class _ChmCompressed {
  _ChmCompressed(this.archive) {
    final content = archive.entry('::DataSpace/Storage/MSCompressed/Content');
    final control = archive.entry('::DataSpace/Storage/MSCompressed/ControlData');
    final reset = archive.entry(
      '::DataSpace/Storage/MSCompressed/Transform/'
      '{7FC28940-9D31-11D0-9B27-00A0C91E9C7C}/InstanceData/ResetTable',
    );
    if (content == null ||
        control == null ||
        reset == null ||
        content.section != 0 ||
        control.section != 0 ||
        reset.section != 0) {
      throw const InvalidBookException('CHM LZX control streams are missing.');
    }
    final c = archive.read(control);
    final r = archive.read(reset);
    if (c.length < 24 ||
        ascii.decode(c.sublist(4, 8), allowInvalid: true) != 'LZXC' ||
        r.length < 40) {
      throw const InvalidBookException('Invalid CHM LZX control streams.');
    }
    final cv = ByteData.sublistView(c);
    final rv = ByteData.sublistView(r);
    final version = cv.getUint32(8, Endian.little);
    if (version != 1 && version != 2) {
      throw const FormatNotSupportedException('Unsupported CHM LZX control version.');
    }
    final multiplier = version == 2 ? 32768 : 1;
    final resetInterval = cv.getUint32(12, Endian.little) * multiplier;
    final windowSize = cv.getUint32(16, Endian.little) * multiplier;
    final windowsPerReset = cv.getUint32(20, Endian.little);
    final frameSize = _bounded64(rv, 32);
    final count = rv.getUint32(4, Endian.little);
    final tableOffset = rv.getUint32(12, Endian.little);
    final expanded = _bounded64(rv, 16);
    final compressedSize = _bounded64(rv, 24);
    if (windowSize < 32768 ||
        windowSize > 2097152 ||
        windowSize & (windowSize - 1) != 0 ||
        frameSize != 32768 ||
        resetInterval == 0 ||
        windowsPerReset == 0 ||
        count == 0 ||
        count > 4096 ||
        tableOffset < 40 ||
        tableOffset + count * 8 > r.length ||
        expanded > _maxExpandedBytes ||
        compressedSize > content.length) {
      throw const InvalidBookException('Invalid CHM LZX reset bounds.');
    }
    _content = content;
    _expandedLength = expanded;
    _resetFrameCount = resetInterval ~/ (windowSize ~/ 2) * windowsPerReset;
    if (_resetFrameCount <= 0 || _resetFrameCount > 4096) {
      throw const InvalidBookException('Invalid CHM LZX reset interval.');
    }
    _offsets = List<int>.generate(
      count + 1,
      (final index) => index == count ? compressedSize : _bounded64(rv, tableOffset + index * 8),
    );
    for (var i = 0; i < count; i++) {
      if (_offsets[i] >= _offsets[i + 1] || _offsets[i + 1] > compressedSize) {
        throw const InvalidBookException('Invalid CHM LZX block offsets.');
      }
    }
    _windowBits = windowSize.bitLength - 1;
  }

  final ChmArchive archive;
  late final ChmEntry _content;
  late final int _expandedLength;
  late final int _resetFrameCount;
  late final int _windowBits;
  late final List<int> _offsets;
  ChmLzxDecoder? _decoder;
  int _cachedResetStart = -1;
  int _nextFrame = -1;
  final List<Uint8List> _cachedFrames = <Uint8List>[];
  int decodedFrames = 0;

  static int _bounded64(final ByteData view, final int offset) {
    if (view.getUint32(offset + 4, Endian.little) != 0) {
      throw const InvalidBookException('CHM LZX size exceeds supported bounds.');
    }
    return view.getUint32(offset, Endian.little);
  }

  Uint8List read(final ChmEntry entry) {
    if (entry.offset + entry.length > _expandedLength) {
      throw const InvalidBookException('CHM entry exceeds LZX span.');
    }
    final result = Uint8List(entry.length);
    var copied = 0;
    var frame = entry.offset ~/ 32768;
    while (copied < entry.length) {
      final bytes = _frame(frame);
      final skip = copied == 0 ? entry.offset % 32768 : 0;
      final take = entry.length - copied < bytes.length - skip
          ? entry.length - copied
          : bytes.length - skip;
      if (take <= 0) throw const InvalidBookException('Invalid CHM LZX file offset.');
      result.setRange(copied, copied + take, bytes, skip);
      copied += take;
      frame++;
    }
    return result;
  }

  Uint8List _frame(final int frame) {
    if (frame >= _offsets.length - 1) {
      throw const InvalidBookException('Missing CHM LZX frame.');
    }
    final resetStart = frame - frame % _resetFrameCount;
    if (resetStart != _cachedResetStart) {
      _cachedResetStart = resetStart;
      _nextFrame = resetStart;
      _cachedFrames.clear();
      _decoder = ChmLzxDecoder(_windowBits)..reset();
    }
    while (_nextFrame <= frame) {
      if (decodedFrames >= _maxDecodedFrames) {
        throw const InvalidBookException('CHM cumulative LZX work limit exceeded.');
      }
      final start = _content.offset + _offsets[_nextFrame];
      final compressedLength = _offsets[_nextFrame + 1] - _offsets[_nextFrame];
      final raw = archive.bytes.sublist(
        archive._dataOffset + start,
        archive._dataOffset + start + compressedLength,
      );
      final remaining = _expandedLength - _nextFrame * 32768;
      _cachedFrames.add(_decoder!.decodeFrame(raw, remaining < 32768 ? remaining : 32768));
      decodedFrames++;
      _nextFrame++;
    }
    return _cachedFrames[frame - resetStart];
  }
}
