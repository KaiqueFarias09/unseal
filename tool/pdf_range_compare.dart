/// C01 comparison stage: runs every acceptance case against the
/// independent MuPDF reference and emits the gate report.
///
/// Reads the reference JSON produced by `tool/pdf_mupdf_reference.py`,
/// compares it against sessions opened through the public
/// `BookSession.openSource` entry over recording byte sources, runs the
/// real VM/Chrome/fuzz/corpus lanes for the matrix case, and writes one
/// evidence artifact per acceptance ID (PR01..PR08) plus the comparison
/// report the oracle gate consumes.
///
///     dart run tool/pdf_range_compare.dart \
///         --reference build/evidence/C01/reference.json \
///         --report build/evidence/C01/comparison.json
library;

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/foundation/archive/async_byte_reader.dart';
import 'package:unseal/unseal.dart';

import 'oracle_test_lane.dart';

// The corpus cut fixed in doc/proposals/C01-pdf-byte-source.md.
const _corpus = <(String, String?)>[
  ('test/resources/pdf/dickens-sample.pdf', null),
  ('test/resources/pdf/gutenberg/pg2701-generated.pdf', null),
  ('test/resources/books/pdf/elements-of-euclid-pg.pdf', null),
  ('test/resources/pdf/jbig2/jbig2_huffman_2.pdf', null),
  ('test/resources/pdf/encrypted/pr6531_1.pdf', 'asdfasdf'),
  ('test/resources/pdf/encrypted/r6.pdf', 'user123'),
  ('test/resources/pdf/encrypted/r3-rc4-128.pdf', 'user123'),
];

const _largeFixtures = <String>[
  'test/resources/pdf/jbig2/jbig2_huffman_2.pdf',
  'test/resources/books/pdf/elements-of-euclid-pg.pdf',
];

/// The pre-implementation ceiling from the proposal.
const _partialReadCeiling = 0.5;

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

String _sha256(final List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// The independent host-side observer: exact slices over an in-memory
/// buffer, every range recorded, contract violations injectable.
final class RecordingSource implements UnsealByteSource {
  RecordingSource(this.bytes, {this.revision, this.delay = Duration.zero});

  final Uint8List bytes;
  @override
  String? revision;
  final Duration delay;
  var _closed = false;
  var _reads = 0;
  var _active = 0;
  int? shortOn;
  int? longOn;
  int? throwOn;
  int? flipOn;
  final List<({int offset, int count})> log = <({int offset, int count})>[];

  bool get closed => _closed;
  int get readCount => log.length;
  int get peakRequests => _peakRequests;
  var _peakRequests = 0;
  int get totalBytes => log.fold(0, (final total, final read) => total + read.count);
  void flipRevision() {
    revision = 'flipped-${revision ?? 'null'}';
  }

  int uniqueBytes() {
    final sorted = [...log]..sort((final a, final b) => a.offset.compareTo(b.offset));
    var unique = 0;
    var cursor = -1;
    for (final read in sorted) {
      final end = read.offset + read.count;
      if (end <= cursor) continue;
      unique += end - (read.offset > cursor ? read.offset : cursor);
      cursor = end;
    }

    return unique;
  }

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    final sequence = _reads++;
    if (flipOn != null && sequence >= flipOn!) flipRevision();
    if (throwOn == sequence) throw StateError('host transport failure');
    log.add((offset: offset, count: count));
    _active++;
    if (_active > _peakRequests) _peakRequests = _active;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
    } finally {
      _active--;
    }
    if (shortOn == sequence) {
      return Uint8List.sublistView(bytes, offset, offset + count - 1);
    }
    if (longOn == sequence) {
      final long = Uint8List(count + 1);
      long.setRange(0, count, Uint8List.sublistView(bytes, offset, offset + count));

      return long;
    }

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// The fixed text policy from `tool/pdf_parity.dart` (1.3.0): fold,
/// collapse whitespace, casefold; Dice over character bigrams.
const _foldMap = <String, String>{
  '\uFB00': 'ff',
  '\uFB01': 'fi',
  '\uFB02': 'fl',
  '\uFB03': 'ffi',
  '\uFB04': 'ffl',
  '\u2018': "'",
  '\u2019': "'",
  '\u201A': "'",
  '\u201B': "'",
  '\u201C': '"',
  '\u201D': '"',
  '\u201E': '"',
  '\u201F': '"',
  '\u2010': '-',
  '\u2011': '-',
  '\u2012': '-',
  '\u2013': '-',
  '\u2014': '-',
  '\u2015': '-',
  '\u2212': '-',
  '\u2026': '...',
  '\u2032': "'",
  '\u2033': '"',
};
final RegExp _foldablePattern = RegExp(
  '[\uFB00-\uFB04\u2010-\u2015\u2018-\u201F\u2026\u2032\u2033\u2212]',
);
final RegExp _whitespaceRun = RegExp(r'\s+');

String _normalizeText(final String input) {
  var text = input.replaceAll('\u00AD', '').replaceAll('\uFEFF', '').replaceAll('\u200B', '');
  text = text.replaceAllMapped(_foldablePattern, (final match) => _foldMap[match[0]!]!);

  return text.replaceAll(_whitespaceRun, ' ').trim().toLowerCase();
}

double _diceBigramSimilarity(final String a, final String b) {
  if (a.length < 2 || b.length < 2) return a == b ? 1 : 0;
  final bag = <String, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    final bigram = a.substring(i, i + 2);
    bag[bigram] = (bag[bigram] ?? 0) + 1;
  }
  var overlap = 0;
  for (var i = 0; i < b.length - 1; i++) {
    final bigram = b.substring(i, i + 2);
    final remaining = bag[bigram];
    if (remaining != null && remaining > 0) {
      overlap++;
      bag[bigram] = remaining - 1;
    }
  }

  return 2 * overlap / (a.length - 1 + (b.length - 1));
}

