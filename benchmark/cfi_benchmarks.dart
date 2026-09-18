// Benchmarks for the EPUB CFI feature: `EpubCfi.parse`, the
// `EpubCfiResolver` extension (`resolveCfi` / `buildEpubCfi`) and the
// build → parse → resolve round trip, all against the Alice EPUB
// fixture.
//
// Every derived input — the parsed book, the section document models,
// target offsets and the pre-parsed CFIs of the resolve targets — is
// computed untimed before registration, so the timed bodies measure
// only the CFI work itself.
//
// `resolveCfi` / `buildEpubCfi` come in pairs: the plain entry parses
// the section XML on every call, the `· cached` entry is pre-touched
// untimed and hits the per-book section document cache.

// Benchmark registration reads best as sequential statements.
// ignore_for_file: cascade_invocations

import 'package:e_livre/e_livre.dart';

import 'benchmark_harness.dart';
import 'fixtures.dart';

/// The canonical CFI example from the EPUB CFI spec.
const String _w3cExample = 'epubcfi(/6/4[chap01ref]!/4[body01]/10[para05]/3:10)';

/// Runs the CFI parse / resolve / build / round-trip benchmarks.
void runCfiBenchmarks() {
  final book = BookReader.parseBook(epubAlice.bytes) as EpubBook;
  final documents = _SectionDocuments(book);
  final group = BenchmarkGroup('CFI');

  _addParseBenchmarks(group, book, documents);
  _addResolveBenchmarks(group, book, documents);
  _addBuildBenchmarks(group, book, documents);
  _addRoundtripBenchmark(group, book, documents);
}

/// One derived position in the fixture book: the content index, the
/// offset inside the section's document text and the pre-parsed
/// book-level CFI pointing there.
final class _CfiTarget {
  const _CfiTarget({
    required this.label,
    required this.contentIndex,
    required this.offset,
    required this.cfi,
  });

  /// Where in the book this target sits, for the benchmark name.
  final String label;

  /// Index of the content section in the reading order.
  final int contentIndex;

  /// Offset inside the section's document text.
  final int offset;

  /// The book-level CFI of (contentIndex, offset), parsed untimed.
  final EpubCfi cfi;
}

/// Lazily parsed document models of the fixture's sections, keyed by
/// content index. Derivation-only state; never touched by timed code.
final class _SectionDocuments {
  _SectionDocuments(this._book);

  final EpubBook _book;
  final Map<int, EpubCfiDocument?> _cache = <int, EpubCfiDocument?>{};

  /// The document model of the section at [contentIndex], or `null`
  /// when the section has no HTML file.
  EpubCfiDocument? at(final int contentIndex) {
    return _cache.putIfAbsent(contentIndex, () {
      final sections = _book.readingOrder;
      if (contentIndex < 0 || contentIndex >= sections.length) return null;

      for (final file in _book.files.html) {
        if (file.path == sections[contentIndex].name) return EpubCfiDocument.parse(file.content);
      }

      return null;
    });
  }

  /// The index and document of the section with the most text.
  (int, EpubCfiDocument?) largestTextSection() {
    var index = -1;
    EpubCfiDocument? document;
    for (var i = 0; i < sectionCount; i++) {
      final candidate = at(i);
      if (candidate == null) continue;

      if (document == null || candidate.text.length > document.text.length) {
        index = i;
        document = candidate;
      }
    }

    return (index, document);
  }

  /// How many content sections the reading order has.
  int get sectionCount => _book.readingOrder.length;
}

/// Book-level CFI for [offset] inside [document], mirroring
/// `buildEpubCfi` (spine segment `/6/N` plus the document's local
/// path) so derivation can sample many offsets without re-parsing the
/// section XML for every sample.
EpubCfi _bookCfi(final EpubCfiDocument document, final int contentIndex, final int offset) {
  final spine = EpubCfi.simple(steps: [6, (contentIndex + 1) * 2]);
  final local = document.cfiForOffset(offset);

  return EpubCfi(start: EpubCfiPath(segments: [...spine.start.segments, ...local.start.segments]));
}

/// The first section index at or after [from] whose document text is
/// non-empty, or `null` when none qualifies.
int? _workableIndex(final _SectionDocuments documents, final int from, final int count) {
  for (var i = from.clamp(0, count - 1); i < count; i++) {
    final document = documents.at(i);
    if (document != null && document.text.isNotEmpty) return i;
  }

  return null;
}

