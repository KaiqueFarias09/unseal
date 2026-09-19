// Benchmarks for the MOBI compression codecs: the PalmDOC (LZ77)
// decoder and the HUFF/CDIC decoder.
//
// The library ships decoders only, so the synthetic fixtures are
// prepared untimed before the run: mixed prose is extracted from the
// EPUB fixtures, split into the 4096-byte text records MOBI uses, and
// PalmDOC-encoded by a benchmark-local compressor that emits the same
// token stream [decompressPalmdoc] accepts. HUFF/CDIC reuses the
// synthetic 8-bit identity dictionary from the test suite
// (test/tests/mobi/mobi_fixture_builder.dart), where every byte
// decodes through one dictionary lookup — exercising the bit reader,
// the dictionary and the output assembly of the real decoder. Every
// fixture round-trips untimed before it may enter a measurement.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:unseal/src/features/mobi/compression/huff_cdic.dart';
import 'package:unseal/src/features/mobi/compression/palmdoc.dart';
import 'package:unseal/src/features/mobi/header/mobi_header.dart';
import 'package:unseal/src/features/mobi/header/pdb_header.dart';
import 'package:unseal/src/features/mobi/reader/mobi_trailing_data.dart';

import '../test/tests/mobi/mobi_fixture_builder.dart' show buildCdic, buildHuffHeader;
import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Prose size points: ~100 KB, ~1 MB and ~5 MB of decompressed text.
const List<int> _proseSizes = <int>[100 * 1024, 1024 * 1024, 5 * 1024 * 1024];

/// MOBI text records hold up to 4096 uncompressed bytes.
const int _textRecordSize = 4096;

/// Optional real HUFF/CDIC sample, kept outside the repository. Any
/// HUFF-compressed (compression `DH`, 0x4448) .mobi / .azw3 works;
/// e.g. libmobi's `tests/samples/sample-unicode-huffdic.mobi`.
const String _realSamplePath = '/tmp/unseal-huffcdic-sample.mobi';

final Map<int, _ProseFixtures> _fixturesBySize = <int, _ProseFixtures>{};
HuffReader? _huffReader;

/// Runs the MOBI compression codec benchmarks.
void runMobiCompressionBenchmarks() {
  final group = BenchmarkGroup('MOBI compression');

  _addAliceRecordBenchmark(group);
  for (final targetBytes in _proseSizes) {
    _addProseBenchmarks(group, targetBytes);
  }
  _addRealSampleBenchmark(group);
}

/// Adds the end-to-end sanity label: record 1 of the PalmDOC-compressed
/// alice-old.mobi fixture, decompressed straight from the real file.
void _addAliceRecordBenchmark(final BenchmarkGroup group) {
  final pdb = PdbHeader.parse(mobi6Alice.bytes);
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  if (pdb.count < 2 || header.compressionType != 2) {
    return;
  }

  final record = pdb.record(1);
  final decompressed = decompressPalmdoc(record);
  group.add(
    'PalmDOC — alice-old.mobi record 1 (real corpus, ${formatBytes(decompressed.length)})',
    () => decompressPalmdoc(record),
    inputBytes: decompressed.length,
    note: '${formatBytes(record.length)} compressed',
  );
}

/// Adds the PalmDOC and HUFF/CDIC labels for one prose size point.
void _addProseBenchmarks(final BenchmarkGroup group, final int targetBytes) {
  final fixtures = _fixturesBySize.putIfAbsent(targetBytes, () => _buildFixtures(targetBytes));
  final label = formatBytes(fixtures.plain.length);
  group.add(
    'PalmDOC — $label mixed prose',
    () => _unpackAll(fixtures.palmdocRecords, decompressPalmdoc),
    inputBytes: fixtures.plain.length,
    note:
        '${formatBytes(fixtures.palmdocBytes)} compressed · '
        '${fixtures.palmdocRecords.length} records',
  );
  group.add(
    'HUFF/CDIC — $label mixed prose',
    () => _unpackAll(fixtures.huffRecords, _huff.unpack),
    inputBytes: fixtures.plain.length,
    note: 'identity dictionary · ${fixtures.huffRecords.length} records',
  );
}

