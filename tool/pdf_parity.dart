/// PDF parity harness: measures how close eLivre's pure-Dart PDF
/// extraction is to the Calibre/Poppler reference tooling on the same
/// files. Report-only by design — the numbers are a ruler, not a gate.
///
/// Levels:
///
/// 1. Extraction (default): for every page, compare eLivre's canonical
///    page text (`parsePdfBook(...).pageTexts[N].text`) against
///    `pdftotext -enc UTF-8 -f N -l N -raw <pdf> -`. Scores per page:
///    Dice coefficient over character bigrams of the two normalized
///    strings plus the lesser/greater length ratio.
/// 2. `--metadata`: parses `pdfinfo -isodates <pdf>` and compares
///    Title, Author and page count against `readPdfMetadata`,
///    reporting each field as match / diff / missing.
/// 3. `--reflow`: converts the PDF with
///    `ebook-convert <pdf> <tmp>/out.epub`, unpacks the EPUB with
///    package:archive, concatenates `documentText` of the content
///    HTML files in numeric filename order and scores the whole book
///    against the concatenation of eLivre's canonical page texts.
///
/// Reference binaries are resolved inside the Calibre app bundle
/// (`/Applications/calibre.app`); when the bundle is absent the
/// harness prints a note and exits 0 (skipped).
///
/// Usage:
///
/// ```
/// dart run tool/pdf_parity.dart [directory] [--json out.json]
///     [--metadata] [--reflow] [--case-insensitive]
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/pdf/header/pdf_document.dart';
import 'package:e_livre/src/features/pdf/header/pdf_object.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_page_tree.dart';
import 'package:e_livre/src/features/pdf/utils/pdf_bitmap.dart';
import 'package:e_livre/src/features/pdf/utils/pdf_stream_filters.dart';
import 'package:path/path.dart' as p;

/// Directory scanned when no positional argument is given.
const String _defaultDirectory = 'test/resources/pdf';

/// Root of the Calibre app bundle holding the reference binaries.
const String _calibreBundle = '/Applications/calibre.app';

/// Page similarity above which a page counts as aligned.
const double _divergenceThreshold = 0.9;

/// Characters kept in each side-by-side snippet of a divergent page.
const int _snippetLength = 80;

/// Divergent pages listed per book.
const int _maxDivergentPages = 5;

/// Generous budget for `ebook-convert`, which boots a Python stack.
const Duration _reflowTimeout = Duration(seconds: 120);

/// Fold map: every key is folded to its value on both sides of a
/// comparison. Keep the [_foldablePattern] character class in sync
/// with these keys (full range coverage, no misses).
const Map<String, String> _foldMap = <String, String>{
  // Typographic (fancy) ligatures to expanded forms.
  '\uFB00': 'ff',
  '\uFB01': 'fi',
  '\uFB02': 'fl',
  '\uFB03': 'ffi',
  '\uFB04': 'ffl',
  // Fancy single quotes / apostrophes.
  '\u2018': "'",
  '\u2019': "'",
  '\u201A': "'",
  '\u201B': "'",
  // Fancy double quotes.
  '\u201C': '"',
  '\u201D': '"',
  '\u201E': '"',
  '\u201F': '"',
  // Dashes and hyphen variants to the ASCII hyphen-minus.
  '\u2010': '-',
  '\u2011': '-',
  '\u2012': '-',
  '\u2013': '-',
  '\u2014': '-',
  '\u2015': '-',
  '\u2212': '-',
  // Horizontal ellipsis to three dots.
  '\u2026': '...',
  // Prime marks.
  '\u2032': "'",
  '\u2033': '"',
};

/// Matches exactly the characters folded by [_foldMap].
final RegExp _foldablePattern = RegExp(
  '[\uFB00-\uFB04\u2010-\u2015\u2018-\u201F\u2026\u2032\u2033\u2212]',
);

/// ECMAScript `\s` (Dart RegExp is ECMAScript-flavoured) already
/// covers NBSP, U+2028/9, ideographic spaces and the BOM/ZWNBSP.
final RegExp _whitespaceRun = RegExp(r'\s+');

/// CLI options gathered from the command line.
class _Options {
  /// Creates the option set.
  const _Options({
    required this.directory,
    required this.jsonPath,
    required this.runMetadata,
    required this.runReflow,
    required this.runImage,
    required this.updateGoldens,
    required this.caseInsensitive,
  });

  /// Directory scanned for `.pdf` files (recursive).
  final String directory;

  /// Where the JSON report is written, or null to skip it.
  final String? jsonPath;

  /// Whether the pdfinfo metadata level runs.
  final bool runMetadata;

  /// Whether the ebook-convert reflow level runs.
  final bool runReflow;

  /// Whether the image-decode parity level runs.
  final bool runImage;

  /// Whether oracle rasters are (re)written into the goldens directory.
  final bool updateGoldens;

  /// Whether text normalization also casefolds both sides.
  final bool caseInsensitive;
}

/// Outcome of parsing the command line: [options] is null when the
/// run should stop after printing usage, with [exitCode] as status.
class _CliParse {
  /// Creates the parse outcome.
  const _CliParse(this.options, this.exitCode);

  /// Parsed options, or null for `--help` / usage errors.
  final _Options? options;

  /// Process exit code for the stop case.
  final int exitCode;
}

/// Resolved reference binaries; null means the binary is not available.
class _Tools {
  /// Creates the tool set.
  const _Tools({this.pdftotext, this.pdfinfo, this.ebookConvert});

  /// Discovers the binaries inside the Calibre app bundle.
  factory _Tools.discover() {
    String? locate(final String relative) {
      final candidate = '$_calibreBundle/$relative';
      return File(candidate).existsSync() ? candidate : null;
    }

    return _Tools(
      pdftotext: locate('Contents/utils.app/Contents/MacOS/pdftotext'),
      pdfinfo: locate('Contents/utils.app/Contents/MacOS/pdfinfo'),
      ebookConvert: locate('Contents/MacOS/ebook-convert'),
    );
  }

  /// `pdftotext` (Poppler, shipped inside Calibre's utils app).
  final String? pdftotext;

  /// `pdfinfo` (Poppler, shipped inside Calibre's utils app).
  final String? pdfinfo;