/// Derives the target at [orderFraction] of the reading order and
/// [textFraction] of that section's document text, or `null` when the
/// section carries no HTML text.
_CfiTarget? _targetAt(
  final EpubBook book,
  final _SectionDocuments documents, {
  required final double orderFraction,
  required final double textFraction,
  final String label = '',
}) {
  final sections = book.readingOrder;
  final requested = (orderFraction * (sections.length - 1)).round();
  final index = _workableIndex(documents, requested, sections.length);
  if (index == null) return null;

  final document = documents.at(index)!;
  final textLength = document.text.length;
  final offset = (textFraction * textLength).round().clamp(0, textLength);
  final cfi = EpubCfi.parse(book.buildEpubCfi(contentIndex: index, offsetInText: offset));
  final place = 'section ${index + 1}/${sections.length}';

  return _CfiTarget(
    label: label.isEmpty ? place : '$label ($place)',
    contentIndex: index,
    offset: offset,
    cfi: cfi,
  );
}

void _addParseBenchmarks(
  final BenchmarkGroup group,
  final EpubBook book,
  final _SectionDocuments documents,
) {
  group.add(
    'EpubCfi.parse — W3C spec example',
    () => EpubCfi.parse(_w3cExample),
    note: '5 steps · 3 assertions',
  );

  // The deepest book-level CFI buildable from the fixture, sampled
  // across every section. The book CFI and the range CFI below are
  // both derived untimed from real positions.
  final deepest = _deepestBookCfi(documents);
  if (deepest != null) {
    final steps = _stepCount(EpubCfi.parse(deepest));
    group.add(
      'EpubCfi.parse — alice book CFI ($steps steps, ${deepest.length} chars)',
      () => EpubCfi.parse(deepest),
      note: 'longest real CFI in the fixture',
    );
  }

  final range = _rangeCfi(documents);
  if (range != null) {
    final steps = _stepCount(EpubCfi.parse(range));
    group.add(
      'EpubCfi.parse — alice range CFI ($steps steps, ${range.length} chars)',
      () => EpubCfi.parse(range),
      note: 'leading path + 2 range sub-paths',
    );
  }

  final (index, document) = documents.largestTextSection();
  if (document != null) {
    final content = _htmlOf(book, index);
    if (content != null) {
      group.add(
        'EpubCfiDocument.parse — largest chapter',
        () => EpubCfiDocument.parse(content),
        inputBytes: content.length,
        note: 'XML parse + text-node index, run per resolve/build call',
      );
    }
  }
}

/// Registers the resolve benchmarks at five positions spread over the
/// reading order (start / quarter / middle / three quarters / end).
/// The CFIs are built and parsed untimed; only `resolveCfi` is timed.
void _addResolveBenchmarks(
  final BenchmarkGroup group,
  final EpubBook book,
  final _SectionDocuments documents,
) {
  const positions = <(String, double)>[
    ('start of book', 0.0),
    ('quarter', 0.25),
    ('middle', 0.5),
    ('three quarters', 0.75),
    ('end of book', 1.0),
  ];
  for (final (label, orderFraction) in positions) {
    final target = _targetAt(
      book,
      documents,
      orderFraction: orderFraction,
      textFraction: 0.5,
      label: label,
    );
    if (target == null) continue;

    group.add('resolveCfi — ${target.label}', () => book.resolveCfi(target.cfi));
    // Pre-touch so the cached entry below hits the warm document
    // cache instead of re-parsing the section XML.
    book.resolveCfi(target.cfi);
    group.add(
      'resolveCfi — ${target.label} · cached',
      () => book.resolveCfi(target.cfi),
      note: 'section document cached',
    );
  }
}

/// Registers the build benchmark over a spread of (contentIndex,
/// offset) pairs across the book.
void _addBuildBenchmarks(
  final BenchmarkGroup group,
  final EpubBook book,
  final _SectionDocuments documents,
) {
  const spreads = <(double, double)>[
    (0.0, 0.0),
    (0.25, 0.33),
    (0.5, 0.5),
    (0.75, 0.66),
    (1.0, 1.0),
  ];
  for (final (orderFraction, textFraction) in spreads) {
    final target = _targetAt(
      book,
      documents,
      orderFraction: orderFraction,
      textFraction: textFraction,
    );
    if (target == null) continue;

    final percent = (textFraction * 100).round();
    group.add(
      'buildEpubCfi — ${target.label} · $percent% into text',
      () => book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset),
    );
    // Pre-touch so the cached entry below hits the warm document
    // cache instead of re-parsing the section XML.
    book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset);
    group.add(
      'buildEpubCfi — ${target.label} · $percent% into text · cached',
      () => book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset),
      note: 'section document cached',
    );
  }
}