/// Adds the real HUFF/CDIC label when [_realSamplePath] exists and is
/// HUFF-compressed, or prints a skip note — keeping the suite runnable
/// anywhere, like the real-corpus library fixtures.
void _addRealSampleBenchmark(final BenchmarkGroup group) {
  const name = 'HUFF/CDIC — huffdic real sample';
  final file = File(_realSamplePath);
  if (!file.existsSync()) {
    if (matchesFilter(name)) {
      stdout.writeln(
        '[$name] skipped — no file at $_realSamplePath; drop a '
        'HUFF-compressed .mobi / .azw3 there to enable it.',
      );
    }

    return;
  }

  final pdb = PdbHeader.parse(file.readAsBytesSync());
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  if (header.compressionType != 0x4448 ||
      header.huffRecordCount == 0 ||
      header.textRecordCount < 1) {
    if (matchesFilter(name)) {
      stdout.writeln('[$name] skipped — $_realSamplePath is not HUFF/CDIC compressed.');
    }

    return;
  }

  final huff = HuffReader(<Uint8List>[
    for (var i = header.huffOffset; i < header.huffOffset + header.huffRecordCount; i++)
      pdb.record(i),
  ]);
  final records = <Uint8List>[
    for (var i = 1; i <= header.textRecordCount; i++)
      stripTrailingEntries(pdb.record(i), header.extraFlags),
  ];
  final compressed = records.fold(0, (final sum, final record) => sum + record.length);
  final decompressed = _unpackAll(records, huff.unpack);
  group.add(
    '$name (${formatBytes(decompressed.length)})',
    () => _unpackAll(records, huff.unpack),
    inputBytes: decompressed.length,
    note: '${formatBytes(compressed)} compressed · ${records.length} records',
  );
}

/// The shared synthetic HUFF/CDIC reader, built once like a real book
/// builds it (one reader per file, many records unpacked through it).
HuffReader get _huff => _huffReader ??= HuffReader(<Uint8List>[buildHuffHeader(), buildCdic()]);

/// Decodes every record through [unpack] and joins the output, the
/// same shape `extractMobiText` uses when reading a book.
Uint8List _unpackAll(final List<Uint8List> records, final Uint8List Function(Uint8List) unpack) {
  final builder = BytesBuilder(copy: false);
  for (final record in records) {
    builder.add(unpack(record));
  }

  return builder.takeBytes();
}

/// Prepares one size point: the prose, its PalmDOC-compressed records
/// and its HUFF/CDIC records, each verified to round-trip untimed.
_ProseFixtures _buildFixtures(final int targetBytes) {
  final plain = _proseBytes(targetBytes);
  final records = _splitTextRecords(plain);
  final palmdocRecords = <Uint8List>[for (final record in records) _compressPalmdoc(record)];
  _verifyRoundTrip('PalmDOC', plain, palmdocRecords, decompressPalmdoc);
  _verifyRoundTrip('HUFF/CDIC', plain, records, _huff.unpack);

  return _ProseFixtures(plain: plain, palmdocRecords: palmdocRecords, huffRecords: records);
}

/// Builds [targetBytes] of mixed prose by repeating the plain text of
/// the largest EPUB fixture chapter, trimming the tail to a word
/// boundary so records end on readable text.
Uint8List _proseBytes(final int targetBytes) {
  final base = plainTextSample;
  if (base == null || base.isEmpty) {
    throw StateError('No plain text sample available from the EPUB fixtures.');
  }

  final source = Uint8List.fromList(base.codeUnits); // ASCII prose from the EPUB.
  final plain = Uint8List(targetBytes);
  var filled = 0;
  while (filled < targetBytes) {
    final chunk = math.min(source.length, targetBytes - filled);
    plain.setRange(filled, filled + chunk, source);
    filled += chunk;
  }

  var end = targetBytes;
  while (end > 0 && plain[end - 1] != 0x20 && plain[end - 1] != 0x0A) {
    end--;
  }

  return Uint8List.sublistView(plain, 0, end);
}

/// Splits [plain] into MOBI-sized text records.
List<Uint8List> _splitTextRecords(final Uint8List plain) {
  return <Uint8List>[
    for (var start = 0; start < plain.length; start += _textRecordSize)
      Uint8List.sublistView(plain, start, math.min(start + _textRecordSize, plain.length)),
  ];
}

/// Compresses [record] into the PalmDOC token stream — benchmark
/// fixture machinery only; the library itself only ever decompresses.
///
/// A single-slot hash of 3-byte prefixes finds back references
/// (11-bit distance, 3..10 byte copies); literals use the escape form
/// for control bytes 1..8 and non-ASCII bytes, and a space followed
/// by an ASCII letter folds into its single-byte pair form — so
/// spaces are held back one byte until the fold is ruled out.
Uint8List _compressPalmdoc(final Uint8List record) {
  return _PalmDocCompressor(record).compress();
}