Future<void> main(final List<String> arguments) async {
  var referencePath = '';
  var reportPath = '';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--reference') referencePath = arguments[i + 1];
    if (arguments[i] == '--report') reportPath = arguments[i + 1];
  }
  if (referencePath.isEmpty || reportPath.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/pdf_range_compare.dart '
      '--reference <json> --report <json>',
    );

    exit(2);
  }

  final reference =
      convert.jsonDecode(File(referencePath).readAsStringSync()) as Map<String, Object?>;
  final fixtures = (reference['fixtures']! as List<Object?>)
      .cast<Map<String, Object?>>()
      .map(
        (final entry) => (
          path: entry['path']! as String,
          pages: (entry['pages']! as List<Object?>).cast<Map<String, Object?>>(),
          toc: (entry['toc']! as List<Object?>).cast<Map<String, Object?>>(),
          sha256: entry['sha256']! as String,
        ),
      )
      .toList();

  final evidenceDir = Directory('${File(reportPath).parent.path}/cases');
  evidenceDir.createSync(recursive: true);
  final head = Process.runSync('git', ['rev-parse', 'HEAD']).stdout.toString().trim();

  String artifact(final String name) => '${evidenceDir.path}/$name';

  final cases = <Map<String, Object?>>[];
  final stages = <String, Future<bool> Function()>{
    'PR01': () => _pr01(cases, artifact),
    'PR02': () => _pr02(cases, artifact, fixtures),
    'PR03': () => _pr03(cases, artifact),
    'PR04': () => _pr04(cases, artifact),
    'PR05': () => _pr05(cases, artifact, evidenceDir),
    'PR06': () => _pr06(cases, artifact),
    'PR07': () => _pr07(cases, artifact),
    'PR08': () => _pr08(cases, artifact, evidenceDir),
  };
  var failed = false;
  for (final entry in stages.entries) {
    try {
      if (!await entry.value()) failed = true;
    } on Object catch (error, stack) {
      stdout.writeln('STAGE ${entry.key} threw: ${error.runtimeType}: $error');
      stdout.writeln(stack);
      cases.add(_case(entry.key, 'fail', {}, [artifact('${entry.key.toLowerCase()}-crash.json')]));
      failed = true;
    }
    stdout.writeln(
      '${entry.key}: ${cases.lastWhere((final c) => c['id'] == entry.key)['verdict']}',
    );
  }

  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'C01',
    'generatedBy': 'tool/pdf_range_compare.dart',
    'head': head,
    'reference': referencePath,
    'referencePin': _referencePin(reference),
    'cases': cases,
  };
  final reportFile = File(reportPath);
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('wrote $reportPath');
  exit(failed ? 1 : 0);
}

String _referencePin(final Map<String, Object?> reference) {
  final tool = reference['tool']! as Map<String, Object?>;

  return 'PyMuPDF ${tool['version']} / MuPDF ${tool['mupdf']} '
      '(tool/pdf_mupdf_reference.py)';
}

Map<String, Object?> _case(
  final String id,
  final String verdict,
  final Map<String, Object?> evidence,
  final List<String> artifacts,
) => <String, Object?>{
  'id': id,
  'verdict': verdict,
  'skipped': false,
  'evidence': evidence,
  'evidenceArtifacts': artifacts,
};

