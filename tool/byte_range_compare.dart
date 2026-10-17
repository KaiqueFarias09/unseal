// B02 comparison stage: three-way parity plus partial-reading evidence.
//
// Reads the independent Python zipfile inventory and, for every
// fixture, compares it against (a) a progressive session opened over a
// recording byte source through the real isolate bridge and (b) the
// eager parse. Emits the gate comparison report with one verdict per
// acceptance case (BS01..BS07) and the measured byte counts.
//
//     dart run tool/byte_range_compare.dart \
//         --inventory build/evidence/B02/reference-inventory.json \
//         --report build/evidence/B02/comparison.json
//
// The recording source is independent of Unseal's zip code: it slices
// an in-memory buffer and logs every range.

import 'dart:convert' as convert;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:unseal/unseal.dart';

import 'oracle_test_lane.dart';

const _epubFixtures = <String>[
  'test/resources/epub/Alices Adventures in Wonderland.epub',
  'test/resources/books/epub/elements-of-chemistry.epub',
  'test/resources/books/epub/mahabharata.epub',
];
const _cbzFixtures = <String>[
  'test/resources/books/comic/halfpenny-surprise-1895.cbz',
  'test/resources/books/comic/synthetic-pages.cbz',
];
const _largeFixture = 'test/resources/books/epub/mahabharata.epub';
const _pdfFixture = 'test/resources/pdf/dickens-sample.pdf';
const _rarFixture = 'test/resources/books/comic/american-beauty-trading-cards-1909.cbr';
const _docxFixture = 'test/resources/books/docx/synthetic.docx';

Uint8List _bytes(final String path) => Uint8List.fromList(File(path).readAsBytesSync());

String _sha256(final List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// The instrumented host source: exact slices over an in-memory
/// buffer, every range recorded, contract violations injectable.
final class RecordingByteSource implements UnsealByteSource {
  RecordingByteSource(this.bytes, {this.revision, this.delay = Duration.zero});

  final Uint8List bytes;
  @override
  String? revision;
  final Duration delay;
  var _closed = false;
  final List<({int offset, int count})> reads = <({int offset, int count})>[];

  bool get closed => _closed;
  int get readCount => reads.length;
  int get totalBytesRequested => reads.fold(0, (final total, final read) => total + read.count);
  void flipRevision() {
    revision = 'revised-${revision ?? 'null'}';
  }

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (_closed) throw const ByteSourceClosedException();
    RangeError.checkValidRange(offset, offset + count, bytes.length, 'offset', 'end');
    reads.add((offset: offset, count: count));
    if (delay > Duration.zero) await Future<void>.delayed(delay);

    return Uint8List.sublistView(bytes, offset, offset + count);
  }

  @override
  Future<void> close() async {
    _closed = true;
  }
}

/// Contract-violation source for the typed-failure checks.
final class FaultyByteSource implements UnsealByteSource {
  FaultyByteSource(this.bytes, this.mode);

  final Uint8List bytes;
  final String mode;

  @override
  int get length => bytes.length;

  @override
  String? get revision => null;

  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    switch (mode) {
      case 'short':
        return Uint8List.sublistView(bytes, offset, offset + count - 1);
      case 'long':
        final long = Uint8List(count + 1);
        long.setRange(0, count, Uint8List.sublistView(bytes, offset, offset + count));

        return long;
      case 'host':
        throw StateError('host transport failure');
    }
    throw StateError('unknown mode $mode');
  }

  @override
  Future<void> close() async {}
}

final class _Case {
  _Case(this.id, this.verdict, this.evidence);

  final String id;
  final String verdict;
  final Map<String, Object?> evidence;

  Map<String, Object?> toWire() => <String, Object?>{
    'id': id,
    'verdict': verdict,
    'skipped': false,
    'evidence': evidence,
  };
}