final class _PalmDocCompressor {
  _PalmDocCompressor(this._record) : _heads = Int32List(_hashSlots)..fillRange(0, _hashSlots, -1);

  static const int _hashSlots = 1 << 16;

  final Uint8List _record;
  final BytesBuilder _out = BytesBuilder(copy: false);
  final Int32List _heads;
  bool _pendingSpace = false;

  Uint8List compress() {
    var index = 0;
    while (index < _record.length) {
      index = _writeToken(index);
    }
    if (_pendingSpace) _out.addByte(0x20);

    return _out.takeBytes();
  }

  int _writeToken(final int index) {
    final byte = _record[index];
    if (byte == 0x20) return _holdSpace(index);
    if (_tryFoldSpace(byte, index)) return index + 1;
    _flushPendingSpace();

    final match = _findMatch(index);
    if (match != null) return _writeMatch(index, match);
    _writeLiteral(byte);
    _register(index);

    return index + 1;
  }

  int _holdSpace(final int index) {
    if (_pendingSpace) _out.addByte(0x20);
    _pendingSpace = true;
    _register(index);

    return index + 1;
  }

  bool _tryFoldSpace(final int byte, final int index) {
    if (!_pendingSpace || byte < 0x40 || byte > 0x7F) return false;
    _out.addByte(byte | 0x80);
    _register(index);
    _pendingSpace = false;

    return true;
  }

  void _flushPendingSpace() {
    if (!_pendingSpace) return;
    _out.addByte(0x20);
    _pendingSpace = false;
  }

  _PalmDocMatch? _findMatch(final int index) {
    if (index + 3 > _record.length) return null;
    final candidate = _heads[_hash3(index)];
    final distance = index - candidate;
    if (candidate < 0 || distance < 1 || distance > 2047) return null;

    final remaining = _record.length - index;
    final limit = remaining < 10 ? remaining : 10;
    var length = 0;
    while (length < limit && _record[candidate + length] == _record[index + length]) {
      length++;
    }

    if (length < 3) return null;

    return _PalmDocMatch(distance: distance, length: length);
  }

  int _writeMatch(final int index, final _PalmDocMatch match) {
    final pair = (match.distance << 3) | (match.length - 3);
    _out
      ..addByte(0x80 | (pair >> 8))
      ..addByte(pair & 0xFF);
    for (var offset = 0; offset < match.length; offset++) {
      _register(index + offset);
    }

    return index + match.length;
  }

  void _writeLiteral(final int byte) {
    if ((byte >= 0x01 && byte <= 0x08) || byte >= 0x80) {
      // Control bytes 1..8 and raw bytes >= 0x80 need the escape
      // form: `1` copies the following byte verbatim.
      _out
        ..addByte(0x01)
        ..addByte(byte);
    } else {
      _out.addByte(byte);
    }
  }

  void _register(final int index) {
    if (index + 3 <= _record.length) _heads[_hash3(index)] = index;
  }

  int _hash3(final int index) {
    return ((_record[index] * 31 + _record[index + 1]) * 31 + _record[index + 2]) &
        (_hashSlots - 1);
  }
}

final class _PalmDocMatch {
  const _PalmDocMatch({required this.distance, required this.length});

  final int distance;
  final int length;
}

/// Guards the fixture: [unpack] over [records] must reproduce [plain].
void _verifyRoundTrip(
  final String codec,
  final Uint8List plain,
  final List<Uint8List> records,
  final Uint8List Function(Uint8List) unpack,
) {
  final decoded = _unpackAll(records, unpack);
  if (!_sameBytes(decoded, plain)) {
    throw StateError(
      'Synthetic $codec fixture failed to round-trip: '
      '${decoded.length} of ${plain.length} bytes decoded.',
    );
  }
}

bool _sameBytes(final Uint8List a, final Uint8List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }

  return true;
}

/// Prepared fixtures for one prose size point.
final class _ProseFixtures {
  /// Creates fixtures from their parts.
  const _ProseFixtures({
    required this.plain,
    required this.palmdocRecords,
    required this.huffRecords,
  });

  /// The decompressed prose — the decoders' expected output.
  final Uint8List plain;

  /// The prose PalmDOC-compressed, one record per MOBI text record.
  final List<Uint8List> palmdocRecords;

  /// The prose as HUFF/CDIC records (identity dictionary: same bytes).
  final List<Uint8List> huffRecords;

  /// Total size of the compressed PalmDOC payload.
  int get palmdocBytes => palmdocRecords.fold(0, (final sum, final record) => sum + record.length);
}
