/// Compares Unseal's durable-anchor resolution against Hypothesis
/// client's DOM-free `matchQuote` at the pinned revision — the
/// acceptance oracle for the anchoring port (ANN01–ANN05's re-finding
/// behavior).
///
/// Cases come from the licensed Gutenberg PDF corpus (canonical page
/// texts) plus labeled synthetic astral cases. Every case runs through
/// both implementations on identical UTF-16 text:
///
/// * the oracle, through `tool/reference/hypothesis_anchor_oracle/`
///   (Node; the bundle must be built from the pinned revision — see
///   that directory's README), and
/// * `DurableAnnotations.resolve` under `AnchorPolicy.explicitMigration`,
///   with the anchor captured through the real snapshot API.
///
/// Classification: an oracle hit where Unseal reports ambiguity (or
/// refuses inside its declared budgets) is an *expected stricter*
/// divergence — the plan requires our tie handling to be stricter than
/// the oracle's. A real divergence — different selected text, or Unseal
/// resolving where the oracle finds nothing — fails the comparison with
/// exit code 1. A missing oracle fails with exit code 2 and install
/// instructions; a missing oracle never counts as a pass.
library;

import 'dart:convert';
import 'dart:io';

import 'package:unseal/unseal.dart';

/// One comparison case, fed to both implementations.
final class _Case {
  _Case(
    this.id,
    this.kind,
    this.text,
    this.targetText,
    this.quoteStart,
    this.quoteEnd, {
    this.bareContext = false,
  });

  final String id;
  final String kind;
  final String text;
  final String targetText;
  final int quoteStart;
  final int quoteEnd;

  /// Whether the anchor resolves with its context stripped: the
  /// minimal-evidence case where the oracle's leftmost pick is a guess.
  final bool bareContext;
}

/// One classified comparison result.
final class _Result {
  _Result(this.caseId, this.kind, this.verdict, this.detail);

  final String caseId;
  final String kind;
  final String verdict;
  final String detail;
}

Future<void> main(final List<String> arguments) async {
  String? oracleBundle;
  var node = 'node';
  String? jsonOutput;
  for (var i = 0; i < arguments.length; i++) {
    switch (arguments[i]) {
      case '--oracle':
        oracleBundle = arguments[++i];
      case '--node':
        node = arguments[++i];
      case '--json':
        jsonOutput = arguments[++i];
      default:
        _usage('unknown argument ${arguments[i]}');
    }
  }
  if (oracleBundle == null) {
    _usage(
      '--oracle is required (the pinned matchQuote bundle); see '
      'tool/reference/hypothesis_anchor_oracle/README.md',
    );
  }

  final cases = _buildCases();
  final oracleAnswers = await _runOracle(node, oracleBundle, cases);

  final results = <_Result>[];
  for (var i = 0; i < cases.length; i++) {
    results.add(_compare(cases[i], oracleAnswers[i]));
  }

  _report(results, jsonOutput);
  final real = results.where((final r) => r.verdict == 'real-divergence').length;
  if (real > 0) {
    stderr.writeln('hypothesis_anchor_compare: $real real divergence(s)');
    exitCode = 1;
  }
}

Never _usage(final String message) {
  stderr.writeln('hypothesis_anchor_compare: $message');
  stderr.writeln(
    'usage: dart run tool/hypothesis_anchor_compare.dart --oracle <match-quote.cjs> '
    '[--node <node>] [--json <report.json>]',
  );
  exit(2);
}