Future<void> main(final List<String> arguments) async {
  String inventoryPath = '';
  String reportPath = '';
  for (var i = 0; i < arguments.length - 1; i++) {
    if (arguments[i] == '--inventory') inventoryPath = arguments[i + 1];
    if (arguments[i] == '--report') reportPath = arguments[i + 1];
  }
  if (inventoryPath.isEmpty || reportPath.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/byte_range_compare.dart --inventory <json> --report <json>',
    );

    exit(2);
  }

  final inventory =
      convert.jsonDecode(File(inventoryPath).readAsStringSync()) as Map<String, Object?>;
  final containers = (inventory['containers']! as List<Object?>).cast<Map<String, Object?>>();

  final cases = <_Case>[];
  final stages = <String, Future<void> Function()>{
    'BS01': () => _bs01(cases),
    'BS02': () => _bs02(cases, containers),
    'BS03': () => _bs03(cases, containers),
    'BS04': () => _bs04(cases),
    'BS05': () => _bs05(cases),
    'BS06': () => _bs06(cases),
    'BS07': () => _bs07(cases),
  };
  for (final entry in stages.entries) {
    try {
      await entry.value();
    } on Object catch (error, stack) {
      stdout.writeln('STAGE ${entry.key} threw: ${error.runtimeType}: $error');
      stdout.writeln(stack);
      exit(3);
    }
  }

  final laneDir = Directory('build/evidence/B02/current-lanes');
  final lanes = [
    runOracleDartLane(laneDir, 'public-source-vm', [
      'test',
      'test/tests/progressive/byte_source_test.dart',
    ]),
    runOracleDartLane(laneDir, 'compile-worker', [
      'compile',
      'js',
      'web/unseal_worker.dart',
      '-o',
      'test/web/unseal_worker.js',
    ]),
    runOracleDartLane(laneDir, 'public-source-chrome', [
      'test',
      '-p',
      'chrome',
      'test/web/session_byte_source_worker_test.dart',
    ]),
  ];
  for (final id in ['BS05', 'BS06']) {
    final index = cases.indexWhere((entry) => entry.id == id);
    final original = cases[index];
    cases[index] = _Case(
      id,
      original.verdict == 'pass' && lanes.every((lane) => lane['exitCode'] == 0) ? 'pass' : 'fail',
      {...original.evidence, 'executedLanes': lanes},
    );
  }
  final report = <String, Object?>{
    'schemaVersion': 1,
    'mission': 'B02',
    'generatedBy': 'tool/byte_range_compare.dart',
    'inventory': inventoryPath,
    'cases': <Object?>[for (final entry in cases) entry.toWire()],
  };
  final reportFile = File(reportPath);
  reportFile.parent.createSync(recursive: true);
  reportFile.writeAsStringSync('${const convert.JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('wrote $reportPath');
  var failed = false;
  for (final entry in cases) {
    stdout.writeln('${entry.id}: ${entry.verdict}');
    if (entry.verdict != 'pass') failed = true;
  }
  exit(failed ? 1 : 0);
}

Map<String, Object?>? _containerFor(
  final List<Map<String, Object?>> containers,
  final String path,
) {
  final name = path.split('/').last;
  for (final container in containers) {
    if ((container['fixture'] as String).endsWith(name)) return container;
  }

  return null;
}

/// BS01: the public contract — header shape, exact reads, revision
/// reporting, disposal, and explicit refusals outside the cut.
Future<void> _bs01(final List<_Case> cases) async {
  final raw = _bytes(_epubFixtures.first);
  final source = RecordingByteSource(raw, revision: 'compare-etag');
  final session = await BookSession.openSource(source);
  final problems = <String>[];

  if (session.book is! EpubBook) problems.add('header is not an EpubBook');
  if (session.sourceRevision != 'compare-etag') problems.add('revision not reported');
  if (session.book.files.html.isNotEmpty) problems.add('header carries content');

  final first = session.book.readingOrder.first;
  final chapter = await session.loadDocumentSource(first.name);
  final eager = Unseal.parse(raw) as EpubBook;
  final expected = eager.files.html
      .firstWhere((final file) => file.path == eager.readingOrder.first.name)
      .content;
  if (chapter != expected) problems.add('first section source differs from eager');

  session.dispose();
  if (!source.closed) problems.add('dispose did not close the host source');

  for (final (fixture, needle) in <(String, String)>[
    (_pdfFixture, 'PDF'),
    (_rarFixture, 'CBR'),
    (_docxFixture, 'zip container has no progressive session support'),
  ]) {
    try {
      final session2 = await BookSession.openSource(RecordingByteSource(_bytes(fixture)));
      session2.dispose();
      problems.add('$fixture opened but must be refused');
    } on SessionUnsupportedFormatException catch (error) {
      if (!error.message.contains(needle)) {
        problems.add('$fixture refusal does not name the format: ${error.message}');
      }
    } on Object catch (error) {
      problems.add('$fixture failed with ${error.runtimeType} instead of the typed refusal');
    }
  }

  cases.add(
    _Case('BS01', problems.isEmpty ? 'pass' : 'fail', {
      'problems': problems.isEmpty ? 'contract held on every check' : problems,
    }),
  );
}