  /// Calibre's conversion driver.
  final String? ebookConvert;
}

/// Captured output of one reference command.
class _ProcessOutput {
  /// Creates the captured output.
  const _ProcessOutput(this.exitCode, this.standardOutput, this.standardError);

  /// Process exit code.
  final int exitCode;

  /// Decoded stdout (UTF-8, malformed sequences allowed).
  final String standardOutput;

  /// Decoded stderr (UTF-8, malformed sequences allowed).
  final String standardError;
}

/// Per-page extraction comparison.
class _PageMetric {
  /// Creates the page metric.
  const _PageMetric({
    required this.page,
    required this.similarity,
    required this.lengthRatio,
    required this.referenceChars,
    required this.ourChars,
    required this.referenceSnippet,
    required this.ourSnippet,
  });

  /// 1-based page number.
  final int page;

  /// Dice coefficient over character bigrams of the normalized texts.
  final double similarity;

  /// lesser/greater character-length ratio of the normalized texts.
  final double lengthRatio;

  /// Normalized reference length in characters.
  final int referenceChars;

  /// Normalized eLivre length in characters.
  final int ourChars;

  /// Head of the normalized reference text (for divergent pages).
  final String referenceSnippet;

  /// Head of the normalized eLivre text (for divergent pages).
  final String ourSnippet;

  /// Whether the page sits at or below the divergence threshold.
  bool get isDivergent => similarity <= _divergenceThreshold;
}

/// Result of one metadata field comparison.
class _MetadataField {
  /// Creates the field comparison.
  const _MetadataField(this.field, this.status, this.pdfinfoValue, this.eLivreValue);

  /// Field name (`Title`, `Author` or `Pages`).
  final String field;

  /// One of `match`, `diff` or `missing`.
  final String status;

  /// Value reported by pdfinfo (null when absent).
  final String? pdfinfoValue;

  /// Value extracted by eLivre (null when absent).
  final String? eLivreValue;
}

/// Metadata level result for one book.
class _MetadataReport {
  /// Creates the metadata report.
  const _MetadataReport(this.available, this.fields, this.error);

  /// A report for the case where pdfinfo could not run.
  const _MetadataReport.unavailable(this.error)
    : available = false,
      fields = const <_MetadataField>[];

  /// Whether pdfinfo ran at all.
  final bool available;

  /// One entry per compared field (always Title, Author, Pages).
  final List<_MetadataField> fields;

  /// Why pdfinfo could not run, when it failed.
  final String? error;

  /// Number of fields that agree.
  int get matchCount => fields.where((final field) => field.status == 'match').length;
}

/// Reflow level result for one book.
class _ReflowReport {
  /// Creates the reflow report.
  const _ReflowReport({
    required this.available,
    required this.error,
    required this.similarity,
    required this.charRatio,
    required this.referenceChars,
    required this.ourChars,
  });

  /// A report for the case where conversion could not run.
  const _ReflowReport.failed(this.error)
    : available = true,
      similarity = null,
      charRatio = null,
      referenceChars = null,
      ourChars = null;

  /// A report for the case where the level was not requested.
  const _ReflowReport.skipped()
    : available = false,
      error = null,
      similarity = null,
      charRatio = null,
      referenceChars = null,
      ourChars = null;

  /// A report for the case where the reference tool is missing.
  const _ReflowReport.unavailable(this.error)
    : available = false,
      similarity = null,
      charRatio = null,
      referenceChars = null,
      ourChars = null;

  /// Whether ebook-convert ran at all.
  final bool available;

  /// Why the conversion failed, when it did.
  final String? error;

  /// Whole-book Dice over character bigrams, or null on failure.
  final double? similarity;

  /// Whole-book lesser/greater character ratio, or null on failure.
  final double? charRatio;

  /// Normalized Calibre EPUB text length, or null on failure.
  final int? referenceChars;

  /// Normalized eLivre canonical text length, or null on failure.
  final int? ourChars;
}

/// Full report for one book.
class _BookReport {
  /// Creates the book report.
  const _BookReport({
    required this.displayPath,
    required this.pageCount,
    required this.pages,
    required this.errors,
    required this.metadata,
    required this.reflow,
  });

  /// Path as shown in the console table.
  final String displayPath;

  /// Number of document pages eLivre found.
  final int pageCount;

  /// One metric per successfully compared page.
  final List<_PageMetric> pages;

  /// Fatal problems recorded instead of metrics (parse failures...).
  final List<String> errors;

  /// Metadata level result.
  final _MetadataReport metadata;

  /// Reflow level result.
  final _ReflowReport reflow;

  /// Mean page similarity (0 when nothing compared).
  double get meanSimilarity => pages.isEmpty
      ? 0
      : pages.fold(0.0, (final sum, final page) => sum + page.similarity) / pages.length;

  /// The lowest-similarity page, or null when nothing compared.
  _PageMetric? get worstPage {
    _PageMetric? worst;
    for (final page in pages) {
      if (worst == null || page.similarity < worst.similarity) {
        worst = page;
      }
    }
    return worst;
  }

  /// Divergent pages, worst first, capped at [_maxDivergentPages].
  List<_PageMetric> get divergentPages {
    final divergent = pages.where((final page) => page.isDivergent).toList()
      ..sort((final a, final b) => a.similarity.compareTo(b.similarity));
    return divergent.take(_maxDivergentPages).toList();
  }

  /// Percentage of compared pages above the divergence threshold.
  double get percentAboveThreshold => pages.isEmpty
      ? 0
      : 100 * pages.where((final page) => !page.isDivergent).length / pages.length;
}

/// Runs one reference command, capturing both streams as UTF-8 with
/// malformed sequences allowed. Returns null when the executable could
/// not be started or overran [timeout] (the child may linger; the
/// harness is a one-shot report tool and does not chase it).
Future<_ProcessOutput?> _runCommand(
  final String executable,
  final List<String> arguments, {
  final Duration timeout = const Duration(seconds: 60),
}) async {
  try {
    final result = await Process.run(
      executable,
      arguments,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
      stderrEncoding: const Utf8Codec(allowMalformed: true),
    ).timeout(timeout);
    return _ProcessOutput(result.exitCode, result.stdout as String, result.stderr as String);
  } on ProcessException {
    return null;
  } on TimeoutException {
    return null;
  }
}

