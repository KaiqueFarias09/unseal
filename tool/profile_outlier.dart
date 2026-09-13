/// Staged performance profile of one pathological PDF ("the outlier").
///
/// Times every stage of `parsePdfBook` separately — file read,
/// `PdfDocument.parse` (cross-reference/trailer resolution), page tree,
/// metadata, outline, text extraction (per page), content-stream
/// decode replay, reflow — plus a whole-document object/stream census
/// (counts by object type, stream filter, raw/decoded sizes, decode
/// time) and one end-to-end `parsePdfBook` wall-clock.
///
/// The subject file is a private-library book: it is identified by the
/// anonymized sweep id (a truncated SHA-256 of the library-relative
/// path recorded in the quarantine checkpoint). The tool resolves the
/// local path ONLY at run time — by walking the library root and
/// re-hashing the relative paths, or from an explicit `--path`/env
/// override — and never prints or writes the path anywhere: reports
/// carry the sweep id and byte size only.
///
/// Usage:
///
/// ```
/// dart run tool/profile_outlier.dart
///     [--checkpoint=<calibre-sweep-checkpoint.json>]
///     [--id=<12-hex sweep id>]
///     [--library=<calibre library root>]
///     [--path=<explicit pdf> | ELIVRE_OUTLIER_PDF=<pdf>]
///     [--rounds=<n>] [--pages=<n>] [--census] [--json=<out.json>]
/// ```
///
/// `--rounds` repeats the whole stage sequence, reporting every round
/// plus the median per stage. `--pages` limits text extraction to the
/// first N pages (0 = all). `--census` enables the object/stream walk
/// (it forces a full decode of every stream and can be slow).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_page.dart';
import 'package:e_livre/src/features/pdf/entities/pdf_page_text.dart';
import 'package:e_livre/src/features/pdf/header/pdf_document.dart';
import 'package:e_livre/src/features/pdf/header/pdf_object.dart';
import 'package:e_livre/src/features/pdf/parse_pdf_book.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_content_stream.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_metadata.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_outline.dart';
import 'package:e_livre/src/features/pdf/reader/pdf_page_tree.dart';
import 'package:e_livre/src/features/pdf/reflow/pdf_reflow.dart';

/// Default sweep id of the outlier PDF under investigation.
const _defaultTargetId = '605cee501f4e';

Future<void> main(final List<String> arguments) async {
  final options = _parseOptions(arguments);
  final (path, sizeBytes) = _resolveSubject(options);
  if (path == null) {
    exitCode = 2;

    return;
  }
  // The resolved path never crosses this function boundary again:
  // blank it out right after the bytes are read.
  final pathForRead = path;
  final bytes = _stage('read_file', () => File(pathForRead).readAsBytesSync());
  if (options.drillPages.isNotEmpty) {
    _drill(bytes, options.drillPages);

    return;
  }

  final profile = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'outlier-stage-profile',
    'target': {'sweepId': options.targetId, 'sizeBytes': sizeBytes},
    'rounds': options.rounds,
    'roundsData': <Object?>[],
  };

  final roundSummaries = <Map<String, double>>[];
  for (var round = 0; round < options.rounds; round++) {
    final stageMillis = <String, double>{};
    final detail = <String, Object?>{};

    final document = _timed(stageMillis, 'document_parse', () => PdfDocument.parse(bytes));
    final pages = _timed(stageMillis, 'page_tree', () => PdfPageTree.parse(document));
    _timed(stageMillis, 'metadata', () => PdfMetadataReader.read(document));
    _timed(stageMillis, 'outline', () => PdfOutlineReader.read(document, pages));

    final extractLimit = options.pageLimit <= 0
        ? pages.length
        : math.min(options.pageLimit, pages.length);
    final pageMillis = <double>[];
    final watch = Stopwatch();
    final extracted = _timed(stageMillis, 'text_extraction', () {
      final extractor = PdfTextExtractor(document);
      final pageTexts = <PdfPageText>[];
      for (var i = 0; i < extractLimit; i++) {
        watch
          ..reset()
          ..start();
        pageTexts.add(extractor.extract(pages[i]));
        watch.stop();
        pageMillis.add(watch.elapsedMicroseconds / 1000);
        stdout.writeln('  page ${i + 1}/$extractLimit: ${pageMillis.last.toStringAsFixed(1)}ms');
      }

      return pageTexts;
    });
    detail['pagesParsed'] = extractLimit;
    if (pageMillis.isNotEmpty) {
      detail['pageMillisMax'] = _round3(pageMillis.reduce(math.max));
      detail['pageMillisMedian'] = _round3(_median(pageMillis));
      detail['pagesOver100Millis'] = pageMillis.where((final ms) => ms > 100).length;
      detail['topPagesByMillis'] = _topPages(pageMillis);
    }

    _timed(stageMillis, 'content_decode_replay', () {
      var decodedBytes = 0;
      for (var i = 0; i < extractLimit; i++) {
        for (final stream in _contentStreamsOf(document, pages[i])) {
          decodedBytes += document.decodeStream(stream).length;
        }
      }
      detail['contentDecodeBytes'] = decodedBytes;

      return decodedBytes;
    });
    _timed(stageMillis, 'reflow', () => PdfReflow.apply(extracted, pages.sublist(0, extractLimit)));

    if (options.census) {
      final census = _timed(
        stageMillis,
        'object_census',
        () => _census(document, document.trailer),
      );
      detail['census'] = census;
    }

    _timed(stageMillis, 'parse_pdf_book_total', () {
      parsePdfBook(bytes);

      return null;
    });
    detail['stageMillis'] = stageMillis.map(
      (final key, final value) => MapEntry(key, _round3(value)),
    );
    (profile['roundsData'] as List<Object?>).add(detail);
    roundSummaries.add(stageMillis);
    stdout.writeln(
      'round ${round + 1}/${options.rounds}: '
      '${stageMillis.entries.map((final e) => '${e.key}=${_round3(e.value)}ms').join(' ')}',
    );
  }

  profile['medians'] = {
    for (final entry in _medianStages(roundSummaries).entries) entry.key: _round3(entry.value),
  };
  profile['gitHead'] = _gitHead();

  final encoded = const JsonEncoder.withIndent('  ').convert(profile);
  if (options.out != null) {
    File(options.out!).writeAsStringSync('$encoded\n');
    stdout.writeln('report written to ${options.out}');
  } else {
    stdout.writeln(encoded);
  }
}