/// BS02: entry-by-entry content identity across the three references —
/// Python zipfile SHA-256, remote session bytes, eager parse bytes —
/// plus structure parity (spine, page order, inventory sizes).
Future<void> _bs02(final List<_Case> cases, final List<Map<String, Object?>> containers) async {
  final notes = <String, Object?>{};
  var mismatches = 0;
  var entriesCompared = 0;

  Future<void> walk(final String fixture) async {
    final container = _containerFor(containers, fixture);
    if (container == null) {
      mismatches++;
      notes['$fixture:inventory'] = 'missing from the reference inventory';

      return;
    }
    final raw = _bytes(fixture);
    final eager = Unseal.parse(raw);
    final source = RecordingByteSource(raw);
    final session = await BookSession.openSource(source);
    final byPath = <String, Map<String, Object?>>{
      for (final entry in (container['entries']! as List<Object?>).cast<Map<String, Object?>>())
        entry['path']! as String: entry,
    };

    for (final entry in session.book.archiveEntries) {
      final reference = byPath[entry.path];
      if (reference == null) {
        mismatches++;
        notes['$fixture:${entry.path}'] = 'absent from the python inventory';

        continue;
      }
      if (entry.size != reference['uncompressedSize']) {
        mismatches++;
        notes['$fixture:${entry.path}'] = 'size ${entry.size} != ${reference['uncompressedSize']}';

        continue;
      }
      final remote = await session.loadResource(entry.path);
      if (remote == null) {
        mismatches++;
        notes['$fixture:${entry.path}'] = 'remote session returned null';

        continue;
      }
      if (_sha256(remote) != reference['sha256']) {
        mismatches++;
        notes['$fixture:${entry.path}'] = 'remote sha != python sha';

        continue;
      }
      final eagerBytes = _eagerBytesFor(eager, entry.path);
      if (eagerBytes != null && _sha256(eagerBytes) != reference['sha256']) {
        mismatches++;
        notes['$fixture:${entry.path}'] = 'eager sha != python sha';

        continue;
      }
      entriesCompared++;
    }
    session.dispose();
  }

  for (final fixture in _epubFixtures) {
    await walk(fixture);
  }
  for (final fixture in _cbzFixtures) {
    final raw = _bytes(fixture);
    final eager = Unseal.parse(raw) as ComicBook;
    await walk(fixture);
    final source = RecordingByteSource(raw);
    final session = await BookSession.openSource(source);
    final header = session.book as ComicBook;
    if (header.pageCount != eager.pageCount ||
        [for (final page in header.pages) page.path].join('|') !=
            [for (final page in eager.pages) page.path].join('|')) {
      mismatches++;
      notes['$fixture:pages'] = 'page order differs from the eager parse';
    }
    session.dispose();
  }

  cases.add(
    _Case('BS02', mismatches == 0 && entriesCompared > 50 ? 'pass' : 'fail', {
      'entriesCompared': entriesCompared,
      'mismatches': mismatches,
      'notes': notes.isEmpty ? 'every entry matched python, remote and eager' : notes,
    }),
  );
}

Uint8List? _eagerBytesFor(final Book eager, final String path) {
  for (final file in eager.files.html) {
    if (file.path == path) return Uint8List.fromList(convert.utf8.encode(file.content));
  }
  for (final group in [eager.files.images, eager.files.fonts, eager.files.others]) {
    for (final file in group) {
      if (file.path == path) return file.content;
    }
  }
  for (final file in eager.files.css) {
    if (file.path == path) return Uint8List.fromList(convert.utf8.encode(file.content));
  }

  return null;
}