/// Normalizes a text sample for scoring. Pragmatic by design: real
/// Unicode normalization (NFC) is unavailable without a new
/// dependency, so both sides receive the same best-effort folding and
/// the residual gap is reported, not hidden. Choices, in order:
///
/// 1. Remove soft hyphen U+00AD (hyphenation artifact), BOM U+FEFF and
///    zero-width space U+200B: invisible on both sides.
/// 2. Fold ligatures to expanded forms (fi, fl, ff, ffi, ffl) because
///    PDF cmaps and Calibre's HTML disagree on which form survives.
/// 3. Fold fancy quotes, dashes, primes and the ellipsis to their
///    ASCII shapes for the same reason.
/// 4. Collapse whitespace runs (newlines included) to one space and
///    trim: line-break policy differences between raw-mode Poppler
///    output and eLivre's canonical line list must not dominate the
///    metric. ECMAScript `\s` already eats NBSP and friends.
/// 5. Casefold only when [caseInsensitive] is set.
///
/// Deliberately not done: dehyphenating `word- \n continuation` (an
/// asymmetric heuristic would inflate the score) and any reordering
/// tolerance (character bigrams stay order-sensitive).
String _normalizeText(final String input, {required final bool caseInsensitive}) {
  var text = input.replaceAll('\u00AD', '').replaceAll('\uFEFF', '').replaceAll('\u200B', '');
  text = text.replaceAllMapped(_foldablePattern, (final match) => _foldMap[match[0]!]!);
  text = text.replaceAll(_whitespaceRun, ' ').trim();
  if (caseInsensitive) {
    text = text.toLowerCase();
  }
  return text;
}

/// Dice coefficient over character bigrams of [a] and [b].
///
/// `2|A ∩ B| / (|A| + |B|)` on bigram multisets; two empty (or equal
/// sub-2-character) strings count as identical.
double _diceBigramSimilarity(final String a, final String b) {
  if (a.length < 2 || b.length < 2) {
    return a == b ? 1 : 0;
  }
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

/// lesser/greater character-length ratio of [a] and [b].
double _lengthRatio(final String a, final String b) {
  final greater = math.max(a.length, b.length);
  if (greater == 0) {
    return 1;
  }
  return math.min(a.length, b.length) / greater;
}

/// Head of [text] as a one-line snippet of at most [_snippetLength].
String _snippet(final String text) {
  final flat = text.replaceAll(_whitespaceRun, ' ').trim();
  return flat.length <= _snippetLength ? flat : flat.substring(0, _snippetLength);
}

/// Parses `--flag`, `--flag value` and `--flag=value` CLI shapes.
_CliParse _parseOptions(final List<String> arguments) {
  final directory = _defaultDirectory;
  String? jsonPath;
  var runMetadata = false;
  var runReflow = false;
  var runImage = false;
  var updateGoldens = false;
  var caseInsensitive = false;
  String? positional;

  for (var i = 0; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '-h' || argument == '--help') {
      _printUsage(stdout);
      return const _CliParse(null, 0);
    }
    if (argument.startsWith('--')) {
      final split = argument.indexOf('=');
      final name = split == -1 ? argument : argument.substring(0, split);
      final inline = split == -1 ? null : argument.substring(split + 1);
      switch (name) {
        case '--metadata':
          runMetadata = true;
        case '--reflow':
          runReflow = true;
        case '--image':
          runImage = true;
        case '--update-goldens':
          updateGoldens = true;
        case '--case-insensitive':
          caseInsensitive = true;
        case '--json':
          final value = inline ?? (i + 1 < arguments.length ? arguments[++i] : null);
          if (value == null || value.isEmpty) {
            stderr.writeln('error: --json requires a file path.');
            _printUsage(stderr);
            return const _CliParse(null, 2);
          }
          jsonPath = value;
        default:
          stderr.writeln('error: unknown option $name.');
          _printUsage(stderr);
          return const _CliParse(null, 2);
      }
      continue;
    }
    if (argument.startsWith('-')) {
      stderr.writeln('error: unknown option $argument.');
      _printUsage(stderr);
      return const _CliParse(null, 2);
    }
    if (positional != null) {
      stderr.writeln('error: unexpected extra argument $argument.');
      return const _CliParse(null, 2);
    }
    positional = argument;
  }

  return _CliParse(
    _Options(
      directory: p.normalize(p.absolute(positional ?? directory)),
      jsonPath: jsonPath,
      runMetadata: runMetadata,
      runReflow: runReflow,
      runImage: runImage,
      updateGoldens: updateGoldens,
      caseInsensitive: caseInsensitive,
    ),
    0,
  );
}

/// Prints the CLI usage to [sink].
void _printUsage(final IOSink sink) {
  sink.writeln(
    'usage: dart run tool/pdf_parity.dart [directory] [--json out.json] '
    '[--metadata] [--reflow] [--image] [--update-goldens] [--case-insensitive]',
  );
  sink.writeln('  directory            scanned recursively for .pdf (default: $_defaultDirectory)');
  sink.writeln('  --json <path>        writes the full structured report');
  sink.writeln('  --metadata           compares pdfinfo against readPdfMetadata');
  sink.writeln('  --reflow             compares ebook-convert EPUB text against the');
  sink.writeln('                       canonical page texts via documentText');
  sink.writeln('  --image              compares CCITT/JBIG2 image decodes against the');
  sink.writeln('                       pdf.js oracle raster (node, pdfjs-dist 3.11.174)');
  sink.writeln('  --update-goldens     refreshes the oracle rasters committed under');
  sink.writeln('                       test/resources/pdf/reference/goldens/');
  sink.writeln('  --case-insensitive   also casefolds both sides before scoring');
}

/// Collects every `.pdf` under [root], sorted by path.
List<File> _collectPdfs(final Directory root) {
  final files = <File>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.pdf')) {
      files.add(entity);
    }
  }
  files.sort((final a, final b) => a.path.compareTo(b.path));
  return files;
}

