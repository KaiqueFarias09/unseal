/// Builds RAR 5 archives with compressed entries for Unseal's test
/// fixtures and oracle comparisons.
///
/// The encoder emits algorithm-version-0 streams with fixed-length
/// canonical Huffman tables, a greedy LZ matcher, and the delta / E8 /
/// E8-E9 / ARM filters. Correctness is checked externally: generated
/// fixtures must decode byte-identically through rardecode (Go) and
/// libarchive (see `tool/rar5_compare.dart`) — two independent
/// decoders. This tool is not trusted by itself.
///
/// Usage: `dart run tool/rar5_pack.dart --out build/rar5-fixtures`
/// writes one `.cbr` per fixture plus `manifest.json` with sizes, the
/// SHA-256 of every entry's decoded content, and the stream knobs.
library;

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'rar5_stream_encoder.dart';

void main(final List<String> arguments) {
  var outDir = 'build/rar5-fixtures';
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--out' && i + 1 < arguments.length) {
      outDir = arguments[++i];
    }
  }

  final directory = Directory(outDir);
  if (!directory.existsSync()) directory.createSync(recursive: true);

  final fixtures = buildFixtures();
  final manifest = <Map<String, Object>>[];
  for (final fixture in fixtures) {
    final file = File('${directory.path}/${fixture.name}');
    file.writeAsBytesSync(fixture.archive);
    manifest.add({
      'file': fixture.name,
      'bytes': fixture.archive.length,
      'sha256': _sha256Hex(fixture.archive),
      'method': fixture.method,
      'dictExp': fixture.dictExp,
      'filters': fixture.filters,
      'entries': [
        for (final entry in fixture.entries)
          {'name': entry.name, 'bytes': entry.content.length, 'sha256': _sha256Hex(entry.content)},
      ],
    });
    stdout.writeln(
      '${fixture.name}: ${fixture.archive.length} bytes, '
      '${fixture.entries.length} entries, filters ${fixture.filters}',
    );
  }

  File(
    '${directory.path}/manifest.json',
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(manifest)}\n');
  stdout.writeln('wrote ${fixtures.length} fixtures to $outDir');
}

final class Fixture {
  Fixture(this.name, this.entries, this.archive, this.method, this.dictExp, this.filters);

  final String name;
  final List<FixtureEntry> entries;
  final Uint8List archive;
  final int method;
  final int dictExp;
  final List<String> filters;
}

List<Fixture> buildFixtures() {
  final compressible = _compressibleData(96 * 1024, seed: 0x5A5A);
  final jpegish = _jpegishData(48 * 1024, seed: 0xC0FFEE);
  final text = _textData(64 * 1024, seed: 7);

  final fixtures = <Fixture>[];

  // One fixture per compression method: the stream format is identical
  // across methods 1-5, the header field carries the level.
  for (var method = 1; method <= 5; method++) {
    final entries = [
      FixtureEntry('data-$method.bin', compressible),
      FixtureEntry('image-$method.jpg', jpegish),
    ];
    final archive = buildRar5Archive(entries: entries, method: method, dictExp: 0);
    fixtures.add(Fixture('rar5-m$method.cbr', entries, archive, method, 0, const []));
  }

  // Dictionary sizes across the subset, including both edges.
  for (final (exp, label) in [(0, '128k'), (3, '1m'), (9, '64m')]) {
    final entries = [FixtureEntry('dict-$label.bin', compressible)];
    final archive = buildRar5Archive(entries: entries, method: 3, dictExp: exp);
    fixtures.add(Fixture('rar5-dict-$label.cbr', entries, archive, 3, exp, const []));
  }

  // One fixture per filter, with pre-filter content crafted so the
  // transform matters and the decoded output differs from the stream.
  final filterCases = <(String, int, Uint8List)>[
    ('delta', 0, _deltaPreImage(16 * 1024, seed: 11)),
    ('e8', 1, _e8PreImage(16 * 1024, seed: 12)),
    ('e8e9', 2, _e8PreImage(16 * 1024, seed: 13, e9Too: true)),
    ('arm', 3, _armPreImage(16 * 1024, seed: 14)),
  ];
  for (final (label, filterType, preImage) in filterCases) {
    // The stream encodes the pre-image; the archive declares the
    // FILTERED target, so the manifest records the target's digest.
    final probe = Rar5StreamEncoder(preImage, windowSize: 0x20000, filterType: filterType)
      ..encode();
    final target = probe.target;
    final archive = buildRar5Archive(
      entries: [FixtureEntry('filtered-$label.bin', preImage)],
      method: 4,
      dictExp: 0,
      filterType: filterType,
    );
    final entries = [FixtureEntry('filtered-$label.bin', target)];
    fixtures.add(Fixture('rar5-filter-$label.cbr', entries, archive, 4, 0, [label]));
  }

  // A mixed comic: UTF-8 paths, ComicInfo.xml, several pages, declared
  // CRCs.
  final comicEntries = <FixtureEntry>[
    FixtureEntry('ComicInfo.xml', convert.utf8.encode(_comicInfoXml)),
    FixtureEntry('Páginas/001 – título.jpg', _jpegishData(24 * 1024, seed: 21)),
    FixtureEntry('Páginas/002 – título.jpg', _jpegishData(24 * 1024, seed: 22)),
    FixtureEntry('Páginas/003 – título.txt', text),
  ];
  final comicArchive = buildRar5Archive(entries: comicEntries, method: 3, dictExp: 3);
  fixtures.add(Fixture('rar5-comic-utf8.cbr', comicEntries, comicArchive, 3, 3, const []));

  return fixtures;
}