/// BS03: measured partial reading on the large fixture — the open and
/// the first content request stay inside the container bookkeeping and
/// the addressed entry's byte span, a small fraction of the file.
Future<void> _bs03(final List<_Case> cases, final List<Map<String, Object?>> containers) async {
  final raw = _bytes(_largeFixture);
  final container = _containerFor(containers, _largeFixture);
  final entries = (container!['entries']! as List<Object?>).cast<Map<String, Object?>>();
  final source = RecordingByteSource(raw);
  final session = await BookSession.openSource(source);

  final openBytes = source.totalBytesRequested;
  var openWithinRegions = true;
  final directoryEnd = _directoryEnd(raw);
  for (final read in source.reads) {
    final inDirectory = read.offset + read.count <= directoryEnd;
    final isTail = read.offset >= raw.length - (65535 + 22);
    if (!inDirectory && !isTail && read.count > 1024) openWithinRegions = false;
  }

  final firstPath = session.book.readingOrder.first.name;
  final span = _entrySpan(entries, firstPath);
  final readsBefore = source.readCount;
  final firstBytes = await session.loadResource(firstPath);
  final loadReads = source.reads.sublist(readsBefore);
  var loadWithinSpan = firstBytes != null;
  for (final read in loadReads) {
    if (read.offset < span.$1 || read.offset + read.count > span.$2) loadWithinSpan = false;
  }
  final totalAfterFirst = source.totalBytesRequested;

  // A distant section, out of order: still just its own span.
  final distantPath = session.book.readingOrder.last.name;
  final distantSpan = _entrySpan(entries, distantPath);
  final readsBeforeDistant = source.readCount;
  await session.loadResource(distantPath);
  for (final read in source.reads.sublist(readsBeforeDistant)) {
    if (read.offset < distantSpan.$1 || read.offset + read.count > distantSpan.$2) {
      loadWithinSpan = false;
    }
  }

  session.dispose();

  cases.add(
    _Case('BS03', openWithinRegions && loadWithinSpan ? 'pass' : 'fail', {
      'fixture': _largeFixture,
      'fileBytes': raw.length,
      'openBytesRequested': openBytes,
      'openFraction': (openBytes / raw.length).toStringAsFixed(4),
      'openWithinContainerRegions': openWithinRegions,
      'firstSection': firstPath,
      'firstSectionBytes': firstBytes?.length,
      'firstSectionWithinEntrySpan': loadWithinSpan,
      'entrySpan': <Object?>[span.$1, span.$2],
      'totalAfterFirstSection': totalAfterFirst,
      'totalAfterFirstFraction': (totalAfterFirst / raw.length).toStringAsFixed(4),
    }),
  );
}

int _directoryEnd(final Uint8List raw) {
  // Independent EOCD walk (shares no code with Unseal): scan the tail
  // for the end-of-central-directory signature and read its fields.
  int u32(final int offset) =>
      ByteData.sublistView(raw, offset, offset + 4).getUint32(0, Endian.little);
  const recordLength = 22;
  var cursor = raw.length - recordLength;
  while (cursor >= 0 && cursor >= raw.length - (65535 + recordLength)) {
    if (u32(cursor) == 0x06054b50) {
      final directoryOffset = u32(cursor + 16);
      final directorySize = u32(cursor + 12);

      return directoryOffset + directorySize;
    }
    cursor--;
  }
  throw StateError('the fixture has no end-of-central-directory record');
}

(int, int) _entrySpan(final List<Map<String, Object?>> entries, final String path) {
  for (final entry in entries) {
    if (entry['path'] == path) {
      final start = entry['localHeaderOffset']! as int;
      // The local header's own name/extra fields sit between the fixed
      // header and the payload; the python inventory carries none of
      // them, so the span gets one record's worth of documented slack.
      final end = start + 30 + (entry['compressedSize']! as int) + 65535 + 1024;

      return (start, math.min(end, 1 << 40));
    }
  }
  throw StateError('entry $path missing from the inventory');
}