// --- subject resolution -----------------------------------------------------

/// Resolves the subject file path from the sweep id. The path lives
/// only inside this function's return value and is consumed (blanked)
/// immediately after the bytes are read in [main].
(String?, int?) _resolveSubject(final _Options options) {
  if (options.explicitPath != null) {
    final file = File(options.explicitPath!);
    if (!file.existsSync()) {
      stderr.writeln('profile_outlier: --path does not exist.');
      exitCode = 2;

      return (null, null);
    }

    return (options.explicitPath, file.lengthSync());
  }

  final checkpointFile = File(options.checkpoint);
  if (!checkpointFile.existsSync()) {
    stderr.writeln('profile_outlier: checkpoint not found at ${options.checkpoint}.');
    exitCode = 2;

    return (null, null);
  }
  final checkpoint = jsonDecode(checkpointFile.readAsStringSync()) as Map<String, Object?>;
  final completed = checkpoint['completed'] as Map<String, Object?>?;
  final entry = completed?[options.targetId] as Map<String, Object?>?;
  if (entry == null) {
    stderr.writeln('profile_outlier: sweep id ${options.targetId} is not in the checkpoint.');
    exitCode = 2;

    return (null, null);
  }
  final expectedSize = (entry['sizeBytes'] as num?)?.toInt();
  final expectedExtension = entry['ext'] as String? ?? '';

  final root = _libraryRoot(options.library);
  if (root == null) {
    stderr.writeln(
      'profile_outlier: no library root. Pass --library or set '
      'ELIVRE_CALIBRE_LIBRARY (the id is the truncated sha256 of the '
      'library-relative path, so the root is required to re-derive it).',
    );
    exitCode = 2;

    return (null, null);
  }

  final prefix = Directory(root).path.endsWith('/')
      ? Directory(root).path
      : '${Directory(root).path}/';
  final hit = _walkForId(
    Directory(root),
    options.targetId,
    expectedSize,
    expectedExtension,
    prefix,
  );
  if (hit == null) {
    stderr.writeln(
      'profile_outlier: no file under the library root hashes to ${options.targetId}.',
    );
    exitCode = 2;

    return (null, null);
  }

  return (hit, expectedSize);
}