/// Registers the round trip: one run builds, parses and resolves
/// ~10 positions spread over the reading order.
void _addRoundtripBenchmark(
  final BenchmarkGroup group,
  final EpubBook book,
  final _SectionDocuments documents,
) {
  final targets = <_CfiTarget>[];
  for (var k = 0; k < 10; k++) {
    final target = _targetAt(book, documents, orderFraction: k / 9, textFraction: 0.5);
    if (target != null) targets.add(target);
  }

  if (targets.isEmpty) return;

  group.add('roundtrip build → parse → resolve', () {
    Object? last;
    for (final target in targets) {
      final cfi = EpubCfi.parse(
        book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset),
      );
      last = book.resolveCfi(cfi);
    }

    return last;
  }, note: '${targets.length} positions per run');
  // Pre-touch every section so the cached round trip below never
  // parses section XML.
  for (final target in targets) {
    book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset);
  }
  group.add(
    'roundtrip build → parse → resolve · cached',
    () {
      Object? last;
      for (final target in targets) {
        final cfi = EpubCfi.parse(
          book.buildEpubCfi(contentIndex: target.contentIndex, offsetInText: target.offset),
        );
        last = book.resolveCfi(cfi);
      }

      return last;
    },
    note: '${targets.length} positions, section documents cached',
  );
}

/// The longest book-level CFI buildable from the fixture, found by
/// sampling 33 offsets in every section. Returns the encoded string.
String? _deepestBookCfi(final _SectionDocuments documents) {
  String? longest;
  for (var i = 0; i < documents.sectionCount; i++) {
    final document = documents.at(i);
    if (document == null || document.text.isEmpty) continue;

    final textLength = document.text.length;
    for (var k = 0; k <= 32; k++) {
      final offset = (textLength * k / 32).round().clamp(0, textLength);
      final encoded = _bookCfi(document, i, offset).encode();
      if (longest == null || encoded.length > longest.length) {
        longest = encoded;
      }
    }
  }

  return longest;
}

/// A range CFI built from the three structurally richest local paths
/// of the largest chapter (longest encoded form among 65 sampled
/// offsets, ordered by offset): `epubcfi(/6/N!<a>,<b>,<c>)`. The
/// fixture's DOM is too flat to produce deeply nested paths, so this
/// is the longest parse input the book can supply.
String? _rangeCfi(final _SectionDocuments documents) {
  final (index, document) = documents.largestTextSection();
  if (index < 0 || document == null) return null;

  final textLength = document.text.length;
  final sampled = <(int, EpubCfi)>[];
  for (var k = 0; k <= 64; k++) {
    final offset = (textLength * k / 64).round().clamp(0, textLength);
    sampled.add((offset, document.cfiForOffset(offset)));
  }

  final ranked = sampled.toList()
    ..sort((final a, final b) => b.$2.encode().length.compareTo(a.$2.encode().length));
  final chosen = ranked.take(3).toList()..sort((final a, final b) => a.$1.compareTo(b.$1));
  final spine = EpubCfi.simple(steps: [6, (index + 1) * 2]);

  return EpubCfi(
    start: EpubCfiPath(segments: [...spine.start.segments, ...chosen[0].$2.start.segments]),
    rangeStart: chosen[1].$2.start,
    rangeEnd: chosen[2].$2.start,
  ).encode();
}

/// The number of `/N` steps across every path of [cfi], including the
/// range boundaries.
int _stepCount(final EpubCfi cfi) {
  var total = 0;
  for (final path in <EpubCfiPath?>[cfi.start, cfi.rangeStart, cfi.rangeEnd]) {
    if (path == null) continue;

    for (final segment in path.segments) {
      total += segment.steps.length;
    }
  }

  return total;
}

/// The raw XHTML of the section at [contentIndex], or `null`.
String? _htmlOf(final EpubBook book, final int contentIndex) {
  final sections = book.readingOrder;
  if (contentIndex < 0 || contentIndex >= sections.length) return null;

  for (final file in book.files.html) {
    if (file.path == sections[contentIndex].name) return file.content;
  }

  return null;
}