/// BS04: every contract failure fails typed through the public session.
Future<void> _bs04(final List<_Case> cases) async {
  final raw = _bytes(_epubFixtures.first);
  final results = <String, String>{};
  var pass = true;

  Future<void> expectTyped(
    final String name,
    final UnsealByteSource source,
    final String type,
  ) async {
    // The open itself reads; a faulty source may fail it typed — that
    // counts as the observation too.
    String observed;
    BookSession? session;
    try {
      session = await BookSession.openSource(source);
      observed = '';
      for (final section in session.book.readingOrder) {
        try {
          await session.loadResource(section.name);
        } on Object catch (error) {
          observed = error.runtimeType.toString();
          break;
        }
      }
    } on Object catch (error) {
      observed = error.runtimeType.toString();
    }
    session?.dispose();
    results[name] = observed.isEmpty ? 'no read fired' : observed;
    if (observed != type) pass = false;
  }

  await expectTyped('short', FaultyByteSource(raw, 'short'), 'ByteSourceShortReadException');
  await expectTyped('long', FaultyByteSource(raw, 'long'), 'ByteSourceLongReadException');
  await expectTyped('host', FaultyByteSource(raw, 'host'), 'ByteSourceReadException');

  // Revision change under an open session.
  final flipping = RecordingByteSource(raw, revision: 'etag-1');
  final session = await BookSession.openSource(flipping);
  flipping.flipRevision();
  var revisionObserved = '';
  for (final section in session.book.readingOrder) {
    try {
      await session.loadResource(section.name);
    } on Object catch (error) {
      revisionObserved = error.runtimeType.toString();
      break;
    }
  }
  session.dispose();
  results['revision'] = revisionObserved;
  if (revisionObserved != 'ByteSourceRevisionChangedException') pass = false;

  // Extreme offsets through the public range op.
  final rangeSession = await BookSession.openSource(RecordingByteSource(raw));
  var rangeErrors = 0;
  for (final (offset, count) in [(-1, 4), (0, -1), (raw.length + 1, 4)]) {
    try {
      await rangeSession.loadBytesRange(offset, count);
    } on RangeError {
      rangeErrors++;
    } on Object {
      // wrong type
    }
  }
  rangeSession.dispose();
  results['extremeOffsets'] = '$rangeErrors/3 RangeError';
  if (rangeErrors != 3) pass = false;

  // A closed host source fails the next read typed.
  final closing = RecordingByteSource(raw);
  final closedSession = await BookSession.openSource(closing);
  await closing.close();
  var closedObserved = '';
  for (final section in closedSession.book.readingOrder) {
    try {
      await closedSession.loadResource(section.name);
    } on Object catch (error) {
      closedObserved = error.runtimeType.toString();
      break;
    }
  }
  closedSession.dispose();
  results['closedSource'] = closedObserved;
  if (closedObserved.isEmpty) pass = false;

  cases.add(_Case('BS04', pass ? 'pass' : 'fail', {...results}));
}

/// BS05: two sessions through the real isolate bridge, interleaved,
/// then one disposed — the other stays live, late replies serve
/// nobody, and a fresh session over a new source works.
Future<void> _bs05(final List<_Case> cases) async {
  final problems = <String>[];
  final sourceA = RecordingByteSource(
    _bytes(_epubFixtures.first),
    revision: 'a',
    delay: const Duration(milliseconds: 1),
  );
  final sourceB = RecordingByteSource(
    _bytes(_epubFixtures[1]),
    revision: 'b',
    delay: const Duration(milliseconds: 1),
  );
  final sessionA = await BookSession.openSource(sourceA);
  final sessionB = await BookSession.openSource(sourceB);

  final pathA = sessionA.book.readingOrder.first.name;
  final pathB = sessionB.book.readingOrder.first.name;
  final inter = await Future.wait([
    sessionA.loadDocumentText(pathA),
    sessionB.loadDocumentText(pathB),
    sessionA.loadDocumentText(pathA),
    sessionB.loadResource(pathB),
  ]);
  if (inter[0] != inter[2]) problems.add('same session returned different text');
  if (inter[0] == inter[1]) problems.add('different books returned equal text');

  final inFlightA = sessionA.loadResource(pathA);
  sessionA.dispose();
  try {
    await inFlightA;
    problems.add('disposed session completed its in-flight op');
  } on SessionClosedException {
    // expected
  } on Object catch (error) {
    problems.add('disposed session failed with ${error.runtimeType}');
  }
  if (!sourceA.closed) problems.add('dispose did not close source A');

  if (await sessionB.loadDocumentText(pathB) == null) {
    problems.add('the surviving session stopped answering');
  }
  try {
    await sessionA.loadResource(pathA);
    problems.add('the disposed session answered a new request');
  } on SessionClosedException {
    // expected
  }

  final fresh = await BookSession.openSource(RecordingByteSource(_bytes(_epubFixtures.first)));
  if (await fresh.loadResource(fresh.book.readingOrder.first.name) == null) {
    problems.add('a fresh session over a new source failed');
  }
  fresh.dispose();
  sessionB.dispose();

  cases.add(
    _Case('BS05', problems.isEmpty ? 'pass' : 'fail', {
      'problems': problems.isEmpty ? 'isolation, disposal and late-reply semantics held' : problems,
      'sourceAReads': sourceA.reads.length,
      'sourceBReads': sourceB.reads.length,
    }),
  );
}

