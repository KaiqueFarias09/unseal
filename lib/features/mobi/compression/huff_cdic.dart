import 'dart:typed_data';

import 'package:e_livre/features/mobi/exceptions/mobi_exception.dart';

class _Dict1Entry {
  const _Dict1Entry(this.codelen, this.term, this.maxcode);
  final int codelen;
  final bool term;
  final int maxcode;
}

class _DictionaryEntry {
  _DictionaryEntry(this.data, this.cached);
  Uint8List data;
  bool cached;
}

/// Decompresses MOBI records compressed with the HUFF/CDIC algorithm.
///
/// The first section holds the `HUFF` header with the code length
/// table (256 entries) and the min/max code tables; the remaining
/// sections are `CDIC` phrase dictionaries referenced by the decoder.
class HuffReader {
  /// Creates a [HuffReader] from the huff section records.
  HuffReader(final List<Uint8List> sections) {
    _loadHuff(sections.first);
    for (var i = 1; i < sections.length; i++) {
      _loadCdic(sections[i]);
    }
  }

  late final List<_Dict1Entry> _dict1;
  late final List<int> _mincode;
  late final List<int> _maxcode;
  final List<_DictionaryEntry> _dictionary = <_DictionaryEntry>[];

  /// Decompresses a single record.
  Uint8List unpack(final Uint8List data) {
    final output = <Uint8List>[];
    var bitsLeft = data.length * 8;
    final padded = Uint8List(data.length + 8)
      ..setRange(0, data.length, data);
    final view = ByteData.sublistView(padded);
    var pos = 0;
    var x = view.getUint64(pos);
    var n = 32;

    while (true) {
      if (n <= 0) {
        pos += 4;
        x = view.getUint64(pos);
        n += 32;
      }
      final code = (x >> n) & 0xFFFFFFFF;

      final entry = _dict1[code >> 24];
      var codelen = entry.codelen;
      var maxcode = entry.maxcode;
      if (!entry.term) {
        while (code < _mincode[codelen]) {
          codelen++;
        }
        maxcode = _maxcode[codelen];
      }

      n -= codelen;
      bitsLeft -= codelen;
      if (bitsLeft < 0) {
        break;
      }

      final r = (maxcode - code) >> (32 - codelen);
      final dictionaryEntry = _dictionary[r];
      var slice = dictionaryEntry.data;
      if (!dictionaryEntry.cached) {
        slice = unpack(slice);
        dictionaryEntry.data = slice;
        dictionaryEntry.cached = true;
      }
      output.add(slice);
    }

    final builder = BytesBuilder(copy: false);
    for (final chunk in output) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  void _loadHuff(final Uint8List huff) {
    if (huff.length < 16 ||
        huff[0] != 0x48 || huff[1] != 0x55 || huff[2] != 0x46 || huff[3] != 0x46 ||
        huff[4] != 0 || huff[5] != 0 || huff[6] != 0 || huff[7] != 0x18) {
      throw const MobiException('Invalid HUFF header');
    }
    final view = ByteData.sublistView(huff);
    final off1 = view.getUint32(8);
    final off2 = view.getUint32(12);

    final dict1 = <_Dict1Entry>[];
    for (var i = 0; i < 256; i++) {
      final v = view.getUint32(off1 + i * 4);
      final codelen = v & 0x1F;
      final term = (v & 0x80) != 0;
      if (codelen == 0 || (codelen <= 8 && !term)) {
        throw const MobiException('Invalid HUFF codelen table');
      }
      var maxcode = v >> 8;
      maxcode = ((maxcode + 1) << (32 - codelen)) - 1;
      dict1.add(_Dict1Entry(codelen, term, maxcode));
    }
    _dict1 = dict1;

    final mincode = <int>[0];
    final maxcode = <int>[0];
    for (var i = 0; i < 32; i++) {
      final pairMin = view.getUint32(off2 + i * 8);
      final pairMax = view.getUint32(off2 + i * 8 + 4);
      final codelen = i + 1;
      mincode.add(pairMin << (32 - codelen));
      maxcode.add(((pairMax + 1) << (32 - codelen)) - 1);
    }
    _mincode = mincode;
    _maxcode = maxcode;
  }

  void _loadCdic(final Uint8List cdic) {
    if (cdic.length < 16 ||
        cdic[0] != 0x43 || cdic[1] != 0x44 || cdic[2] != 0x49 || cdic[3] != 0x43 ||
        cdic[4] != 0 || cdic[5] != 0 || cdic[6] != 0 || cdic[7] != 0x10) {
      throw const MobiException('Invalid CDIC header');
    }
    final view = ByteData.sublistView(cdic);
    final phrases = view.getUint32(8);
    final bits = view.getUint32(12);
    final available = (1 << bits) < phrases - _dictionary.length
        ? (1 << bits)
        : phrases - _dictionary.length;

    for (var i = 0; i < available; i++) {
      final off = view.getUint16(16 + i * 2);
      final blen = view.getUint16(16 + off);
      final length = blen & 0x7FFF;
      final cached = (blen & 0x8000) != 0;
      final start = 18 + off;
      final end = start + length;
      _dictionary.add(
        _DictionaryEntry(
          Uint8List.sublistView(cdic, start, end > cdic.length ? cdic.length : end),
          cached,
        ),
      );
    }
  }
}