String? _libraryRoot(final String? explicit) {
  if (explicit != null && explicit.isNotEmpty) return explicit;
  final fromEnvironment = Platform.environment['ELIVRE_CALIBRE_LIBRARY'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) return fromEnvironment;

  // The operator's standard library location (default Calibre folder
  // names under the home directory) — generic folder names, not a
  // private path.
  final home = Platform.environment['HOME'];
  if (home == null) return null;
  for (final candidate in <String>[
    '$home/Calibre Library',
    '$home/CalibreLibrary',
    '$home/Documents/Calibre Library',
  ]) {
    if (Directory(candidate).existsSync()) return candidate;
  }

  return null;
}

/// Walks [dir] returning the first file whose truncated library-
/// relative sha256 matches [targetId] (and size [expectedSize] when
/// known). Paths are hashed, never retained.
String? _walkForId(
  final Directory dir,
  final String targetId,
  final int? expectedSize,
  final String extension,
  final String prefix,
) {
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is Directory) {
      final hit = _walkForId(entity, targetId, expectedSize, extension, prefix);
      if (hit != null) return hit;
    } else if (entity is File) {
      final relative = entity.path.startsWith(prefix)
          ? entity.path.substring(prefix.length)
          : entity.path;
      final digest = sha256.convert(utf8.encode(relative)).toString().substring(0, 12);
      if (digest != targetId) continue;
      if (expectedSize != null && entity.lengthSync() != expectedSize) continue;

      return entity.path;
    }
  }

  return null;
}

// --- staged helpers ---------------------------------------------------------

T _stage<T>(final String name, final T Function() body) {
  final watch = Stopwatch()..start();
  final result = body();
  watch.stop();
  stdout.writeln('$name: ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)}ms');

  return result;
}

T _timed<T>(final Map<String, double> sink, final String name, final T Function() body) {
  final watch = Stopwatch()..start();
  final result = body();
  watch.stop();
  sink[name] = watch.elapsedMicroseconds / 1000;

  return result;
}

/// The content streams of [page], resolved the same way the extractor
/// resolves them: the page dictionary's `/Contents`, single stream or
/// array.
List<PdfStream> _contentStreamsOf(final PdfDocument document, final PdfPage page) {
  final dictionary = document.object(page.objectNumber);
  if (dictionary is! PdfDictionary) return const <PdfStream>[];
  final contents = document.resolve(dictionary['Contents']);
  if (contents is PdfStream) return <PdfStream>[contents];
  if (contents is PdfArray) {
    return <PdfStream>[
      for (final item in contents.items)
        if (document.resolve(item) is PdfStream) document.resolve(item) as PdfStream,
    ];
  }

  return const <PdfStream>[];
}

/// The object/stream census: every object number up to the trailer's
/// /Size resolved once, classified by type; every stream classified
/// by filter with raw and decoded sizes and per-filter decode time.
Map<String, Object?> _census(final PdfDocument document, final PdfDictionary trailer) {
  final size = (trailer['Size'] as PdfNumber?)?.intValue ?? 0;
  final byType = <String, int>{};
  final streamsByFilter = <String, int>{};
  final rawBytesByFilter = <String, int>{};
  final decodedBytesByFilter = <String, int>{};
  final decodeMillisByFilter = <String, double>{};
  var objectMisses = 0;
  var decodeFailures = 0;

  for (var number = 1; number < size; number++) {
    final object = document.object(number);
    if (object == null) {
      objectMisses++;

      continue;
    }
    final key = object.runtimeType.toString();
    byType[key] = (byType[key] ?? 0) + 1;
    if (object is! PdfStream) continue;

    final filters = _filterNames(document, object);
    final filterKey = filters.isEmpty ? '(none)' : filters.join('+');
    streamsByFilter[filterKey] = (streamsByFilter[filterKey] ?? 0) + 1;
    rawBytesByFilter[filterKey] = (rawBytesByFilter[filterKey] ?? 0) + object.bytes.length;
    final watch = Stopwatch()..start();
    try {
      final decoded = document.decodeStream(object);
      decodedBytesByFilter[filterKey] = (decodedBytesByFilter[filterKey] ?? 0) + decoded.length;
    } on Exception {
      decodeFailures++;
    }
    watch.stop();
    decodeMillisByFilter[filterKey] =
        (decodeMillisByFilter[filterKey] ?? 0) + watch.elapsedMicroseconds / 1000;
  }

  return <String, Object?>{
    'trailerSize': size,
    'objectsByType': byType,
    'objectMisses': objectMisses,
    'streamsByFilter': streamsByFilter,
    'rawBytesByFilter': rawBytesByFilter,
    'decodedBytesByFilter': decodedBytesByFilter,
    'decodeMillisByFilter': decodeMillisByFilter.map((final k, final v) => MapEntry(k, _round3(v))),
    'decodeFailures': decodeFailures,
  };
}