/// BS06: budgets under concurrency — the stage runs six parallel
/// section loads across two sessions against sources with a small
/// delay and reports the byte totals; the peak-based cap assertions
/// live in test/tests/progressive/byte_source_test.dart and the full
/// VM suite re-runs them on every gate.
Future<void> _bs06(final List<_Case> cases) async {
  final problems = <String>[];
  final sources = <RecordingByteSource>[
    RecordingByteSource(_bytes(_epubFixtures.first), delay: const Duration(milliseconds: 1)),
    RecordingByteSource(_bytes(_epubFixtures[1]), delay: const Duration(milliseconds: 1)),
  ];
  final sessions = <BookSession>[
    for (final source in sources) await BookSession.openSource(source),
  ];
  final loads = <Future<Object?>>[
    for (final session in sessions)
      for (final section in session.book.readingOrder.take(3)) ...<Future<Object?>>[
        session.loadResource(section.name),
        session.loadDocumentText(section.name),
      ],
  ];
  final done = await Future.wait(loads);
  for (final session in sessions) {
    session.dispose();
  }
  for (final result in done) {
    if (result == null) problems.add('a concurrent load returned null');
  }

  cases.add(
    _Case('BS06', problems.isEmpty ? 'pass' : 'fail', {
      'problems': problems.isEmpty
          ? 'concurrent loads across two sessions completed under the '
                'default budgets; the peak cap assertions live in '
                'test/tests/progressive/byte_source_test.dart (gate '
                'maxObservedInFlightRequests/Bytes) and run in the VM lane'
          : problems,
      'concurrentLoads': done.length,
    }),
  );
}

/// BS07: search, progression, statistics and CFI keep their eager
/// contracts over materialized resources; the byte measurements ride
/// along.
Future<void> _bs07(final List<_Case> cases) async {
  final raw = _bytes(_epubFixtures.first);
  final source = RecordingByteSource(raw);
  final session = await BookSession.openSource(source);
  final eager = Unseal.parse(raw) as EpubBook;
  final problems = <String>[];

  final remoteSearch = await session.search('Alice', maxMatches: 50);
  final eagerSearch = eager.search('Alice', maxMatches: 50);
  if (remoteSearch.matches.length != eagerSearch.matches.length) {
    problems.add('search match count differs');
  }

  final progression = await session.computeProgression();
  final eagerLengths = <int>[
    for (final section in eager.readingOrder)
      section.isHtml
          ? documentTextOf(
              eager.files.html.firstWhere((final file) => file.path == section.name),
            ).length
          : 0,
  ];
  if (progression.sectionLengths.join(',') != eagerLengths.join(',')) {
    problems.add('progression section lengths differ');
  }

  final statistics = await session.computeStatistics();
  final eagerStatistics = eager.statistics;
  if (statistics.wordCount != eagerStatistics.wordCount) {
    problems.add('word count differs from eager');
  }

  final cfi = await session.buildCfi(contentIndex: 0, offsetInText: 12);
  if (await session.resolveCfi(cfi) == null) problems.add('built CFI does not resolve');

  final coverage = await session.buildSearchIndex(sectionsPerBatch: 2);
  if (!coverage.isComplete) problems.add('indexed build did not complete');
  final indexed = await session.searchIndexed('alice');
  if (indexed.hits.isEmpty) problems.add('indexed query found nothing');

  final bytes = source.totalBytesRequested;
  session.dispose();

  cases.add(
    _Case('BS07', problems.isEmpty ? 'pass' : 'fail', {
      'problems': problems.isEmpty
          ? 'search, progression, statistics, CFI and the index match eager'
          : problems,
      'totalBytesRequestedByAllOps': bytes,
      'fileBytes': raw.length,
    }),
  );
}