/// Runs the extraction level for one book: one `pdftotext` call per
/// page against eLivre's canonical page text.
Future<List<_PageMetric>> _compareExtraction({
  required final PdfBook book,
  required final File pdf,
  required final String? pdftotext,
  required final bool caseInsensitive,
  required final List<String> errors,
}) async {
  final metrics = <_PageMetric>[];
  if (pdftotext == null) {
    errors.add('pdftotext not available; extraction level skipped.');
    return metrics;
  }
  for (var index = 0; index < book.pageTexts.length; index++) {
    final page = index + 1;
    final output = await _runCommand(pdftotext, <String>[
      '-enc',
      'UTF-8',
      '-f',
      '$page',
      '-l',
      '$page',
      '-raw',
      pdf.path,
      '-',
    ]);
    if (output == null) {
      errors.add('page $page: failed to start pdftotext.');
      continue;
    }
    if (output.exitCode != 0) {
      errors.add(
        'page $page: pdftotext exited ${output.exitCode}: '
        '${_snippet(output.standardError)}',
      );
      continue;
    }
    final reference = _normalizeText(output.standardOutput, caseInsensitive: caseInsensitive);
    final ours = _normalizeText(book.pageTexts[index].text, caseInsensitive: caseInsensitive);
    metrics.add(
      _PageMetric(
        page: page,
        similarity: _diceBigramSimilarity(reference, ours),
        lengthRatio: _lengthRatio(reference, ours),
        referenceChars: reference.length,
        ourChars: ours.length,
        referenceSnippet: _snippet(reference),
        ourSnippet: _snippet(ours),
      ),
    );
  }
  return metrics;
}

/// Runs the metadata level for one book: `pdfinfo -isodates` parsed
/// as `Key: value` lines against `readPdfMetadata`.
Future<_MetadataReport> _compareMetadata({
  required final Uint8List bytes,
  required final File pdf,
  required final int pageCount,
  required final String pdfinfo,
  required final bool caseInsensitive,
}) async {
  final output = await _runCommand(pdfinfo, <String>['-isodates', pdf.path]);
  if (output == null) {
    return const _MetadataReport.unavailable('failed to start pdfinfo.');
  }
  if (output.exitCode != 0) {
    return _MetadataReport(
      true,
      const <_MetadataField>[],
      'pdfinfo exited ${output.exitCode}: ${_snippet(output.standardError)}',
    );
  }

  // pdfinfo prints `Key: value` lines; keep the last occurrence of
  // each key (some builds wrap long values onto continuation lines,
  // whose leading whitespace makes indexOf(':') skip them safely).
  final reported = <String, String>{};
  for (final line in output.standardOutput.split('\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0 || line.startsWith(' ')) {
      continue;
    }
    reported[line.substring(0, separator).trim()] = line.substring(separator + 1).trim();
  }

  final BookMetadata ours;
  try {
    ours = readPdfMetadata(bytes);
  } on Exception catch (error) {
    return _MetadataReport(true, const <_MetadataField>[], 'readPdfMetadata failed: $error');
  }

  final fields = <_MetadataField>[
    _compareTextualField('Title', reported['Title'], ours.title, caseInsensitive),
    _compareAuthorField(reported['Author'], ours.authors, caseInsensitive),
    _comparePageField(reported['Pages'], pageCount),
  ];
  return _MetadataReport(true, fields, null);
}

/// Compares one free-text metadata field by normalized equality.
_MetadataField _compareTextualField(
  final String field,
  final String? pdfinfoValue,
  final String? eLivreValue,
  final bool caseInsensitive,
) {
  final referenceEmpty = pdfinfoValue == null || pdfinfoValue.isEmpty;
  final oursEmpty = eLivreValue == null || eLivreValue.isEmpty;
  if (referenceEmpty) {
    return oursEmpty
        ? _MetadataField(field, 'match', null, null)
        : _MetadataField(field, 'missing', null, eLivreValue);
  }
  if (oursEmpty) {
    return _MetadataField(field, 'missing', pdfinfoValue, null);
  }
  final matches =
      _normalizeText(pdfinfoValue, caseInsensitive: caseInsensitive) ==
      _normalizeText(eLivreValue, caseInsensitive: caseInsensitive);
  return _MetadataField(field, matches ? 'match' : 'diff', pdfinfoValue, eLivreValue);
}

/// Compares the author field as sets of names: pdfinfo joins authors
/// with `, ` or ` and `; eLivre keeps a list.
_MetadataField _compareAuthorField(
  final String? pdfinfoValue,
  final List<String> authors,
  final bool caseInsensitive,
) {
  if (pdfinfoValue == null || pdfinfoValue.isEmpty) {
    return authors.isEmpty
        ? _MetadataField('Author', 'match', null, null)
        : _MetadataField('Author', 'missing', null, authors.join(', '));
  }
  if (authors.isEmpty) {
    return _MetadataField('Author', 'missing', pdfinfoValue, null);
  }
  String fold(final String raw) =>
      _normalizeText(raw.replaceAll(' and ', ', '), caseInsensitive: caseInsensitive);
  final reference = fold(
    pdfinfoValue,
  ).split(',').map((final name) => name.trim()).where((final name) => name.isNotEmpty).toSet();
  final ours = authors.map(fold).toSet();
  final matches = reference.length == ours.length && reference.containsAll(ours);
  return _MetadataField('Author', matches ? 'match' : 'diff', pdfinfoValue, authors.join(', '));
}

/// Compares the page count reported by pdfinfo against eLivre's.
_MetadataField _comparePageField(final String? pdfinfoValue, final int pageCount) {
  final parsed = pdfinfoValue == null ? null : int.tryParse(pdfinfoValue.trim());
  if (parsed == null) {
    return _MetadataField('Pages', 'missing', pdfinfoValue, '$pageCount');
  }
  return _MetadataField('Pages', parsed == pageCount ? 'match' : 'diff', '$parsed', '$pageCount');
}

/// Zero-pads digit runs so plain string order matches numeric order
/// for the `index_split_000.html`-style names Calibre emits.
String _naturalKey(final String name) =>
    name.replaceAllMapped(RegExp(r'(\d+)'), (final match) => match[1]!.padLeft(8, '0'));