/// Builds the comparison cases from the licensed corpus and labeled
/// synthetic text.
List<_Case> _buildCases() {
  final corpusDir = Directory('test/resources/pdf/gutenberg');
  if (!corpusDir.existsSync()) {
    stderr.writeln(
      'hypothesis_anchor_compare: missing test/resources/pdf/gutenberg; '
      'run `dart run tool/fetch_pdf_corpus.dart`',
    );
    exit(2);
  }
  final books =
      corpusDir
          .listSync()
          .whereType<File>()
          .where((final file) => file.path.endsWith('.pdf'))
          .toList()
        ..sort((final a, final b) => a.path.compareTo(b.path));

  final PdfBook book;
  try {
    book = books
        .map((final file) => parsePdfBook(file.readAsBytesSync()))
        .firstWhere((final parsed) => parsed.pageCount > 20);
  } on StateError {
    stderr.writeln('hypothesis_anchor_compare: corpus has no book over 20 pages');
    exit(2);
  }

  final cases = <_Case>[];
  final midPage = book.pageCount ~/ 2;
  for (final pageIndex in [midPage, midPage + 1]) {
    final text = buildPdfPageStructure(book: book, pageIndex: pageIndex).canonicalText;
    if (text.length < 600) continue;

    // Exact, unique-length run on a word boundary: both implementations
    // should anchor the same span.
    final (start, end) = _wordRun(text, 140);
    cases.add(_Case('page$pageIndex-exact', 'exact', text, text, start, end));

    // Corrected edition: one word replaced in the target.
    final corrected = _correctOneWord(text, start);
    cases.add(_Case('page$pageIndex-corrected', 'corrected', text, corrected, start, end));

    // Re-wrapped edition: whitespace runs collapsed in the target.
    final rewrapped = text.replaceAll(RegExp(r'\s+'), ' ');
    cases.add(_Case('page$pageIndex-rewrapped', 'rewrapped', text, rewrapped, start, end));

    // Repeated phrase: a short run known to occur at least twice — the
    // oracle picks the leftmost; Unseal must report the ambiguity.
    final repeated = _repeatedRun(text);
    if (repeated != null) {
      cases.add(_Case('page$pageIndex-repeated', 'repeated', text, text, repeated.$1, repeated.$2));
    }
  }

  // Removed target: a quote from one page searched in another's text.
  final pageA = buildPdfPageStructure(book: book, pageIndex: midPage).canonicalText;
  final pageB = buildPdfPageStructure(book: book, pageIndex: midPage + 5).canonicalText;
  final (goneStart, goneEnd) = _wordRun(pageA, 100);
  cases.add(_Case('removed-target', 'removed', pageA, pageB, goneStart, goneEnd));

  // Labeled synthetic astral case: both implementations count UTF-16
  // code units, so astral content must anchor identically.
  const astralText =
      'livro 📖 com nota 𝄞 e um trecho marcado no meio do texto '
      'para a âncora astral do comparador';
  final astralStart = astralText.indexOf('trecho marcado');
  cases.add(
    _Case(
      'synthetic-astral',
      'astral',
      astralText,
      astralText,
      astralStart,
      astralStart + 'trecho marcado'.length,
    ),
  );
  cases.add(
    _Case(
      'synthetic-repeated-identical',
      'repeated-identical',
      _repeatedIdenticalText,
      _repeatedIdenticalText,
      0,
      _repeatedIdenticalQuote.length,
      bareContext: true,
    ),
  );

  return cases;
}

/// The labeled synthetic repeated case: two identical occurrences with
/// identical (here: stripped) context — the declared stricter-than-
/// oracle behavior of C06/ANN03.
const _repeatedIdenticalText = 'trecho igual segue adiante trecho igual e fecha';
const _repeatedIdenticalQuote = 'trecho igual';

/// A word-boundary run of roughly [length] code units, starting at a
/// word's first character.
(int, int) _wordRun(final String text, final int length) {
  var start = text.length ~/ 3;
  while (start < text.length && !_isSpace(text.codeUnitAt(start))) {
    start++;
  }
  while (start < text.length && _isSpace(text.codeUnitAt(start))) {
    start++;
  }
  var end = start + length;
  while (end < text.length && !_isSpace(text.codeUnitAt(end))) {
    end++;
  }
  if (end >= text.length) {
    throw StateError('fixture page carries too little text');
  }

  return (start, end);
}

/// The shortest word-boundary run, from 16 up to 48 code units, that
/// occurs at least twice in [text] — the ambiguity case. Null when the
/// page carries no repetition (rare in running prose).
(int, int)? _repeatedRun(final String text) {
  for (final length in const [16, 20, 24, 32, 48]) {
    for (var start = 0; start + length < text.length; start++) {
      if (_isSpace(text.codeUnitAt(start))) continue;
      if (_isSpace(text.codeUnitAt(start + length - 1))) continue;
      final candidate = text.substring(start, start + length);
      if (text.indexOf(candidate, start + 1) > 0) {
        var end = start + length;
        while (end < text.length && !_isSpace(text.codeUnitAt(end))) {
          end++;
        }

        return (start, end);
      }
    }
  }

  return null;
}

