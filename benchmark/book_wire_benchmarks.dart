// Benchmarks for the web worker wire codec
// (package:e_livre/src/platform/web/book_wire.dart).
//
// The codec is what a parsed book pays to cross the worker -> main
// thread boundary: [encodeBookWire] flattens a parsed [Book] into a
// JSON map plus the binary blobs it references by index, and
// [decodeBookWire] rebuilds the object graph on the receiving side.
// EPUB books cross as the full package graph; MOBI crosses as its
// parsing inputs (record 0 slice + ident), so the measured decode
// includes the record-0 header re-parse the worker protocol performs.
//
// Each row's extra column reports the encoded payload size (JSON
// string bytes + blob bytes, exactly what travels over postMessage)
// against the original file bytes.

import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// Runs the web wire codec benchmarks.
void runBookWireBenchmarks() {
  final group = BenchmarkGroup('Web wire codec');

  _addGraphWire(group, epubSmall);
  _addGraphWire(group, epubAlice);
  _addGraphWire(group, comicSample);
  _addMobiWire(group, mobi6Alice);
}

/// Times encode / decode for a book whose whole object graph crosses
/// the wire: the [EpubBook] package graph, or comic pages as blobs.
void _addGraphWire(final BenchmarkGroup group, final BookFixture fixture) {
  final book = BookReader.parseBook(fixture.bytes);
  final (json, blobs) = encodeBookWire(book);
  final note = _wireNote(json, blobs, fixture.bytes.length);

  group.add(
    'encodeBookWire — ${fixture.label}',
    () => encodeBookWire(book),
    inputBytes: fixture.bytes.length,
    note: note,
  );
  group.add(
    'decodeBookWire — ${fixture.label}',
    () => decodeBookWire(json, blobs),
    inputBytes: fixture.bytes.length,
    note: note,
  );
}

/// Times the MOBI wire shapes: encode with the record 0 slice + ident,
/// the decode-side header re-parse, and the full roundtrip.
void _addMobiWire(final BenchmarkGroup group, final BookFixture fixture) {
  final book = BookReader.parseBook(fixture.bytes) as MobiBook;
  final pdb = PdbHeader.parse(fixture.bytes);
  final record0 = pdb.record(0);
  final ident = pdb.ident;
  final (json, blobs) = encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);
  final note = _wireNote(json, blobs, fixture.bytes.length);

  group.add(
    'encodeBookWire — ${fixture.label}',
    () => encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident),
    inputBytes: fixture.bytes.length,
    note: note,
  );
  group.add(
    'decodeBookWire — ${fixture.label}',
    () => decodeBookWire(json, blobs),
    inputBytes: fixture.bytes.length,
    note: note,
  );
  group.add(
    'wire roundtrip — ${fixture.label}',
    () {
      final (json, blobs) = encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);

      return decodeBookWire(json, blobs);
    },
    inputBytes: fixture.bytes.length,
    note: note,
  );
}

/// Sizes the wire payload the way the worker transport does (JSON
/// string plus the indexed blobs) and compares it to the file bytes.
String _wireNote(
  final Map<String, Object?> json,
  final List<Uint8List> blobs,
  final int fileBytes,
) {
  final jsonBytes = convert.utf8.encode(encodeJson(json)).length;
  var blobBytes = 0;
  for (final blob in blobs) {
    blobBytes += blob.length;
  }
  final total = jsonBytes + blobBytes;
  final factor = (total / fileBytes).toStringAsFixed(fileBytes < total ? 2 : 3);

  return 'wire ${formatBytes(total)} = json ${formatBytes(jsonBytes)} '
      '+ blobs ${formatBytes(blobBytes)} · $factor× file';
}