/// Concatenation of eLivre's canonical page texts: the page line lists
/// joined with `\n`, the same space `documentText` reads in the HTML.
String _canonicalBookText(final PdfBook book) =>
    book.pageTexts.map((final page) => page.text).join('\n');

/// Runs the reflow level for one book: converts to EPUB with Calibre,
/// unpacks it and scores the concatenated `documentText` of the
/// content HTML files (numeric filename order) against the
/// concatenation of eLivre's canonical page texts.
Future<_ReflowReport> _compareReflow({
  required final PdfBook book,
  required final File pdf,
  required final String ebookConvert,
  required final bool caseInsensitive,
}) async {
  final Directory temp;
  try {
    temp = await Directory.systemTemp.createTemp('pdf_parity_');
  } on FileSystemException catch (error) {
    return _ReflowReport.failed('could not create temp dir: $error');
  }
  try {
    final epubPath = p.join(temp.path, 'out.epub');
    final output = await _runCommand(ebookConvert, <String>[
      pdf.path,
      epubPath,
    ], timeout: _reflowTimeout);
    if (output == null) {
      return _ReflowReport.failed('ebook-convert failed or timed out after 120s.');
    }
    if (output.exitCode != 0) {
      return _ReflowReport.failed(
        'ebook-convert exited ${output.exitCode}: ${_snippet(output.standardError)}',
      );
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(File(epubPath).readAsBytesSync());
    } on Exception catch (error) {
      return _ReflowReport.failed('could not read the produced EPUB: $error');
    }

    final htmlEntries = <ArchiveFile>[];
    for (final entry in archive) {
      if (!entry.isFile) {
        continue;
      }
      final lower = entry.name.toLowerCase();
      if ((lower.endsWith('.html') || lower.endsWith('.xhtml')) && !lower.contains('__macosx')) {
        htmlEntries.add(entry);
      }
    }
    if (htmlEntries.isEmpty) {
      return _ReflowReport.failed('the produced EPUB carries no HTML documents.');
    }
    htmlEntries.sort((final a, final b) => _naturalKey(a.name).compareTo(_naturalKey(b.name)));

    final buffer = StringBuffer();
    for (final entry in htmlEntries) {
      final content = entry.content as List<int>;
      buffer.write(documentText(utf8.decode(content, allowMalformed: true)));
    }
    final reference = _normalizeText(buffer.toString(), caseInsensitive: caseInsensitive);
    final ours = _normalizeText(_canonicalBookText(book), caseInsensitive: caseInsensitive);
    return _ReflowReport(
      available: true,
      error: null,
      similarity: _diceBigramSimilarity(reference, ours),
      charRatio: _lengthRatio(reference, ours),
      referenceChars: reference.length,
      ourChars: ours.length,
    );
  } finally {
    try {
      temp.deleteSync(recursive: true);
    } on FileSystemException {
      // Best-effort cleanup; a leftover temp dir is harmless.
    }
  }
}

/// Evaluates all requested levels for one PDF.
Future<_BookReport> _evaluateBook({
  required final File pdf,
  required final _Options options,
  required final _Tools tools,
}) async {
  final errors = <String>[];
  Uint8List bytes;
  try {
    bytes = pdf.readAsBytesSync();
  } on FileSystemException catch (error) {
    errors.add('could not read file: $error');
    return _BookReport(
      displayPath: _displayPath(pdf, options),
      pageCount: 0,
      pages: const <_PageMetric>[],
      errors: errors,
      metadata: _MetadataReport.unavailable('file unreadable.'),
      reflow: const _ReflowReport.skipped(),
    );
  }

  final PdfBook book;
  try {
    book = parsePdfBook(bytes);
  } on Exception catch (error) {
    errors.add('parsePdfBook failed: $error');
    return _BookReport(
      displayPath: _displayPath(pdf, options),
      pageCount: 0,
      pages: const <_PageMetric>[],
      errors: errors,
      metadata: _MetadataReport.unavailable('parse failed.'),
      reflow: const _ReflowReport.skipped(),
    );
  }

  final pages = await _compareExtraction(
    book: book,
    pdf: pdf,
    pdftotext: tools.pdftotext,
    caseInsensitive: options.caseInsensitive,
    errors: errors,
  );

  var metadata = const _MetadataReport.unavailable('pdfinfo not available.');
  if (options.runMetadata) {
    metadata = tools.pdfinfo == null
        ? const _MetadataReport.unavailable('pdfinfo not available.')
        : await _compareMetadata(
            bytes: bytes,
            pdf: pdf,
            pageCount: book.pageCount,
            pdfinfo: tools.pdfinfo!,
            caseInsensitive: options.caseInsensitive,
          );
  }

  var reflow = const _ReflowReport.skipped();
  if (options.runReflow) {
    reflow = tools.ebookConvert == null
        ? const _ReflowReport.unavailable('ebook-convert not available.')
        : await _compareReflow(
            book: book,
            pdf: pdf,
            ebookConvert: tools.ebookConvert!,
            caseInsensitive: options.caseInsensitive,
          );
  }

  return _BookReport(
    displayPath: _displayPath(pdf, options),
    pageCount: book.pageCount,
    pages: pages,
    errors: errors,
    metadata: metadata,
    reflow: reflow,
  );
}

/// Path shown in the table: relative to the scanned directory.
String _displayPath(final File pdf, final _Options options) =>
    p.relative(pdf.path, from: options.directory);