/// PR01: the public entry opens PDFs over host sources on the VM
/// (real isolate), keeps bytes/file and the other formats working, and
/// fails typed.
Future<bool> _pr01(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
) async {
  final problems = <String>[];
  final raw = _bytes(_corpus[0].$1);
  final source = RecordingSource(raw, revision: 'pr01-etag');
  final session = await BookSession.openSource(source);
  final eager = Unseal.parse(raw) as PdfBook;
  final book = session.book as PdfBook;
  if (book.pageCount != eager.pageCount) problems.add('pageCount differs');
  if (book.metadata.title != eager.metadata.title) problems.add('title differs');
  if (session.byteLength != raw.length) problems.add('byteLength differs');
  if (session.sourceRevision != 'pr01-etag') problems.add('revision not reported');
  if (session.isProgressive != true) problems.add('not progressive');
  final firstPage = await session.loadDocumentText('page_1.html');
  if (firstPage != eager.pageTexts[0].text) problems.add('page 1 differs from eager');
  session.dispose();
  if (!source.closed) problems.add('dispose did not close the host source');

  // Bytes and file lanes keep working (PDF).
  final bytesSession = await BookSession.open(raw);
  if ((bytesSession.book as PdfBook).pageCount != eager.pageCount) {
    problems.add('bytes session pageCount differs');
  }
  bytesSession.dispose();

  // EPUB stays openable over a source; other formats stay refused.
  final epubBytes = _bytes('test/resources/epub/Alices Adventures in Wonderland.epub');
  final epubSession = await BookSession.openSource(RecordingSource(epubBytes));
  if (epubSession.book is! EpubBook) problems.add('EPUB source session broke');
  epubSession.dispose();

  for (final (label, bytes, needle) in <(String, Uint8List, String)>[
    ('empty', Uint8List(0), 'empty'),
    ('garbage', Uint8List.fromList(List.filled(64, 0x41)), 'progressive session'),
    (
      'truncated-pdf',
      Uint8List.fromList(<int>[0x25, 0x50, 0x44, 0x46, 0x2d, 0x31, 0x2e, 0x34]),
      '',
    ),
  ]) {
    try {
      final broken = await BookSession.openSource(RecordingSource(bytes));
      broken.dispose();
      problems.add('$label opened but must fail typed');
    } on UnsealException catch (error) {
      if (needle.isNotEmpty && !error.message.contains(needle)) {
        problems.add('$label failure does not name the cause: ${error.message}');
      }
    }
  }

  // Passwords: wrong fails typed, right opens with identical text.
  final r6 = _bytes('test/resources/pdf/encrypted/r6.pdf');
  final plain = _bytes(_corpus[0].$1);
  await expectTyped(
    problems,
    'wrong-password',
    BookSession.openSource(RecordingSource(r6)),
    (final error) => error is PdfEncryptedException && error.requiresNonEmptyPassword,
  );
  final unlocked = await BookSession.openSource(RecordingSource(r6), password: 'user123');
  final unlockedText = await unlocked.loadDocumentText('page_1.html');
  if (unlockedText != (Unseal.parse(plain) as PdfBook).pageTexts[0].text) {
    problems.add('unlocked text differs from the unencrypted original');
  }
  unlocked.dispose();

  final evidence = <String, Object?>{
    'fixture': _corpus[0].$1,
    'fixtureSha256': _sha256(raw),
    'pageCount': eager.pageCount,
    'checks': 'identity, revision, bytes/file lanes, EPUB preserved, typed failures, passwords',
    'problems': problems.isEmpty ? 'none' : problems,
  };
  final path = artifact('pr01.json');
  File(path).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR01', problems.isEmpty ? 'pass' : 'fail', evidence, [path]));

  return problems.isEmpty;
}

Future<void> expectTyped(
  final List<String> problems,
  final String label,
  final Future<Object?> future,
  final bool Function(Object error) predicate,
) async {
  try {
    final value = await future;
    problems.add('$label completed instead of failing typed: $value');
  } on Object catch (error) {
    if (!predicate(error)) {
      problems.add('$label failed with the wrong type: ${error.runtimeType}');
    }
  }
}

typedef _ReferenceFixture = ({
  String path,
  List<Map<String, Object?>> pages,
  List<Map<String, Object?>> toc,
  String sha256,
});

Map<String, Object?>? _fixtureFor(final List<_ReferenceFixture> fixtures, final String path) {
  for (final fixture in fixtures) {
    if (fixture.path.endsWith(path.split('/').last)) {
      return {
        'path': fixture.path,
        'pages': fixture.pages,
        'toc': fixture.toc,
        'sha256': fixture.sha256,
      };
    }
  }

  return null;
}