const String _comicInfoXml =
    '<?xml version="1.0"?><ComicInfo><Series>RAR5 Fixtures</Series>'
    '<Number>1</Number><Title>UTF-8 pages</Title><Manga>No</Manga></ComicInfo>';

// Sample content generators (pre-filter bytes).

Uint8List _deltaPreImage(final int length, {required final int seed}) {
  final data = Uint8List(length);
  var state = seed;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    // Smooth-ish ramp with low-amplitude noise compresses and shows
    // the per-channel transform clearly.
    data[i] = ((i * 3) + (state & 7)) & 0xFF;
  }

  return data;
}

Uint8List _e8PreImage(final int length, {required final int seed, final bool e9Too = false}) {
  final data = Uint8List(length);
  var state = seed;
  var i = 0;
  while (i < length) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    if (i + 5 <= length && state % 8 == 0) {
      data[i] = e9Too && state % 16 == 0 ? 0xE9 : 0xE8;
      // Small positive addresses: the subtract branch always applies.
      final address = state % 0x400000;
      data[i + 1] = address & 0xFF;
      data[i + 2] = (address >> 8) & 0xFF;
      data[i + 3] = (address >> 16) & 0xFF;
      data[i + 4] = (address >> 24) & 0xFF;
      i += 5;
    } else {
      data[i] = state & 0xFF;
      i++;
    }
  }

  return data;
}

Uint8List _armPreImage(final int length, {required final int seed}) {
  final data = Uint8List(length);
  var state = seed;
  var i = 0;
  while (i < length) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    if (i + 4 <= length && state % 6 == 0) {
      data[i + 3] = 0xEB;
      final value = state % 0x800000;
      data[i] = value & 0xFF;
      data[i + 1] = (value >> 8) & 0xFF;
      data[i + 2] = (value >> 16) & 0xFF;
      i += 4;
    } else {
      data[i] = state & 0xFF;
      i++;
    }
  }

  return data;
}

Uint8List _compressibleData(final int length, {required final int seed}) {
  final data = Uint8List(length);
  final pattern = Uint8List(4096);
  var state = seed;
  for (var i = 0; i < pattern.length; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    pattern[i] = state & 0xFF;
  }
  var position = 0;
  while (position < length) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    final run = 16 + state % 512;
    final source = state % 2 == 0 ? 0 : (state ~/ 2) % (pattern.length - run);
    for (var i = 0; i < run && position < length; i++) {
      data[position++] = pattern[source + i];
    }
  }

  return data;
}

Uint8List _jpegishData(final int length, {required final int seed}) {
  final data = Uint8List(length);
  data[0] = 0xFF;
  data[1] = 0xD8;
  data[2] = 0xFF;
  data[3] = 0xE0;
  var state = seed;
  for (var i = 8; i < length - 2; i++) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    // Chunky structure: long runs of similar bytes compress well.
    data[i] = state % 97 == 0 ? state & 0xFF : ((i ~/ 24) * 7) & 0xFF;
  }
  data[length - 2] = 0xFF;
  data[length - 1] = 0xD9;

  return data;
}

Uint8List _textData(final int length, {required final int seed}) {
  final words = [
    'quadro ',
    'história ',
    'narração ',
    'leitura ',
    'página ',
    'tradução ',
    'biblioteca ',
    'janela ',
    'rodapé ',
    'capítulo ',
  ];
  final buffer = BytesBuilder();
  var state = seed;
  var written = 0;
  while (written < length) {
    state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
    final word = convert.utf8.encode(words[state % words.length]);
    buffer.add(word);
    written += word.length;
  }

  return buffer.takeBytes();
}

String _sha256Hex(final Uint8List bytes) => crypto.sha256.convert(bytes).toString();