/// Renders the aligned console table plus the footer summary.
void _printConsoleReport(final List<_BookReport> books, final _Options options) {
  final headers = <String>['file', 'pages', 'mean', 'worst', '%>0.9', 'extra'];
  final rows = <List<String>>[for (final book in books) _tableRow(book, options)];

  final widths = List<int>.generate(headers.length, (final column) => headers[column].length);
  for (final row in rows) {
    for (var column = 0; column < row.length; column++) {
      widths[column] = math.max(widths[column], row[column].length);
    }
  }
  String line(final List<String> cells) =>
      '  ${[for (var column = 0; column < cells.length; column++) cells[column].padRight(widths[column])].join('  ').trimRight()}';

  stdout.writeln();
  stdout.writeln(line(headers));
  stdout.writeln('  ${[for (final width in widths) '-' * width].join('  ')}');
  for (final row in rows) {
    stdout.writeln(line(row));
  }

  for (final book in books) {
    for (final error in book.errors) {
      stdout.writeln('  ! ${book.displayPath}: $error');
    }
    for (final page in book.divergentPages) {
      stdout.writeln();
      stdout.writeln(
        '  divergent page ${page.page} '
        '(similarity ${page.similarity.toStringAsFixed(4)}, ratio ${page.lengthRatio.toStringAsFixed(3)}):',
      );
      stdout.writeln('    reference: "${page.referenceSnippet}"');
      stdout.writeln('    ours:      "${page.ourSnippet}"');
    }
    for (final field in book.metadata.fields) {
      if (field.status == 'match') {
        continue;
      }
      stdout.writeln(
        '  metadata ${book.displayPath} ${field.field} ${field.status}: '
        'pdfinfo=${field.pdfinfoValue ?? '<absent>'} | e_livre=${field.eLivreValue ?? '<absent>'}',
      );
    }
    if (options.runMetadata && book.metadata.error != null) {
      stdout.writeln('  metadata ${book.displayPath}: ${book.metadata.error}');
    }
    if (options.runReflow && book.reflow.error != null) {
      stdout.writeln('  reflow ${book.displayPath}: ${book.reflow.error}');
    }
  }

  final comparedPages = books.fold<int>(0, (final sum, final book) => sum + book.pages.length);
  final globalMean = comparedPages == 0
      ? 0.0
      : books.fold<double>(
              0,
              (final sum, final book) => sum + book.meanSimilarity * book.pages.length,
            ) /
            comparedPages;
  final above = books.fold<int>(
    0,
    (final sum, final book) => sum + book.pages.where((final page) => !page.isDivergent).length,
  );
  stdout.writeln();
  stdout.writeln(
    'summary: ${books.length} book(s), $comparedPages page(s) compared | '
    'extraction mean ${globalMean.toStringAsFixed(4)} | '
    'pages >0.9 $above/$comparedPages '
    '(${comparedPages == 0 ? 0.0 : 100 * above / comparedPages}%)',
  );
  if (options.runMetadata) {
    final totalFields = books.fold<int>(
      0,
      (final sum, final book) => sum + book.metadata.fields.length,
    );
    final matchFields = books.fold<int>(
      0,
      (final sum, final book) => sum + book.metadata.matchCount,
    );
    stdout.writeln('metadata: $matchFields/$totalFields field(s) match');
  }
  if (options.runReflow) {
    final scored = books.where((final book) => book.reflow.similarity != null).toList();
    final reflowMean = scored.isEmpty
        ? 0.0
        : scored.fold<double>(0, (final sum, final book) => sum + book.reflow.similarity!) /
              scored.length;
    stdout.writeln(
      'reflow: ${scored.length}/${books.length} book(s) scored, '
      'mean similarity ${reflowMean.toStringAsFixed(4)}',
    );
  }
}

/// Builds one aligned table row for [book].
List<String> _tableRow(final _BookReport book, final _Options options) {
  final extras = <String>[];
  if (options.runMetadata) {
    extras.add(
      book.metadata.available
          ? 'meta ${book.metadata.matchCount}/${book.metadata.fields.length}'
          : 'meta n/a',
    );
  }
  if (options.runReflow) {
    final similarity = book.reflow.similarity;
    extras.add(similarity == null ? 'reflow n/a' : 'reflow ${similarity.toStringAsFixed(4)}');
  }
  final worst = book.worstPage;
  return <String>[
    book.displayPath,
    '${book.pageCount}',
    book.pages.isEmpty ? '-' : book.meanSimilarity.toStringAsFixed(4),
    worst == null ? '-' : '${worst.page}:${worst.similarity.toStringAsFixed(4)}',
    book.pages.isEmpty ? '-' : '${book.percentAboveThreshold.toStringAsFixed(1)}%',
    extras.isEmpty ? '-' : extras.join(' | '),
  ];
}

/// Builds the JSON-serializable report for one book.
Map<String, Object?> _bookToJson(final _BookReport book, final _Options options) {
  final worst = book.worstPage;
  return <String, Object?>{
    'file': book.displayPath,
    'pages': book.pageCount,
    'errors': book.errors,
    'extraction': <String, Object?>{
      'pagesCompared': book.pages.length,
      'meanSimilarity': book.meanSimilarity,
      'worstPage': <String, Object?>{'page': worst?.page, 'similarity': worst?.similarity},
      'percentAboveThreshold': book.percentAboveThreshold,
      'divergentPages': <Object?>[
        for (final page in book.divergentPages)
          <String, Object?>{
            'page': page.page,
            'similarity': page.similarity,
            'reference': page.referenceSnippet,
            'ours': page.ourSnippet,
          },
      ],
      'pageMetrics': <Object?>[
        for (final page in book.pages)
          <String, Object?>{
            'page': page.page,
            'similarity': page.similarity,
            'lengthRatio': page.lengthRatio,
            'referenceChars': page.referenceChars,
            'ourChars': page.ourChars,
          },
      ],
    },
    if (options.runMetadata)
      'metadata': <String, Object?>{
        'available': book.metadata.available,
        'error': book.metadata.error,
        'fields': <Object?>[
          for (final field in book.metadata.fields)
            <String, Object?>{
              'field': field.field,
              'status': field.status,
              'pdfinfo': field.pdfinfoValue,
              'eLivre': field.eLivreValue,
            },
        ],
      },
    if (options.runReflow)
      'reflow': <String, Object?>{
        'available': book.reflow.available,
        'error': book.reflow.error,
        'similarity': book.reflow.similarity,
        'charRatio': book.reflow.charRatio,
        'referenceChars': book.reflow.referenceChars,
        'ourChars': book.reflow.ourChars,
      },
  };
}