List<String> _filterNames(final PdfDocument document, final PdfStream stream) {
  final filter = document.resolve(stream.dictionary['Filter'] ?? const PdfNull());
  if (filter is PdfName) return <String>[filter.value];
  if (filter is PdfArray) {
    return <String>[
      for (final item in filter.items)
        if (item is PdfName) item.value,
    ];
  }

  return const <String>[];
}

// --- options ----------------------------------------------------------------

final class _Options {
  String checkpoint =
      '/Volumes/SSD/Projects/ai-worktrees/artifacts/quarantine-readonly/calibre-sweep-checkpoint.json';
  String targetId = _defaultTargetId;
  String? library;
  String? explicitPath;
  int rounds = 1;
  int pageLimit = 0;
  bool census = false;
  String? out;
  List<int> drillPages = const <int>[];
}

_Options _parseOptions(final List<String> arguments) {
  final options = _Options();
  for (final argument in arguments) {
    final value = argument.contains('=') ? argument.split('=').skip(1).join('=') : null;
    if (argument.startsWith('--checkpoint=') && value != null) {
      options.checkpoint = value;
    } else if (argument.startsWith('--id=') && value != null) {
      options.targetId = value;
    } else if (argument.startsWith('--library=') && value != null) {
      options.library = value;
    } else if (argument.startsWith('--path=') && value != null) {
      options.explicitPath = value;
    } else if (argument.startsWith('--rounds=') && value != null) {
      options.rounds = math.max(1, int.tryParse(value) ?? 1);
    } else if (argument.startsWith('--pages=') && value != null) {
      options.pageLimit = int.tryParse(value) ?? 0;
    } else if (argument == '--census') {
      options.census = true;
    } else if (argument.startsWith('--drill=') && value != null) {
      options.drillPages = <int>[
        for (final part in value.split(','))
          if (int.tryParse(part.trim()) != null) int.parse(part.trim()),
      ];
    } else if (argument.startsWith('--json=') && value != null) {
      options.out = value;
    } else if (argument.startsWith('--out=') && value != null) {
      options.out = value;
    }
  }
  options.explicitPath ??= Platform.environment['ELIVRE_OUTLIER_PDF'];

  return options;
}

// --- drill mode -------------------------------------------------------------

/// Extracts the given 1-based pages in sequence, timing every call —
/// repeated indices reveal per-first-extract state (font/CMap builds)
/// versus per-call work.
void _drill(final Uint8List bytes, final List<int> pageNumbers) {
  final document = PdfDocument.parse(bytes);
  final pages = PdfPageTree.parse(document);
  final extractor = PdfTextExtractor(document);
  for (final pageNumber in pageNumbers) {
    if (pageNumber < 1 || pageNumber > pages.length) continue;
    final watch = Stopwatch()..start();
    final pageText = extractor.extract(pages[pageNumber - 1]);
    watch.stop();
    stdout.writeln(
      'drill page $pageNumber: ${(watch.elapsedMicroseconds / 1000).toStringAsFixed(1)}ms '
      'lines=${pageText.lines.length}',
    );
  }
}

// --- small stats ------------------------------------------------------------

double _median(final List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;

  return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

Map<String, double> _medianStages(final List<Map<String, double>> rounds) {
  final names = <String>{for (final round in rounds) ...round.keys};
  final medians = <String, double>{};
  for (final name in names) {
    medians[name] = _median(<double>[
      for (final round in rounds)
        if (round.containsKey(name)) round[name]!,
    ]);
  }

  return medians;
}

List<Map<String, Object?>> _topPages(final List<double> millis) {
  final indexed = <(int, double)>[for (var i = 0; i < millis.length; i++) (i, millis[i])]
    ..sort((final a, final b) => b.$2.compareTo(a.$2));

  return <Map<String, Object?>>[
    for (final (index, value) in indexed.take(10)) {'page': index, 'millis': _round3(value)},
  ];
}

double _round3(final double value) => (value * 1000).roundToDouble() / 1000;

String _gitHead() {
  try {
    return Process.runSync('git', <String>[
      'rev-parse',
      '--short',
      'HEAD',
    ]).stdout.toString().trim();
  } on Exception {
    return 'unknown';
  }
}