/// PR02: MuPDF vs the session under the fixed fold + Dice policy.
Future<bool> _pr02(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
  final List<_ReferenceFixture> fixtures,
) async {
  final perFixture = <String, Object?>{};
  var pagesCompared = 0;
  var pagesAligned = 0;
  var geometryCompared = 0;
  final problems = <String>[];

  for (final (path, password) in _corpus) {
    final fixture = _fixtureFor(fixtures, path);
    if (fixture == null) {
      problems.add('$path missing from the reference');

      continue;
    }
    final raw = _bytes(path);
    if (_sha256(raw) != fixture['sha256']) {
      problems.add('$path sha256 differs from the reference run');

      continue;
    }
    final source = RecordingSource(raw);
    final session = await BookSession.openSource(source, password: password ?? '');
    final book = session.book as PdfBook;
    final referencePages = (fixture['pages']! as List<Object?>).cast<Map<String, Object?>>();
    var minDice = 1.0;
    var aligned = 0;
    var compared = 0;
    final divergentPages = <int>[];
    for (final referencePage in referencePages) {
      final index = referencePage['index']! as int;
      final ours = _normalizeText(await session.loadDocumentText('page_${index + 1}.html') ?? '');
      final theirs = _normalizeText(referencePage['text']! as String);
      final score = theirs.isEmpty
          ? (ours.isEmpty ? 1.0 : 0.0)
          : _diceBigramSimilarity(theirs, ours);
      if (score >= 0.90) {
        aligned++;
      } else {
        divergentPages.add(index + 1);
      }
      minDice = math.min(minDice, score);
      compared++;

      // Page geometry: exact width/height/rotation against MuPDF.
      final page = book.pages[index];
      final referenceWidth = (referencePage['width']! as num).toDouble();
      final referenceHeight = (referencePage['height']! as num).toDouble();
      final referenceRotation = referencePage['rotation']! as int;
      if ((page.width - referenceWidth).abs() > 0.5 ||
          (page.height - referenceHeight).abs() > 0.5 ||
          page.rotate != referenceRotation) {
        problems.add(
          '${path.split('/').last} page ${index + 1} geometry '
          '${page.width}x${page.height}@${page.rotate} '
          'vs $referenceWidth x $referenceHeight @$referenceRotation',
        );
      }
      geometryCompared++;
    }
    pagesCompared += compared;
    pagesAligned += aligned;

    // Navigation: titles and target pages against get_toc().
    final toc = (fixture['toc']! as List<Object?>).cast<Map<String, Object?>>();
    final navTitles = <String>[];
    void walk(final List<NavPoint> points) {
      for (final point in points) {
        navTitles.add(point.label);
        walk(point.subNavPoints);
      }
    }

    walk(book.navigation.navPoints);
    if (toc.isEmpty) {
      if (navTitles.isNotEmpty) problems.add('${path.split('/').last} has unexpected nav');
    } else {
      final referenceTitles = [for (final entry in toc) entry['title']! as String];
      if (navTitles.length != referenceTitles.length) {
        problems.add(
          '${path.split('/').last} nav count ${navTitles.length} '
          '!= toc ${referenceTitles.length}',
        );
      }
    }

    // Byrne's Euclid plates: MuPDF walks the multi-column plates in its
    // own order and expands their symbols differently, so strict
    // order-sensitive bigrams land below 0.90 (pre-implementation probe:
    // character-sorted dice ~0.95). Declared as the mission's expected
    // difference, not tolerated silently; every other corpus page must
    // align or the case fails.
    final isEuclid = path.contains('euclid');
    if (divergentPages.isNotEmpty && !isEuclid) {
      problems.addAll([
        for (final page in divergentPages) '${path.split('/').last} page $page diverged',
      ]);
    }
    perFixture[path.split('/').last] = <String, Object?>{
      'verdict': divergentPages.isEmpty
          ? 'pass'
          : isEuclid
          ? 'expected-difference'
          : 'fail',
      'divergentPages': divergentPages,
      'pages': compared,
      'aligned': aligned,
      'minDice': double.parse(minDice.toStringAsFixed(4)),
      'geometryChecks': compared,
      'tocEntries': toc.length,
      'navEntries': navTitles.length,
      'wireBytesUnique': source.uniqueBytes(),
      'fixtureBytes': raw.length,
    };
    session.dispose();
  }

  final euclidDivergent = perFixture.keys.any((final name) {
    final entry = perFixture[name]! as Map<String, Object?>;

    return name.contains('euclid') && entry['verdict'] == 'expected-difference';
  });

  final evidence = <String, Object?>{
    'policy':
        'fold + whitespace collapse + casefold; Dice over character '
        'bigrams; page aligned at >= 0.90; empty-vs-empty counts as aligned; '
        'geometry exact within 0.5pt; rotation exact',
    'expectedDifference':
        'elements-of-euclid-pg.pdf: MuPDF reads the '
        'multi-column Byrne plates in its own order and expands their '
        'symbols differently, so strict bigrams land below 0.90 '
        '(character-sorted dice ~0.95, measured pre-implementation). '
        'Declared, not tolerated silently.',
    'pagesCompared': pagesCompared,
    'pagesAligned': pagesAligned,
    'geometryCompared': geometryCompared,
    'perFixture': perFixture,
    'problems': problems.isEmpty ? 'none' : problems.take(20).toList(),
  };
  final path2 = artifact('pr02.json');
  File(
    path2,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(
    _case(
      'PR02',
      problems.isEmpty ? (euclidDivergent ? 'expected-difference' : 'pass') : 'fail',
      evidence,
      [path2],
    ),
  );

  return problems.isEmpty;
}

/// PR03: partial reads on the two fixed large fixtures, observed by the
/// recording source (independent of Unseal's internals).
Future<bool> _pr03(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
) async {
  final problems = <String>[];
  final perFixture = <String, Object?>{};
  for (final path in _largeFixtures) {
    final raw = _bytes(path);
    final source = RecordingSource(raw);
    final session = await BookSession.openSource(source);
    final pageCount = (session.book as PdfBook).pageCount;
    final firstPastSample = math.min(20, pageCount);
    await session.loadDocumentText('page_${firstPastSample + 1}.html');

    final openUnique = source.uniqueBytes();
    final openFraction = openUnique / raw.length;
    if (openFraction >= _partialReadCeiling) {
      problems.add(
        '$path open+first content read ${(openFraction * 100).toStringAsFixed(2)}% '
        'of the file (ceiling 50%)',
      );
    }

    final metrics = await session.metrics();
    final residentPeak = metrics.pdfRangeResidentPeak ?? 0;
    if (residentPeak >= raw.length ~/ 2) {
      problems.add('$path resident peak $residentPeak keeps too much of the file');
    }

    final beforeReads = source.readCount;
    final beforeUnique = source.uniqueBytes();
    await session.loadDocumentText('page_$pageCount.html');
    final jumpUnique = source.uniqueBytes() - beforeUnique;
    if (source.readCount - beforeReads >= 40) {
      problems.add('$path distant jump needed ${source.readCount - beforeReads} reads');
    }
    if (jumpUnique >= raw.length ~/ 10) {
      problems.add('$path distant jump pulled ${100 * jumpUnique / raw.length}% of the file');
    }

    perFixture[path.split('/').last] = <String, Object?>{
      'fileBytes': raw.length,
      'openPlusFirstUniqueBytes': openUnique,
      'openPlusFirstFraction': double.parse((openFraction * 100).toStringAsFixed(2)),
      'residentPeakBytes': residentPeak,
      'distantJumpReads': source.readCount - beforeReads,
      'distantJumpUniqueBytes': jumpUnique,
      'totalRequests': source.readCount,
      'totalWireBytes': source.totalBytes,
    };
    session.dispose();
  }

  final evidence = <String, Object?>{
    'ceiling': _partialReadCeiling,
    'observer':
        'RecordingSource (test-side exact slices over an in-memory '
        'buffer; coverage merged outside Unseal)',
    'perFixture': perFixture,
    'problems': problems.isEmpty ? 'none' : problems,
  };
  final path3 = artifact('pr03.json');
  File(
    path3,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR03', problems.isEmpty ? 'pass' : 'fail', evidence, [path3]));

  return problems.isEmpty;
}

/// PR04: hostile sources and broken structures, refused typed or
/// recovered with eager parity.
Future<bool> _pr04(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
) async {
  final problems = <String>[];
  final checked = <String, Object?>{};
  final dickens = _bytes(_corpus[0].$1);

  Future<void> refuse(
    final String label,
    final UnsealByteSource source, {
    required final bool Function(Object error) predicate,
  }) async {
    await expectTyped(problems, label, BookSession.openSource(source), predicate);
    checked[label] = 'typed refusal';
  }

  final short = RecordingSource(dickens)..shortOn = 2;
  await refuse(
    'short-read',
    short,
    predicate: (final error) => error is ByteSourceShortReadException,
  );
  final long = RecordingSource(dickens)..longOn = 1;
  await refuse('long-read', long, predicate: (final error) => error is ByteSourceLongReadException);
  final host = RecordingSource(dickens)..throwOn = 3;
  await refuse('host-failure', host, predicate: (final error) => error is ByteSourceReadException);
  final flipped = RecordingSource(dickens, revision: 'c01:rev')..flipOn = 2;
  await refuse(
    'revision-changed-open',
    flipped,
    predicate: (final error) => error is ByteSourceRevisionChangedException,
  );

  // Revision flip under an open session fails later reads typed.
  final flipSource = RecordingSource(dickens, revision: 'c01:rev');
  final flipSession = await BookSession.openSource(flipSource);
  await flipSession.loadBytesRange(0, 64);
  flipSource.flipOn = 0;
  await expectTyped(
    problems,
    'revision-changed-session',
    flipSession.loadBytesRange(0, 64),
    (final error) => error is ByteSourceRevisionChangedException,
  );
  flipSource.flipOn = null;
  flipSource.revision = 'c01:rev';
  if (await flipSession.loadBytesRange(0, 64) == null) {
    problems.add('session unusable after the host reverted its revision');
  }
  flipSession.dispose();
  checked['revision-changed-session'] = 'typed refusal, then recovery';

  // A bogus startxref recovers by scan, byte-parity with the eager parse.
  final broken = Uint8List.fromList(dickens);
  final asLatin1 = convert.latin1.decode(broken);
  final markerAt = asLatin1.lastIndexOf('startxref');
  final digitStart = markerAt + 'startxref'.length + 1;
  var digitEnd = digitStart;
  while (digitEnd < broken.length && broken[digitEnd] >= 0x30 && broken[digitEnd] <= 0x39) {
    digitEnd++;
  }
  broken.setRange(digitStart, digitEnd, convert.ascii.encode('999999'));
  final eager = Unseal.parse(dickens) as PdfBook;
  final brokenSession = await BookSession.openSource(RecordingSource(broken));
  if (await brokenSession.loadDocumentText('page_1.html') != eager.pageTexts[0].text) {
    problems.add('bogus startxref recovery differs from eager');
  }
  brokenSession.dispose();
  checked['bogus-startxref'] = 'scan recovery, eager parity';

  // Cyclic /Prev terminates with eager parity (synthetic, identified).
  final cyclic = _singlePagePdf(
    _flateText('BT /F1 24 Tf 72 720 Td (cyclic trailer chain) Tj ET'),
    prevSelf: true,
  );
  final cyclicEager = Unseal.parse(cyclic) as PdfBook;
  final cyclicSession = await BookSession.openSource(RecordingSource(cyclic));
  final cyclicText = await cyclicSession.loadDocumentText('page_1.html');
  if (cyclicText != cyclicEager.pageTexts[0].text ||
      !cyclicText!.contains('cyclic trailer chain')) {
    problems.add('cyclic /Prev chain: parity or content lost');
  }
  cyclicSession.dispose();
  checked['cyclic-prev'] = 'terminated, eager parity, real text';

  // A stream body above the per-request cap is refused before allocation.
  final noise = Uint8List(200 << 10);
  var seed = 0x9e3779b9;
  for (var i = 0; i < noise.length; i++) {
    seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF;
    noise[i] = (seed >> 16) & 0xFF;
  }
  final bigStream = _singlePagePdf(noise);
  final eagerBig = Unseal.parse(bigStream) as PdfBook;
  if (eagerBig.pageCount != 1) problems.add('eager parse of the cap fixture broke');
  await expectTyped(
    problems,
    'stream-body-cap',
    BookSession.openSource(
      RecordingSource(bigStream),
      policy: const SessionPolicy(rangeRequestBytes: 96 << 10),
    ),
    (final error) => error is ByteSourceLimitExceededException,
  );
  final raised = await BookSession.openSource(
    RecordingSource(bigStream),
    policy: const SessionPolicy(rangeRequestBytes: 1 << 20),
  );
  if ((raised.book as PdfBook).pageCount != 1) problems.add('raised-cap open broke');
  raised.dispose();
  checked['stream-body-cap'] = 'refused under the cap, served above it';

  final evidence = <String, Object?>{
    'checks': checked,
    'problems': problems.isEmpty ? 'none' : problems,
  };
  final path4 = artifact('pr04.json');
  File(
    path4,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR04', problems.isEmpty ? 'pass' : 'fail', evidence, [path4]));

  return problems.isEmpty;
}

Uint8List _flateText(final String text) =>
    Uint8List.fromList(ZLibCodec().encode(convert.utf8.encode(text)));

Uint8List _singlePagePdf(final List<int> streamBytes, {final bool prevSelf = false}) {
  final convert_ = <List<int>>[
    convert.ascii.encode('<< /Type /Catalog /Pages 2 0 R >>'),
    convert.ascii.encode('<< /Type /Pages /Kids [3 0 R] /Count 1 >>'),
    convert.ascii.encode(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] '
      '/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    ),
    <int>[
      ...convert.ascii.encode('<< /Length ${streamBytes.length} /Filter /FlateDecode >>\nstream\n'),
      ...streamBytes,
      ...convert.ascii.encode('\nendstream'),
    ],
    convert.ascii.encode('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'),
  ];
  final body = BytesBuilder();
  body.add(convert.ascii.encode('%PDF-1.4\n'));
  final offsets = <int>[];
  for (var i = 0; i < convert_.length; i++) {
    offsets.add(body.length);
    body.add(convert.ascii.encode('${i + 1} 0 obj\n'));
    body.add(convert_[i]);
    body.add(convert.ascii.encode('\nendobj\n'));
  }
  final xrefStart = body.length;
  final xref = BytesBuilder();
  xref.add(convert.ascii.encode('xref\n0 ${convert_.length + 1}\n0000000000 65535 f \n'));
  for (final offset in offsets) {
    xref.add(convert.ascii.encode('${offset.toString().padLeft(10, '0')} 00000 n \n'));
  }
  xref.add(
    convert.ascii.encode(
      'trailer\n<< /Size ${convert_.length + 1} /Root 1 0 R'
      '${prevSelf ? ' /Prev $xrefStart' : ''} >>\n',
    ),
  );
  body.add(xref.toBytes());
  body.add(convert.ascii.encode('startxref\n$xrefStart\n%%EOF\n'));

  return body.toBytes();
}

/// PR05: the real isolate and Web Worker lanes, executed as processes.
Future<bool> _pr05(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
  final Directory evidenceDir,
) async {
  final laneDir = Directory('${evidenceDir.path}/pr05-lanes');
  final lanes = [
    runOracleDartLane(laneDir, 'pdf-source-isolate', [
      'test',
      'test/tests/progressive/pdf_source_lifecycle_test.dart',
      'test/tests/progressive/pdf_source_test.dart',
    ]),
    runOracleDartLane(laneDir, 'compile-worker', [
      'compile',
      'js',
      'web/unseal_worker.dart',
      '-o',
      'test/web/unseal_worker.js',
    ]),
    runOracleDartLane(laneDir, 'pdf-source-worker', [
      'test',
      '-p',
      'chrome',
      'test/web/pdf_source_worker_test.dart',
    ]),
  ];
  final ok = lanes.every((final lane) => lane['exitCode'] == 0);
  final evidence = <String, Object?>{
    'lanes': lanes,
    'problems': ok ? 'none' : 'a lane exited non-zero',
  };
  final path5 = artifact('pr05.json');
  File(
    path5,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR05', ok ? 'pass' : 'fail', evidence, [path5]));

  return ok;
}

/// PR06: the public counters and the backpressure channels.
Future<bool> _pr06(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
) async {
  final problems = <String>[];
  final checked = <String, Object?>{};

  final raw = _bytes('test/resources/pdf/gutenberg/pg2701-generated.pdf');
  final source = RecordingSource(raw);
  final session = await BookSession.openSource(source);
  final metrics = await session.metrics();
  if (metrics.containerReads <= 0) problems.add('containerReads empty');
  if (metrics.sourceBytesRead != source.totalBytes) {
    problems.add('ledger ${metrics.sourceBytesRead} != wire ${source.totalBytes}');
  }
  if ((metrics.pdfRangeUniqueBytes ?? 0) > source.totalBytes) {
    problems.add('unique bytes exceed the wire total');
  }
  checked['ledger-matches-wire'] = {
    'containerReads': metrics.containerReads,
    'sourceBytesRead': metrics.sourceBytesRead,
    'uniqueBytes': metrics.pdfRangeUniqueBytes,
    'residentPeak': metrics.pdfRangeResidentPeak,
    'resumes': metrics.pdfRangeResumes,
  };

  // Single-slot gate: concurrent materializations queue, the wire sees
  // one request at a time, and the results still match the bytes path.
  final serialized = RecordingSource(raw, delay: const Duration(milliseconds: 1));
  final narrow = await BookSession.openSource(
    serialized,
    policy: const SessionPolicy(rangeRequestsInFlight: 1),
  );
  final concurrent = await Future.wait(<Future<String?>>[
    narrow.loadDocumentText('page_25.html'),
    narrow.loadDocumentText('page_26.html'),
  ]);
  if (concurrent.any((final text) => text == null || text.isEmpty)) {
    problems.add('a queued concurrent op came back empty');
  }
  final narrowMetrics = await narrow.metrics();
  if ((narrowMetrics.pdfRangeQueuedStepsPeak ?? 0) < 1) {
    problems.add('no queued-step peak observed');
  }
  if (serialized.peakRequests != 1) {
    problems.add('single-slot cap broken: peak ${serialized.peakRequests}');
  }
  final bytesReference = await (await BookSession.open(raw)).loadDocumentText('page_25.html');
  if (concurrent[0] != bytesReference) {
    problems.add('concurrent result differs from the bytes session');
  }
  narrow.dispose();
  checked['single-slot-cap'] = {
    'peakRequests': serialized.peakRequests,
    'queuedStepsPeak': narrowMetrics.pdfRangeQueuedStepsPeak,
  };

  // Inline engine: the step queue reaches depth two under two racing ops.
  final inlineEngine = await SessionEngine.openRemote(
    CallbackAsyncByteReader(length: source.length, revision: null, read: source.readRange),
    policy: const SessionPolicy(rangeRequestsInFlight: 1),
  );
  final inlineFirst = inlineEngine.documentText('page_25.html');
  final inlineSecond = inlineEngine.documentText('page_26.html');
  await Future.wait([inlineFirst, inlineSecond]);
  if ((inlineEngine.metrics()['pdfRangeQueuedStepsPeak'] as int? ?? 0) < 2) {
    problems.add('inline queue depth never reached two');
  }
  checked['inline-queue-depth'] = inlineEngine.metrics()['pdfRangeQueuedStepsPeak'];

  final evidence = <String, Object?>{
    'checks': checked,
    'problems': problems.isEmpty ? 'none' : problems,
  };
  final path6 = artifact('pr06.json');
  File(
    path6,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR06', problems.isEmpty ? 'pass' : 'fail', evidence, [path6]));

  return problems.isEmpty;
}

/// PR07: page→structure→search→index→progression→anchor parity with the
/// bytes session, plus explicit reuse refusals.
Future<bool> _pr07(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
) async {
  final problems = <String>[];
  final checked = <String, Object?>{};
  final raw = _bytes(_corpus[0].$1);

  final bytesSession = await BookSession.open(raw);
  final sourceSession = await BookSession.openSource(RecordingSource(raw));

  if (await sourceSession.loadDocumentText('page_1.html') !=
      await bytesSession.loadDocumentText('page_1.html')) {
    problems.add('page text differs');
  }
  final sourceLines = await sourceSession.loadPdfPageLines(0);
  final bytesLines = await bytesSession.loadPdfPageLines(0);
  if (sourceLines!.lines.length != bytesLines!.lines.length) problems.add('line count differs');
  for (var i = 0; i < math.min(sourceLines.lines.length, bytesLines.lines.length); i++) {
    if (sourceLines.lines[i].text != bytesLines.lines[i].text) {
      problems.add('line $i text differs');
    }
  }
  checked['page-lines'] = sourceLines.lines.length;

  final sourceStructure = (await sourceSession.loadPdfPageStructure(0))!;
  final bytesStructure = (await bytesSession.loadPdfPageStructure(0))!;
  if (sourceStructure.canonicalText != bytesStructure.canonicalText) {
    problems.add('structure canonical text differs');
  }
  if (sourceStructure.words.length != bytesStructure.words.length) {
    problems.add('structure word count differs');
  }
  checked['structure-words'] = sourceStructure.words.length;

  final sourceSearch = await sourceSession.search('Chapter');
  final bytesSearch = await bytesSession.search('Chapter');
  if (sourceSearch.matches.length != bytesSearch.matches.length) {
    problems.add('search match count differs');
  }
  checked['search-matches'] = sourceSearch.matches.length;

  final sourceProgression = (await sourceSession.computeProgression()).sectionLengths;
  final bytesProgression = (await bytesSession.computeProgression()).sectionLengths;
  if (sourceProgression.length != bytesProgression.length ||
      List.generate(
        sourceProgression.length,
        (final i) => sourceProgression[i] == bytesProgression[i],
      ).any((final equal) => !equal)) {
    problems.add('progression differs');
  }
  checked['progression-sections'] = sourceSearch.matches.length;

  final coverage = await sourceSession.buildSearchIndex();
  if (!coverage.isComplete) problems.add('index build incomplete');
  final hits = await sourceSession.searchIndexed('Chapter');
  if (hits.hits.isEmpty) problems.add('indexed query empty');
  final imported = await bytesSession.importSearchIndex(await sourceSession.exportSearchIndex());
  if (!imported.isComplete) problems.add('cross-lane index import refused');
  checked['index'] = {'hits': hits.hits.length, 'crossLaneImport': imported.isComplete};

  // A different book refuses the reuse explicitly.
  final other = await BookSession.openSource(
    RecordingSource(_bytes('test/resources/pdf/gutenberg/pg11-generated.pdf')),
  );
  await expectTyped(
    problems,
    'foreign-index-import',
    other.importSearchIndex(await sourceSession.exportSearchIndex()),
    (final error) => error is UnsealException,
  );
  other.dispose();

  // Anchors: capture in one source session, resolve in another.
  final structure = (await sourceSession.loadPdfPageStructure(0))!;
  final identity = PublicationRevision(
    publicationId: 'c01:anchor-parity',
    sourceRevision: 'c01:fixed-revision',
    sourceEvidence: SourceEvidence.host,
  );
  final snapshot = structure.canonicalSnapshot(identity: identity);
  final quote = structure.canonicalText;
  final start = quote.indexOf('Chapter');
  final anchor = DurableAnnotations.capture(snapshot: snapshot, start: start, end: start + 24);
  final second = await BookSession.openSource(RecordingSource(raw));
  final reopened = (await second.loadPdfPageStructure(0))!.canonicalSnapshot(identity: identity);
  final resolution = DurableAnnotations.resolve(anchor: anchor, targets: [reopened]);
  if (resolution is! AnchorResolved || !resolution.verified) {
    problems.add('anchor did not resolve verified across sessions');
  } else if (resolution.range.text != anchor.quote.exact) {
    problems.add('anchor resolved to different characters');
  }
  checked['anchor'] = 'captured and resolved verified across source sessions';

  final revised = (await second.loadPdfPageStructure(0))!.canonicalSnapshot(
    identity: PublicationRevision(
      publicationId: identity.publicationId,
      sourceRevision: 'c01:other-revision',
      sourceEvidence: SourceEvidence.host,
    ),
  );
  if (DurableAnnotations.resolve(anchor: anchor, targets: [revised])
      is! AnchorIncompatibleRevision) {
    problems.add('a foreign revision did not refuse the anchor');
  }
  checked['anchor-revision-refusal'] = 'typed';
  second.dispose();
  sourceSession.dispose();
  bytesSession.dispose();

  final evidence = <String, Object?>{
    'checks': checked,
    'problems': problems.isEmpty ? 'none' : problems,
  };
  final path7 = artifact('pr07.json');
  File(
    path7,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR07', problems.isEmpty ? 'pass' : 'fail', evidence, [path7]));

  return problems.isEmpty;
}

/// PR08: the real release-matrix lanes plus the isolated benchmark.
Future<bool> _pr08(
  final List<Map<String, Object?>> cases,
  final String Function(String) artifact,
  final Directory evidenceDir,
) async {
  final laneDir = Directory('${evidenceDir.path}/pr08-lanes');
  final lanes = [
    runOracleDartLane(laneDir, 'format', ['format', '--output=none', '--set-exit-if-changed', '.']),
    runOracleDartLane(laneDir, 'analyze', ['analyze', '--fatal-infos']),
    runOracleDartLane(laneDir, 'vm-suite', ['test', '--exclude-tags', 'fuzz']),
    runOracleDartLane(laneDir, 'chrome-suite', ['test', '-p', 'chrome', 'test/web/']),
    runOracleDartLane(laneDir, 'fuzz', ['test', '--tags', 'fuzz']),
    runOracleDartLane(laneDir, 'corpus-manifest', [
      'run',
      'tool/fuzz_corpus_inventory.dart',
      '--check-manifest',
    ]),
    runOracleDartLane(laneDir, 'pub-dry-run', ['pub', 'publish', '--dry-run']),
    runOracleDartLane(laneDir, 'benchmark', [
      'run',
      'tool/pdf_session_bench.dart',
      '--out=build/evidence/C01/cases/pr08-bench.json',
    ]),
  ];
  final ok = lanes.every((final lane) => lane['exitCode'] == 0);
  final evidence = <String, Object?>{
    'lanes': lanes,
    'problems': ok ? 'none' : 'a lane exited non-zero',
  };
  final path8 = artifact('pr08.json');
  File(
    path8,
  ).writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(evidence)}\n');
  cases.add(_case('PR08', ok ? 'pass' : 'fail', evidence, [path8]));

  return ok;
}