/// Writes the full structured report as pretty-printed JSON.
void _writeJsonReport(final List<_BookReport> books, final _Options options, final _Tools tools) {
  final comparedPages = books.fold<int>(0, (final sum, final book) => sum + book.pages.length);
  final report = <String, Object?>{
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'directory': options.directory,
    'options': <String, Object?>{
      'caseInsensitive': options.caseInsensitive,
      'metadata': options.runMetadata,
      'reflow': options.runReflow,
      'divergenceThreshold': _divergenceThreshold,
    },
    'binaries': <String, Object?>{
      'pdftotext': tools.pdftotext,
      'pdfinfo': tools.pdfinfo,
      'ebookConvert': tools.ebookConvert,
    },
    'books': <Object?>[for (final book in books) _bookToJson(book, options)],
    'summary': <String, Object?>{'books': books.length, 'pagesCompared': comparedPages},
  };
  File(
    options.jsonPath!,
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(report)}\n');
  stdout.writeln('json report written to ${options.jsonPath}');
}

/// Entry point.

/// --- image parity (--image) -----------------------------------------
///
/// Decodes every CCITT/JBIG2 image XObject of the corpus with the
/// library and compares the raster against pdf.js v3.11.174 (the
/// oracle in tool/reference/, or a committed golden raster). This is
/// the ruler for the image codecs the same way pdftotext is the ruler
/// for text extraction.

class _ImageMetric {
  const _ImageMetric({
    required this.file,
    required this.object,
    required this.width,
    required this.height,
    required this.differing,
    required this.total,
    this.error,
  });

  final String file;
  final int object;
  final int width;
  final int height;
  final int differing;
  final int total;
  final String? error;

  double get agreement => total == 0 ? 0 : 1 - differing / total;
}

/// Resolves the oracle script relative to this tool.
final String _oracleScript = 'tool${p.separator}reference${p.separator}pdfjs_image.mjs';

final String _goldensDirectory = p.join('test', 'resources', 'pdf', 'reference', 'goldens');

/// Runs the image parity pass over the given options directory.
Future<void> _runImageParity(final _Options options) async {
  final oracleReady =
      File(
        p.join(
          'tool',
          'reference',
          'node_modules',
          'pdfjs-dist',
          'legacy',
          'build',
          'pdf.worker.js',
        ),
      ).existsSync() &&
      File(_oracleScript).existsSync();
  if (!oracleReady && !options.updateGoldens) {
    stdout.writeln(
      'skipped: the pdf.js oracle is not installed '
      '(npm install --prefix tool/reference brings in pdfjs-dist 3.11.174).',
    );
    return;
  }

  final root = Directory(options.directory);
  if (!root.existsSync()) {
    stderr.writeln('error: directory ${options.directory} does not exist.');
    await stderr.flush();
    exit(2);
  }
  final pdfs = _collectPdfs(root);
  if (pdfs.isEmpty) {
    stdout.writeln('no .pdf files found under ${options.directory}.');
    return;
  }

  stdout.writeln(
    'eLivre PDF image parity | ${pdfs.length} file(s) | '
    'oracle pdf.js 3.11.174 ${oracleReady ? 'live' : 'goldens only'}',
  );

  final metrics = <_ImageMetric>[];
  for (final pdf in pdfs) {
    final relative = p.relative(pdf.path);
    PdfDocument document;
    try {
      document = PdfDocument.parse(pdf.readAsBytesSync());
    } on PdfException catch (error) {
      stdout.writeln('scanning $relative... skipped ($error)');
      continue;
    }
    final images = _collectImageXObjects(document);
    if (images.isEmpty) {
      stdout.writeln('scanning $relative... no bitmap images');
      continue;
    }
    for (final entry in images.entries) {
      stdout.write('scanning $relative obj ${entry.key}... ');
      final metric = await _compareImage(
        pdf: pdf,
        document: document,
        object: entry.key,
        stream: entry.value,
        options: options,
        oracleReady: oracleReady,
      );
      if (metric.error != null) {
        stdout.writeln('ERROR (${metric.error})');
      } else {
        stdout.writeln(
          '${metric.width}x${metric.height}, '
          'agreement ${(metric.agreement * 100).toStringAsFixed(4)}%',
        );
      }
      metrics.add(metric);
    }
  }

  _printImageReport(metrics);
}

/// The bitmap-filter image XObjects of every page's resources, keyed
/// by object number.
Map<int, PdfStream> _collectImageXObjects(final PdfDocument document) {
  final images = <int, PdfStream>{};
  for (final page in PdfPageTree.parse(document)) {
    final resources = document.resolve(page.resources);
    if (resources is! PdfDictionary) continue;
    final xobjects = document.resolve(resources['XObject']);
    if (xobjects is! PdfDictionary) continue;
    for (final name in xobjects.entries.keys) {
      final stream = document.resolve(xobjects.entries[name]);
      if (stream is! PdfStream) continue;
      final subtype = document.resolve(stream.dictionary['Subtype']);
      if (subtype is! PdfName || subtype.value != 'Image') continue;
      final filter = document.resolve(stream.dictionary['Filter'] ?? const PdfNull());
      final filterName = filter is PdfName
          ? filter.value
          : filter is PdfArray && filter.items.isNotEmpty
          ? (filter.items.last is PdfName ? (filter.items.last as PdfName).value : '')
          : '';
      if (filterName != 'CCITTFaxDecode' && filterName != 'JBIG2Decode') continue;
      final reference = xobjects.entries[name];
      final number = reference is PdfIndirectRef ? reference.objectNumber : 0;
      if (number != 0) images[number] = stream;
    }
  }
  return images;
}