/// Replaces one mid-quote word with another real word: a correction an
/// edition could make, inside both implementations' error budgets.
String _correctOneWord(final String text, final int quoteStart) {
  final window = text.substring(quoteStart, quoteStart + 140);
  final words = window.split(' ');
  for (var i = 2; i < words.length; i++) {
    if (words[i].length >= 4) {
      words[i] = words[i] == 'mundo' ? 'cenário' : 'mundo';
      final patched = words.join(' ');

      return text.substring(0, quoteStart) + patched + text.substring(quoteStart + 140);
    }
  }
  throw StateError('no replaceable word in the fixture quote');
}

bool _isSpace(final int unit) => unit == 0x20 || (unit >= 0x09 && unit <= 0x0D);

/// Runs every case through the pinned oracle in one Node invocation.
Future<List<Map<String, Object?>>> _runOracle(
  final String node,
  final String bundle,
  final List<_Case> cases,
) async {
  if (!File(bundle).existsSync()) {
    stderr.writeln(
      'hypothesis_anchor_compare: oracle bundle missing at $bundle; build it from '
      'the pinned revision — see tool/reference/hypothesis_anchor_oracle/README.md',
    );
    exit(2);
  }

  final payload = cases
      .map(
        (final c) => jsonEncode({
          'text': c.targetText,
          'exact': c.text.substring(c.quoteStart, c.quoteEnd),
          if (!c.bareContext) 'prefix': _prefixOf(c),
          if (!c.bareContext) 'suffix': _suffixOf(c),
        }),
      )
      .join('\n');

  final runner = Platform.script
      .resolve('reference/hypothesis_anchor_oracle/oracle_runner.cjs')
      .toFilePath();
  final process = await Process.start(node, [runner], environment: {'MATCH_QUOTE_BUNDLE': bundle});
  process.stdin.writeln(payload);
  await process.stdin.flush();
  await process.stdin.close();
  final stdoutFuture = process.stdout.transform(utf8.decoder).join();
  final stderrFuture = process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;
  final oracleOutput = await stdoutFuture;
  final oracleErrors = await stderrFuture;
  if (exitCode != 0) {
    stderr.writeln('hypothesis_anchor_compare: oracle runner failed: $oracleErrors');
    exit(2);
  }

  return oracleOutput
      .split('\n')
      .where((final line) => line.trim().isNotEmpty)
      .map((final line) => jsonDecode(line) as Map<String, Object?>)
      .toList();
}

String _prefixOf(final _Case c) {
  final from = c.quoteStart >= 96 ? c.quoteStart - 96 : 0;

  return c.text.substring(from, c.quoteStart);
}

String _suffixOf(final _Case c) {
  final to = c.quoteEnd + 96 > c.text.length ? c.text.length : c.quoteEnd + 96;

  return c.text.substring(c.quoteEnd, to);
}