Future<_ImageMetric> _compareImage({
  required final File pdf,
  required final PdfDocument document,
  required final int object,
  required final PdfStream stream,
  required final _Options options,
  required final bool oracleReady,
}) async {
  int widthOf(PdfStream target) {
    for (final key in const ['Width', 'W']) {
      final value = document.resolve(target.dictionary[key] ?? const PdfNull());
      if (value is PdfNumber) return value.value.toInt();
    }
    return 0;
  }

  int heightOf(PdfStream target) {
    for (final key in const ['Height', 'H']) {
      final value = document.resolve(target.dictionary[key] ?? const PdfNull());
      if (value is PdfNumber) return value.value.toInt();
    }
    return 0;
  }

  final width = widthOf(stream);
  final height = heightOf(stream);
  try {
    final packed = decodePdfStream(stream, document.resolve);
    final bitmap = PdfBitmap.fromPacked(width: width, height: height, packed: packed);
    final ours = bitmap.toGrayBytes();

    final goldenPath = p.join(
      _goldensDirectory,
      '${p.basenameWithoutExtension(pdf.path)}-$object.pgm',
    );
    List<int> reference;
    if (options.updateGoldens || oracleReady) {
      final rasterFile = File(
        '${Directory.systemTemp.path}/'
        'elivre-parity-${DateTime.now().microsecondsSinceEpoch}.pgm',
      );
      final result = await Process.run('node', <String>[
        _oracleScript,
        pdf.path,
        '$object',
        rasterFile.path,
      ]);
      if (result.exitCode != 0) {
        return _ImageMetric(
          file: p.relative(pdf.path),
          object: object,
          width: width,
          height: height,
          differing: 0,
          total: 0,
          error:
              'oracle failed (exit ${result.exitCode}): '
              '${(result.stderr as String).trim()}',
        );
      }
      reference = _pgmRaster(rasterFile.readAsBytesSync());
      if (options.updateGoldens) {
        final goldenDir = Directory(_goldensDirectory);
        if (!goldenDir.existsSync()) goldenDir.createSync(recursive: true);
        File(goldenPath).writeAsBytesSync(reference);
      }
    } else {
      final golden = File(goldenPath);
      if (!golden.existsSync()) {
        return _ImageMetric(
          file: p.relative(pdf.path),
          object: object,
          width: width,
          height: height,
          differing: 0,
          total: 0,
          error: 'no golden raster at $goldenPath',
        );
      }
      reference = _pgmRaster(golden.readAsBytesSync());
    }

    if (reference.length != ours.length) {
      return _ImageMetric(
        file: p.relative(pdf.path),
        object: object,
        width: width,
        height: height,
        differing: 0,
        total: 0,
        error:
            'raster size mismatch: oracle ${reference.length} px, '
            'library ${ours.length} px',
      );
    }
    var differing = 0;
    for (var i = 0; i < reference.length; i++) {
      if (reference[i] != ours[i]) differing++;
    }
    return _ImageMetric(
      file: p.relative(pdf.path),
      object: object,
      width: width,
      height: height,
      differing: differing,
      total: reference.length,
    );
  } on PdfException catch (error) {
    return _ImageMetric(
      file: p.relative(pdf.path),
      object: object,
      width: width,
      height: height,
      differing: 0,
      total: 0,
      error: '$error',
    );
  }
}

/// Parses the gray raster out of a P5 PGM written by the oracle.
List<int> _pgmRaster(final List<int> pgm) {
  final text = String.fromCharCodes(pgm);
  final headerEnd = text.indexOf('255\n');
  if (!text.startsWith('P5') || headerEnd < 0) {
    throw const PdfException('oracle did not produce a P5 PGM raster.');
  }
  return pgm.sublist(headerEnd + 4);
}

void _printImageReport(final List<_ImageMetric> metrics) {
  final decodable = metrics.where((m) => m.error == null).toList();
  stdout.writeln();
  stdout.writeln('  file                        obj    dims        differing  agreement');
  stdout.writeln('  --------------------------  -----  ----------  ---------  ---------');
  for (final metric in metrics) {
    if (metric.error != null) {
      stdout.writeln('  ${metric.file}  obj ${metric.object}: ERROR ${metric.error}');
      continue;
    }
    final file = metric.file.padRight(25);
    final obj = metric.object.toString().padLeft(3);
    final dims = '${metric.width}x${metric.height}'.padLeft(10);
    final differing = metric.differing.toString().padLeft(9);
    final agreement = (metric.agreement * 100).toStringAsFixed(4).padLeft(8);
    stdout.writeln('  $file  $obj  $dims  $differing  $agreement%');
  }
  if (decodable.isNotEmpty) {
    final total = decodable.fold<int>(0, (sum, m) => sum + m.total);
    final differing = decodable.fold<int>(0, (sum, m) => sum + m.differing);
    final perfect = decodable.where((m) => m.differing == 0).length;
    stdout.writeln();
    stdout.writeln(
      'image parity: ${decodable.length} image(s), $total px compared, '
      '$differing differing | mean agreement '
      '${(100 * (1 - differing / total)).toStringAsFixed(4)}% | '
      '$perfect/${decodable.length} exact',
    );
  }
}

Future<void> main(final List<String> arguments) async {
  final parsed = _parseOptions(arguments);
  if (parsed.options == null) {
    if (parsed.exitCode != 0) {
      await stderr.flush();
      exit(parsed.exitCode);
    }
    return;
  }
  final options = parsed.options!;

  if (options.runImage) {
    await _runImageParity(options);
    return;
  }

  if (!Directory(_calibreBundle).existsSync()) {
    stdout.writeln(
      'skipped: Calibre is not installed at $_calibreBundle; '
      'the PDF parity harness needs its pdftotext, pdfinfo and ebook-convert.',
    );
    return;
  }
  final tools = _Tools.discover();

  final root = Directory(options.directory);
  if (!root.existsSync()) {
    stderr.writeln('error: directory ${options.directory} does not exist.');
    await stderr.flush();
    exit(2);
  }
  final pdfs = _collectPdfs(root);
  if (pdfs.isEmpty) {
    stdout.writeln('no .pdf files found under ${options.directory}.');
    return;
  }

  stdout.writeln(
    'eLivre PDF parity harness | ${pdfs.length} file(s) | '
    'pdftotext ${tools.pdftotext != null ? 'ok' : 'MISSING'} | '
    'pdfinfo ${tools.pdfinfo != null ? 'ok' : 'MISSING'} | '
    'ebook-convert ${tools.ebookConvert != null ? 'ok' : 'MISSING'}',
  );
  stdout.writeln(
    'normalization: ligature/quote/dash folding + whitespace collapse'
    '${options.caseInsensitive ? ' + casefold' : ''}',
  );

  final books = <_BookReport>[];
  for (final pdf in pdfs) {
    stdout.write('scanning ${p.relative(pdf.path)}... ');
    final report = await _evaluateBook(pdf: pdf, options: options, tools: tools);
    books.add(report);
    stdout.writeln(
      report.pages.isEmpty ? 'no comparable pages' : '${report.pages.length} page(s) compared',
    );
  }

  _printConsoleReport(books, options);
  if (options.jsonPath != null) {
    _writeJsonReport(books, options, tools);
  }
}