/// Resolves the case through Unseal and classifies it against the
/// oracle's answer.
_Result _compare(final _Case c, final Map<String, Object?> oracle) {
  final identity = PublicationRevision(
    publicationId: 'compare:fixture',
    sourceRevision: 'sha256:${'ab' * 32}',
    sourceEvidence: SourceEvidence.sha256,
  );
  final revisedIdentity = PublicationRevision(
    publicationId: 'compare:fixture',
    sourceRevision: 'sha256:${'cd' * 32}',
    sourceEvidence: SourceEvidence.sha256,
  );
  final order = [('fixture.xhtml', true)];
  final snapshot = CanonicalTextSnapshot(
    identity: identity,
    occurrence: SectionOccurrence(
      sectionIndex: 0,
      resourcePath: 'fixture.xhtml',
      readingOrderRevision: RevisionDigest.readingOrderRevision(order),
    ),
    profile: TextProfile.of(
      algorithm: 'compare.fixture',
      options: const {},
      planRevision: RevisionDigest.textRevision('compare fixture 1'),
    ),
    text: c.text,
  );
  final target = CanonicalTextSnapshot(
    identity: revisedIdentity,
    occurrence: snapshot.occurrence,
    profile: snapshot.profile,
    text: c.targetText,
  );
  final captured = AnnotationAnchor.capture(
    snapshot: snapshot,
    start: c.quoteStart,
    end: c.quoteEnd,
  );
  final anchor = c.bareContext
      ? AnnotationAnchor.parts(
          identity: captured.identity,
          occurrence: captured.occurrence,
          profile: captured.profile,
          textRevision: captured.textRevision,
          start: captured.start,
          end: captured.end,
          quote: AnchorQuote(exact: captured.quote.exact),
        )
      : captured;
  final outcome = DurableAnnotations.resolve(
    anchor: anchor,
    targets: [target],
    policy: AnchorPolicy.explicitMigration,
  );

  final oracleStart = oracle['start'] as int?;
  final oracleEnd = oracle['end'] as int?;
  final oracleText = oracleStart == null
      ? null
      : c.targetText.substring(oracleStart, oracleEnd as int);

  String describe() {
    final oraclePart = oracleStart == null
        ? 'null'
        : '[$oracleStart,$oracleEnd) ${_clip(oracleText!)}';

    return 'unseal=${_unsealDescription(outcome, c.targetText)} oracle=$oraclePart';
  }

  if (oracleStart == null) {
    if (outcome is AnchorResolved) {
      return _Result(
        c.id,
        c.kind,
        'real-divergence',
        'unseal resolved where the oracle found nothing: ${describe()}',
      );
    }

    return _Result(c.id, c.kind, 'agree-miss', 'both found nothing');
  }

  if (outcome is AnchorAmbiguous) {
    return _Result(
      c.id,
      c.kind,
      'expected-stricter',
      'unseal reports ${outcome.candidates.length} indistinguishable candidates; '
          'the oracle picks the leftmost (${describe()})',
    );
  }
  if (outcome is AnchorMissing) {
    return _Result(
      c.id,
      c.kind,
      'expected-stricter',
      'unseal refuses inside its declared budgets where the oracle matched: ${describe()}',
    );
  }
  if (outcome is! AnchorResolved) {
    return _Result(c.id, c.kind, 'real-divergence', describe());
  }

  final ourText = outcome.range.text;
  if (ourText == oracleText) {
    final offsets = outcome.range.start == oracleStart && outcome.range.end == oracleEnd
        ? 'offsets identical'
        : 'same text at different offsets';

    return _Result(c.id, c.kind, 'agree', '$offsets; ${describe()}');
  }

  return _Result(
    c.id,
    c.kind,
    'real-divergence',
    'unseal selected "${_clip(ourText)}" and the oracle selected "${_clip(oracleText ?? '')}"',
  );
}

String _unsealDescription(final AnchorResolution outcome, final String targetText) {
  switch (outcome) {
    case AnchorResolved(:final range, :final basis, :final editDistance):
      return 'resolved ${basis.name}[$range) "${_clip(range.text)}"'
          '${editDistance == null ? '' : ' distance=$editDistance'}';
    case AnchorAmbiguous(:final candidates, :final truncated):
      return 'ambiguous (${candidates.length}${truncated ? '+ truncated' : ''})';
    case AnchorMissing(:final reason, :final fuzzySkipped):
      return 'missing ${reason.name}${fuzzySkipped ? ' (fuzzy skipped)' : ''}';
    case AnchorIncompatibleRevision(:final kind, :final differingFields):
      return 'incompatibleRevision ${kind.name} $differingFields';
    case AnchorUnsupported(:final reason):
      return 'unsupported ${reason.name}';
  }
}

String _clip(final String text) {
  final clipped = text.length <= 48 ? text : '${text.substring(0, 45)}…';

  return clipped.replaceAll('\n', '\\n');
}

void _report(final List<_Result> results, final String? jsonOutput) {
  final counts = <String, int>{};
  for (final result in results) {
    counts[result.verdict] = (counts[result.verdict] ?? 0) + 1;
    stdout.writeln('${result.verdict.padRight(18)} ${result.caseId.padRight(24)} ${result.detail}');
  }
  stdout.writeln();
  stdout.writeln(
    'cases: ${results.length}; '
    'agreements: ${(counts['agree'] ?? 0) + (counts['agree-miss'] ?? 0)}; '
    'expected-stricter: ${counts['expected-stricter'] ?? 0}; '
    'real-divergences: ${counts['real-divergence'] ?? 0}',
  );

  if (jsonOutput != null) {
    final report = results
        .map(
          (final r) => {'case': r.caseId, 'kind': r.kind, 'verdict': r.verdict, 'detail': r.detail},
        )
        .toList();
    File(jsonOutput).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln('report written to $jsonOutput');
  }
}
