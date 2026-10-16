import 'dart:convert' as convert;

import '../../../foundation/entities/entities.dart';
import '../../../foundation/text/canonical_document_text.dart';
import '../book_search.dart' show searchSnippet;
import 'index_ranking.dart';
import 'indexed_query_mode.dart';
import 'indexed_search_results.dart';
import 'search_index_exceptions.dart';
import 'search_index_identity.dart';
import 'search_text_tokenizer.dart';
import 'searchable_map.dart';

/// Wire schema version of the serialized index.
const int _schemaVersion = 1;

/// Incremental, per-publication inverted index over a book's canonical
/// document text — the ported core of MiniSearch's index
/// ([revision `3d239d1c`](https://github.com/lucaong/minisearch/tree/3d239d1c3ae7aef1bf5d8945dd7b5f0709f646f5),
/// MIT) with Tantivy-style positioned postings
/// ([revision `e1acb3e0`](https://github.com/quickwit-oss/tantivy/tree/e1acb3e0112f2b4819946aa4ea5742bf429853d8),
/// MIT — see `THIRD_PARTY_NOTICES.md`).
///
/// The index maps normalized terms to per-section occurrence ranges in
/// the original UTF-16 text (the same offset space `Book.search` and
/// CFI address), scores sections with BM25+, and orders hits by the
/// shared deterministic tiebreak: score descending, occurrence
/// ascending, start ascending, end ascending.
///
/// Construction is incremental and cancellable: sections enter in
/// finite batches, queries run at any moment, and the coverage
/// counters (C05) always tell indexed, pending and failed sections
/// apart — an empty result over a partial index never proves absence
/// in the book. Serialized payloads are versioned; import validates
/// schema, profile, identity, order revision and per-section text
/// revisions before trusting a single posting.
///
/// PDF persistence is withheld until the P1 position-mapping
/// acceptance: indexes over PDF text build and query in memory, but
/// [serialize] refuses while `persistable` is false.
final class BookSearchIndex {
  BookSearchIndex._({
    required this.identity,
    required SearchIndexLimits limits,
    required this.persistable,
  }) : _limits = limits;

  /// Creates an empty index for incremental feeding: declare the
  /// eligible sections with [beginEligible], then move each one with
  /// [addSection] or [failSection] — the pattern the session engine
  /// drives across worker ops, one bounded batch per call.
  factory BookSearchIndex.empty({
    final SearchIndexIdentity? identity,
    final SearchIndexLimits limits = const SearchIndexLimits(),
    final bool persistable = true,
  }) {
    return BookSearchIndex._(
      identity: identity ?? const SearchIndexIdentity(),
      limits: limits,
      persistable: persistable,
    );
  }

  /// Builds an index over [book]'s HTML reading order in bounded
  /// batches, yielding between batches so callers (and the isolate or
  /// worker event loop) stay responsive.
  ///
  /// [identity] binds the index to a publication revision when known.
  /// [cancellation] stops the build at the next batch boundary with
  /// `SearchIndexCancelledException`; finished work stays visible in
  /// the coverage counters of the thrown-from index — no complete
  /// index is produced. [onProgress] fires after every batch.
  /// [persistable] must stay false for PDF text until the P1
  /// acceptance (the default derives it from [Book.format]).
  static Future<BookSearchIndex> build(
    final Book book, {
    final SearchIndexIdentity? identity,
    final SearchIndexLimits limits = const SearchIndexLimits(),
    final SearchIndexCancellationToken? cancellation,
    final void Function(SearchIndexCoverage coverage)? onProgress,
    final int sectionsPerBatch = 4,
    final bool? persistable,
  }) async {
    final index = BookSearchIndex._(
      identity: identity ?? const SearchIndexIdentity(),
      limits: limits,
      persistable: persistable ?? book.format != BookFormat.pdf,
    );
    final order = book.readingOrder;
    final eligible = index.beginEligible(order);
    final htmlByPath = <String, TextFile>{for (final file in book.files.html) file.path: file};
    var position = 0;
    while (position < eligible.length) {
      if (cancellation?.isCancelled ?? false) {
        index._markCancelled();

        throw const SearchIndexCancelledException(
          'The search-index build was cancelled at a batch boundary.',
        );
      }
      var batch = sectionsPerBatch < 1 ? 1 : sectionsPerBatch;
      while (batch > 0 && position < eligible.length) {
        final (sectionIndex, path) = eligible[position];
        position++;
        final file = htmlByPath[path];
        if (file == null) {
          index.failSection(sectionIndex: sectionIndex, path: path);

          continue;
        }
        index.addSection(sectionIndex: sectionIndex, path: path, text: documentTextOf(file));
        batch--;
      }
      onProgress?.call(index.coverage);
      // One event-loop turn per batch: bounded CPU slices, observable
      // cancellation, and a warm cache for the next batch.
      await Future<void>.delayed(Duration.zero);
    }

    return index;
  }

  /// The publication identity the index binds to (unverified unless
  /// the host supplied evidence).
  final SearchIndexIdentity identity;
  final SearchIndexLimits _limits;

  /// Whether [serialize] may run (false over PDF text until P1).
  final bool persistable;

  final SearchIndexTokenizer _tokenizer = SearchIndexTokenizer();

  /// Term → postings, the radix tree keyed for prefix/fuzzy walks.
  final SearchableMap<_TermPostings> _terms = SearchableMap<_TermPostings>();

  /// Indexed sections by internal id (insertion order = build order).
  final List<_IndexedSection> _sections = <_IndexedSection>[];

  /// Eligible sections not yet processed: `(sectionIndex, path)`.
  final List<(int, String)> _pending = <(int, String)>[];

  /// Eligible sections whose document text failed to load.
  final Map<int, String> _failed = <int, String>{};

  int _totalTokens = 0;
  int _totalOccurrences = 0;
  int _distinctTerms = 0;
  bool _cancelled = false;
  String? _limitHit;
  bool _disposed = false;
  String? _readingOrderRevision;
  bool _complete = false;

  /// Section texts the snippets cut from — references to the same
  /// immutable strings the book or session cache already holds, not
  /// copies. The index therefore keeps its sections' text reachable
  /// until [dispose]; documented alongside the session memory policy.
  final Map<int, String> _sectionTextCache = <int, String>{};

  /// Whether every eligible section is indexed.
  bool get isComplete => _complete;

  /// The tokenizer id this index was built under.
  static String get tokenizerId => SearchIndexTokenizer.tokenizerId;

  /// The normalization id this index was built under.
  static String get normalizationId => SearchIndexTokenizer.normalizationId;

  /// The canonical text space the index addresses.
  static String get textProfileId => SearchIndexTokenizer.textProfileId;

  /// Current coverage over the eligible sections.
  SearchIndexCoverage get coverage => SearchIndexCoverage(
    eligibleSections: _sections.length + _pending.length + _failed.length,
    indexedSections: _sections.length,
    pendingSections: _pending.length,
    failedSections: _failed.length,
    totalTokens: _totalTokens,
    totalOccurrences: _totalOccurrences,
    termCount: _distinctTerms,
    isComplete: _complete,
    wasCancelled: _cancelled,
    limitHit: _limitHit,
  );

  /// Declares the eligible sections from a full reading order and
  /// records the order revision. Returns the pending list the caller
  /// walks with [addSection] / [failSection].
  List<(int, String)> beginEligible(final List<ReadingOrderItem> order) {
    _ensureOpen();
    if (_readingOrderRevision != null) {
      throw const SearchIndexInvalidArgumentException(
        'The index already began over a reading order.',
      );
    }
    if (order.length > _limits.effectiveMaxSections) {
      throw SearchIndexLimitExceededException(
        'The reading order holds ${order.length} sections, above the '
        '${_limits.effectiveMaxSections} limit.',
      );
    }
    _readingOrderRevision = readingOrderRevisionOf(order);
    for (var sectionIndex = 0; sectionIndex < order.length; sectionIndex++) {
      final section = order[sectionIndex];
      if (!section.isHtml) continue;
      _pending.add((sectionIndex, section.name));
    }
    _refreshComplete();

    return List<(int, String)>.of(_pending);
  }

  /// Indexes one section's canonical text. The section must have been
  /// declared pending by [beginEligible].
  void addSection({
    required final int sectionIndex,
    required final String path,
    required final String text,
  }) {
    _ensureOpen();
    final position = _pendingPosition(sectionIndex, path);
    final tokens = _tokenizer.tokenize(text);
    final internalId = _sections.length;
    var sectionOccurrences = 0;
    for (final token in tokens) {
      if (token.term.isEmpty) continue;
      if (token.term.length > _limits.effectiveMaxTermLength) {
        // Counted (it occupies the field length) but not posted: an
        // oversized run is garbage, not a search term.
        continue;
      }
      var postings = _terms.get(token.term);
      if (postings == null) {
        if (_distinctTerms >= _limits.effectiveMaxTerms) {
          _limitHit = 'maxTerms';
          throw SearchIndexLimitExceededException(
            'The index crossed the ${_limits.effectiveMaxTerms}-term limit '
            'while indexing $path.',
          );
        }
        postings = _TermPostings();
        _terms.set(token.term, postings);
        _distinctTerms++;
      }
      final ranges = postings.bySection.putIfAbsent(internalId, () => <int>[]);
      ranges
        ..add(token.start)
        ..add(token.end);
      sectionOccurrences++;
    }
    _totalOccurrences += sectionOccurrences;
    if (_totalOccurrences > _limits.effectiveMaxOccurrences) {
      _limitHit = 'maxOccurrences';
      throw SearchIndexLimitExceededException(
        'The index crossed the ${_limits.effectiveMaxOccurrences}-occurrence '
        'limit while indexing $path.',
      );
    }
    _totalTokens += tokens.length;
    _sections.add(
      _IndexedSection(
        sectionIndex: sectionIndex,
        path: path,
        tokenCount: tokens.length,
        textLength: text.length,
        textRevision: textRevisionOf(text),
      ),
    );
    _sectionTextCache[internalId] = text;
    _pending.removeAt(position);
    _refreshComplete();
  }

  /// Records a section whose document text could not be loaded.
  void failSection({required final int sectionIndex, required final String path}) {
    _ensureOpen();
    _pending.removeAt(_pendingPosition(sectionIndex, path));
    _failed[sectionIndex] = path;
    _refreshComplete();
  }

  int _pendingPosition(final int sectionIndex, final String path) {
    for (var i = 0; i < _pending.length; i++) {
      final (pendingIndex, pendingPath) = _pending[i];
      if (pendingIndex == sectionIndex && pendingPath == path) return i;
    }

    throw SearchIndexInvalidArgumentException(
      'Section $sectionIndex ($path) was not declared pending; '
      'call beginEligible with the reading order first.',
    );
  }

  void _refreshComplete() {
    _complete = _pending.isEmpty && _failed.isEmpty && !_cancelled;
  }

  void _markCancelled() {
    _cancelled = true;
    _complete = false;
  }

  /// Queries the index. Runs at any construction stage; the result
  /// carries the coverage that produced it. See [IndexedQueryMode] for
  /// the token semantics.
  IndexedSearchResults query(
    final String query, {
    final IndexedQueryMode mode = IndexedQueryMode.exact,
    final int? maxMatches,
    final int? maxExpansions,
    final int contextChars = 48,
  }) {
    _ensureOpen();
    final matchCap = maxMatches != null && maxMatches >= 1
        ? maxMatches
        : _limits.effectiveMaxMatches;
    final expansionCap = maxExpansions != null && maxExpansions >= 1
        ? maxExpansions
        : _limits.effectiveMaxExpansions;
    if (contextChars < 0) {
      throw const SearchIndexInvalidArgumentException('contextChars must not be negative.');
    }

    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return IndexedSearchResults(
        query: query,
        mode: mode,
        hits: const <IndexedSearchHit>[],
        isTruncated: false,
        coverage: coverage,
      );
    }
    final tokens = _tokenizer
        .tokenize(trimmed)
        .where((final token) => token.term.isNotEmpty)
        .toList(growable: false);
    if (tokens.length > _limits.effectiveMaxQueryTokens) {
      throw SearchIndexInvalidArgumentException(
        'The query carries ${tokens.length} tokens, above the '
        '${_limits.effectiveMaxQueryTokens} limit.',
      );
    }
    if (_sections.isEmpty || tokens.isEmpty) {
      return IndexedSearchResults(
        query: query,
        mode: mode,
        hits: const <IndexedSearchHit>[],
        isTruncated: false,
        coverage: coverage,
      );
    }

    final totalSections = _sections.length;
    final averageLength = _totalTokens / totalSections;
    // Per token: the expansion list `(term, weight)` and whether the
    // token matched at all. All tokens must match (AND).
    final tokenExpansions = <List<(String, double)>>[];
    for (var tokenIndex = 0; tokenIndex < tokens.length; tokenIndex++) {
      final token = tokens[tokenIndex].term;
      final isLast = tokenIndex == tokens.length - 1;
      tokenExpansions.add(
        _expandToken(
          token,
          mode: isLast ? mode : IndexedQueryMode.exact,
          expansionCap: expansionCap,
        ),
      );
    }

    // Section scores: AND across tokens, sum of weighted BM25+ per
    // expansion, accumulated in a fixed order (query tokens, then trie
    // traversal) so float results are deterministic.
    final scores = <int, double>{};
    for (var tokenIndex = 0; tokenIndex < tokenExpansions.length; tokenIndex++) {
      final expansions = tokenExpansions[tokenIndex];
      final tokenMatches = <int, double>{};
      for (final (term, weight) in expansions) {
        final postings = _terms.get(term);
        if (postings == null) continue;
        final df = postings.bySection.length;
        for (final entry in postings.bySection.entries) {
          final section = _sections[entry.key];
          final contribution =
              weight *
              bm25PlusScore(
                termFrequency: entry.value.length ~/ 2,
                matchingSections: df,
                totalSections: totalSections,
                sectionLength: section.tokenCount,
                averageLength: averageLength,
              );
          tokenMatches[entry.key] = (tokenMatches[entry.key] ?? 0) + contribution;
        }
      }
      if (tokenMatches.isEmpty) {
        return IndexedSearchResults(
          query: query,
          mode: mode,
          hits: const <IndexedSearchHit>[],
          isTruncated: false,
          coverage: coverage,
        );
      }
      if (tokenIndex == 0) {
        scores.addAll(tokenMatches);
      } else {
        scores.removeWhere((final sectionId, _) => !tokenMatches.containsKey(sectionId));
        for (final entry in tokenMatches.entries) {
          if (scores.containsKey(entry.key)) {
            scores[entry.key] = scores[entry.key]! + entry.value;
          }
        }
      }
    }

    // Hits anchor on the first token's expansions, so every hit cuts a
    // real occurrence of the query text. All anchor occurrences
    // collect (bounded by the index's own occurrence cap), sort under
    // the deterministic order, and only then cut to the match cap —
    // truncation yields the top of the ranking, never the first
    // collected.
    final hits = <IndexedSearchHit>[];
    for (final (term, _) in tokenExpansions.first) {
      final postings = _terms.get(term);
      if (postings == null) continue;
      for (final sectionId in postings.bySection.keys) {
        if (!scores.containsKey(sectionId)) continue;
        final ranges = postings.bySection[sectionId]!;
        final section = _sections[sectionId];
        final text = _sectionTextCache[sectionId];
        for (var i = 0; i + 1 < ranges.length; i += 2) {
          hits.add(
            IndexedSearchHit(
              sectionIndex: section.sectionIndex,
              sectionName: section.path,
              start: ranges[i],
              end: ranges[i + 1],
              snippet: text == null
                  ? ''
                  : searchSnippet(text, ranges[i], ranges[i + 1], contextChars),
              score: scores[sectionId]!,
            ),
          );
        }
      }
    }
    hits.sort(_hitOrder);
    var isTruncated = false;
    if (hits.length > matchCap) {
      hits.removeRange(matchCap, hits.length);
      isTruncated = true;
    }

    return IndexedSearchResults(
      query: query,
      mode: mode,
      hits: hits,
      isTruncated: isTruncated,
      coverage: coverage,
    );
  }

  /// Deterministic hit order (C05): score desc, occurrence asc, start
  /// asc, end asc.
  static int _hitOrder(final IndexedSearchHit a, final IndexedSearchHit b) {
    var order = b.score.compareTo(a.score);
    if (order != 0) return order;
    order = a.sectionIndex.compareTo(b.sectionIndex);
    if (order != 0) return order;
    order = a.start.compareTo(b.start);
    if (order != 0) return order;

    return a.end.compareTo(b.end);
  }

  /// Expands one query token under [mode]: the exact term plus, for
  /// prefix/fuzzy, the bounded fan-out of the radix tree.
  List<(String, double)> _expandToken(
    final String token, {
    required final IndexedQueryMode mode,
    required final int expansionCap,
  }) {
    final expansions = <(String, double)>[];
    if (token.length > _limits.effectiveMaxTermLength) return expansions;
    final exact = _terms.get(token);
    if (exact != null) expansions.add((token, exactTermWeight));
    switch (mode) {
      case IndexedQueryMode.exact:
        break;
      case IndexedQueryMode.prefix:
        var seen = 0;
        for (final (term, _) in _terms.entriesAtPrefix(token)) {
          final extra = term.length - token.length;
          if (extra <= 0) continue; // The exact term already joined.
          if (seen >= expansionCap) {
            throw SearchIndexLimitExceededException(
              'The prefix "$token" expands past the $expansionCap-term cap.',
            );
          }
          seen++;
          expansions.add((
            term,
            prefixExpansionWeight(extraLength: extra, queryLength: token.length),
          ));
        }
      case IndexedQueryMode.fuzzy:
        final maxDistance = _fuzzyDistanceFor(token);
        if (maxDistance <= 0) break;
        var seen = 0;
        for (final (term, _, distance) in _terms.fuzzyEntries(token, maxDistance)) {
          if (distance == 0) continue; // The exact term already joined.
          if (seen >= expansionCap) {
            throw SearchIndexLimitExceededException(
              'The fuzzy token "$token" expands past the $expansionCap-term cap.',
            );
          }
          seen++;
          expansions.add((term, fuzzyExpansionWeight(termLength: term.length, distance: distance)));
        }
    }

    return expansions;
  }

  /// MiniSearch's fractional rule: a fifth of the token length, rounded,
  /// capped by the limits (`maxFuzzy`).
  int _fuzzyDistanceFor(final String token) {
    final derived = (token.length * 0.2).round();

    return derived > _limits.effectiveMaxFuzzyDistance
        ? _limits.effectiveMaxFuzzyDistance
        : derived;
  }

  /// Serializes the complete index into a versioned, JSON-safe wire
  /// map. Refuses while the build is incomplete, cancelled or not
  /// persistable (PDF until P1).
  Map<String, Object?> serialize() {
    _ensureOpen();
    if (!_complete) {
      throw const SearchIndexException(
        'Only a complete index serializes; coverage still has pending or '
        'failed sections.',
      );
    }
    if (!persistable) {
      throw const SearchIndexUnsupportedException(
        'Persisting an index over PDF text awaits the P1 position-mapping '
        'acceptance; the in-memory index keeps working.',
      );
    }

    return <String, Object?>{
      'schemaVersion': _schemaVersion,
      'profile': <String, Object?>{
        'tokenizer': SearchIndexTokenizer.tokenizerId,
        'normalization': SearchIndexTokenizer.normalizationId,
        'textProfile': SearchIndexTokenizer.textProfileId,
      },
      'identity': identity.toWire(),
      'readingOrderRevision': _readingOrderRevision,
      'sections': <Object?>[
        for (final section in _sections)
          <Object?>[
            section.sectionIndex,
            section.path,
            section.tokenCount,
            section.textLength,
            section.textRevision,
          ],
      ],
      'terms': <Object?>[
        for (final (term, postings) in _terms.entriesAtPrefix(''))
          <Object?>[
            term,
            <Object?>[
              for (final entry in postings.bySection.entries) <Object?>[entry.key, entry.value],
            ],
          ],
      ],
    };
  }

  /// Rebuilds an index from a serialized payload.
  ///
  /// Validation happens before any posting is trusted or allocated:
  /// payload size, schema version, profile ids, identity, then the
  /// structural bounds (section, term, occurrence and range limits) —
  /// a hostile payload fails typed, early. With [book] (the eager
  /// path) or [sectionText] (the session path, which materializes text
  /// on demand), the index is additionally verified against the live
  /// content — reading-order revision, section names and per-section
  /// text revisions must match, or
  /// `SearchIndexIncompatibleException` names the mismatch — and the
  /// resolved texts feed the snippet cache. Without a text source the
  /// index loads structurally and serves empty snippets.
  static BookSearchIndex deserialize(
    final Map<String, Object?> payload, {
    final SearchIndexLimits limits = const SearchIndexLimits(),
    final Book? book,
    final String? Function(int sectionIndex, String path)? sectionText,
    final SearchIndexIdentity? identity,
  }) {
    final encodedLength = convert.json.encode(payload).length;
    if (encodedLength > limits.effectiveMaxSerializedBytes) {
      throw SearchIndexLimitExceededException(
        'The serialized index carries $encodedLength code units, above the '
        '${limits.effectiveMaxSerializedBytes} import cap.',
      );
    }
    final version = payload['schemaVersion'];
    if (version is! int) {
      throw const FormatException('searchIndex payload carries no integer schemaVersion.');
    }
    if (version != _schemaVersion) {
      throw SearchIndexIncompatibleException(
        'The serialized index uses schemaVersion $version; this build '
        'reads $_schemaVersion.',
      );
    }
    final profile = payload['profile'];
    if (profile is! Map<String, Object?> ||
        profile['tokenizer'] != SearchIndexTokenizer.tokenizerId ||
        profile['normalization'] != SearchIndexTokenizer.normalizationId ||
        profile['textProfile'] != SearchIndexTokenizer.textProfileId) {
      throw const SearchIndexIncompatibleException(
        'The serialized index was built under a different tokenizer or '
        'normalization profile.',
      );
    }
    final wireIdentity = SearchIndexIdentity.fromWire(payload['identity']);
    if (identity != null &&
        !identity.isCompatibleWith(wireIdentity ?? const SearchIndexIdentity())) {
      throw const SearchIndexIncompatibleException(
        'The serialized index identity does not match the requested '
        'identity: absent fields are not wildcards.',
      );
    }
    final revision = payload['readingOrderRevision'];
    if (revision is! String?) {
      throw const FormatException('searchIndex readingOrderRevision must be a string.');
    }

    final sectionsWire = payload['sections'];
    if (sectionsWire is! List<Object?>) {
      throw const FormatException('searchIndex sections must be an array.');
    }
    if (sectionsWire.length > limits.effectiveMaxSections) {
      throw SearchIndexLimitExceededException(
        'The serialized index declares ${sectionsWire.length} sections, '
        'above the ${limits.effectiveMaxSections} limit.',
      );
    }
    final sections = <_IndexedSection>[];
    for (final sectionWire in sectionsWire) {
      final section = _parseSection(sectionWire, limits);
      sections.add(section);
    }

    final termsWire = payload['terms'];
    if (termsWire is! List<Object?>) {
      throw const FormatException('searchIndex terms must be an array.');
    }
    if (termsWire.length > limits.effectiveMaxTerms) {
      throw SearchIndexLimitExceededException(
        'The serialized index declares ${termsWire.length} terms, above the '
        '${limits.effectiveMaxTerms} limit.',
      );
    }

    final index = BookSearchIndex._(
      identity: identity ?? wireIdentity ?? const SearchIndexIdentity(),
      limits: limits,
      persistable: true,
    ).._readingOrderRevision = revision;
    var occurrences = 0;
    for (final termWire in termsWire) {
      if (termWire is! List<Object?> || termWire.length != 2) {
        throw const FormatException('searchIndex term entries must be [term, postings].');
      }
      final term = termWire[0];
      if (term is! String || term.isEmpty || term.length > limits.effectiveMaxTermLength) {
        throw const FormatException('searchIndex term is out of bounds.');
      }
      final postingsWire = termWire[1];
      if (postingsWire is! List<Object?>) {
        throw const FormatException('searchIndex postings must be an array.');
      }
      final postings = _TermPostings();
      for (final sectionPostings in postingsWire) {
        if (sectionPostings is! List<Object?> || sectionPostings.length != 2) {
          throw const FormatException('searchIndex section postings must be [sectionId, ranges].');
        }
        final sectionId = sectionPostings[0];
        if (sectionId is! int || sectionId < 0 || sectionId >= sections.length) {
          throw const FormatException('searchIndex section id is out of bounds.');
        }
        final ranges = sectionPostings[1];
        if (ranges is! List<Object?> || ranges.isEmpty || ranges.length.isOdd) {
          throw const FormatException('searchIndex ranges must be non-empty start/end pairs.');
        }
        final sectionLength = sections[sectionId].textLength;
        final stored = <int>[];
        for (final range in ranges) {
          if (range is! int || range < 0) {
            throw const FormatException('searchIndex range offset is out of bounds.');
          }
          stored.add(range);
        }
        for (var i = 0; i + 1 < stored.length; i += 2) {
          // Ranges must fit the section text the index claims to
          // address.
          if (stored[i] > stored[i + 1] || stored[i + 1] > sectionLength) {
            throw const FormatException('searchIndex range is outside the declared section text.');
          }
        }
        occurrences += stored.length ~/ 2;
        if (occurrences > limits.effectiveMaxOccurrences) {
          throw SearchIndexLimitExceededException(
            'The serialized index declares more than the '
            '${limits.effectiveMaxOccurrences}-occurrence limit.',
          );
        }
        if (postings.bySection.containsKey(sectionId)) {
          throw const FormatException('searchIndex postings repeat a section.');
        }
        postings.bySection[sectionId] = stored;
      }
      index._terms.set(term, postings);
      index._distinctTerms++;
    }

    index._sections.addAll(sections);
    var totalTokens = 0;
    for (final section in sections) {
      totalTokens += section.tokenCount;
    }
    index._totalTokens = totalTokens;
    index._totalOccurrences = occurrences;
    index._complete = true;

    if (book != null) index._verifyAgainstBook(book);
    if (sectionText != null) index._verifyAgainstTexts(sectionText);

    return index;
  }

  static _IndexedSection _parseSection(final Object? sectionWire, final SearchIndexLimits limits) {
    if (sectionWire is! List<Object?> || sectionWire.length != 5) {
      throw const FormatException(
        'searchIndex section entries must be '
        '[index, path, tokenCount, textLength, textRevision].',
      );
    }
    final sectionIndex = sectionWire[0];
    final path = sectionWire[1];
    final tokenCount = sectionWire[2];
    final textLength = sectionWire[3];
    final textRevision = sectionWire[4];
    // 2^31 literals: dart2js shifts wrap at 32 bits (1 << 31 is
    // negative on the web).
    if (sectionIndex is! int || sectionIndex < 0 || sectionIndex > 2147483648) {
      throw const FormatException('searchIndex section index is out of bounds.');
    }
    if (path is! String || path.isEmpty || path.length > 4096) {
      throw const FormatException('searchIndex section path is out of bounds.');
    }
    if (tokenCount is! int || tokenCount < 0 || tokenCount > 2147483648) {
      throw const FormatException('searchIndex token count is out of bounds.');
    }
    if (textLength is! int || textLength < 0 || textLength > 2147483648) {
      throw const FormatException('searchIndex text length is out of bounds.');
    }
    if (textRevision is! String || textRevision.length != 64) {
      throw const FormatException('searchIndex text revision must be a sha256 hex digest.');
    }

    return _IndexedSection(
      sectionIndex: sectionIndex,
      path: path,
      tokenCount: tokenCount,
      textLength: textLength,
      textRevision: textRevision,
    );
  }

  /// Verifies a deserialized index against the live book: order
  /// revision, section names and per-section text digests. Every
  /// mismatch refuses the index as a whole — stale postings never
  /// surface as valid.
  void _verifyAgainstBook(final Book book) {
    final order = book.readingOrder;
    if (_readingOrderRevision != null && readingOrderRevisionOf(order) != _readingOrderRevision) {
      throw const SearchIndexIncompatibleException(
        'The book reading order changed since the index was built.',
      );
    }
    final htmlByPath = <String, TextFile>{for (final file in book.files.html) file.path: file};
    for (var internalId = 0; internalId < _sections.length; internalId++) {
      final section = _sections[internalId];
      if (section.sectionIndex >= order.length) {
        throw SearchIndexIncompatibleException(
          'Indexed section ${section.sectionIndex} is outside the book '
          'reading order.',
        );
      }
      final item = order[section.sectionIndex];
      if (item.name != section.path || !item.isHtml) {
        throw SearchIndexIncompatibleException(
          'Section ${section.sectionIndex} moved: the index addresses '
          '${section.path}, the book holds ${item.name}.',
        );
      }
      final file = htmlByPath[section.path];
      if (file == null) {
        throw SearchIndexIncompatibleException(
          'Indexed section ${section.path} has no document text in the '
          'book.',
        );
      }
      final text = documentTextOf(file);
      if (textRevisionOf(text) != section.textRevision) {
        throw SearchIndexIncompatibleException(
          'The text of section ${section.path} changed since the index '
          'was built.',
        );
      }
      _sectionTextCache[internalId] = text;
    }
  }

  /// The session-path twin of [_verifyAgainstBook]: the resolver
  /// materializes each section's canonical text (or returns null when
  /// the section is missing), and every digest must match.
  void _verifyAgainstTexts(final String? Function(int sectionIndex, String path) sectionText) {
    for (var internalId = 0; internalId < _sections.length; internalId++) {
      final section = _sections[internalId];
      final text = sectionText(section.sectionIndex, section.path);
      if (text == null) {
        throw SearchIndexIncompatibleException(
          'Indexed section ${section.path} has no document text.',
        );
      }
      if (textRevisionOf(text) != section.textRevision) {
        throw SearchIndexIncompatibleException(
          'The text of section ${section.path} changed since the index '
          'was built.',
        );
      }
      _sectionTextCache[internalId] = text;
    }
  }

  /// Releases the index and the retained section texts. Every later
  /// operation fails with `SearchIndexDisposedException`.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sectionTextCache.clear();
    _pending.clear();
    _failed.clear();
    _complete = false;
  }

  void _ensureOpen() {
    if (_disposed) throw const SearchIndexDisposedException('The search index was disposed.');
  }
}

/// One term's postings: per internal section id, the flat
/// `[start, end, ...]` occurrence ranges in the section's text.
final class _TermPostings {
  final Map<int, List<int>> bySection = <int, List<int>>{};
}

/// One indexed section's ranking metadata and identity.
final class _IndexedSection {
  const _IndexedSection({
    required this.sectionIndex,
    required this.path,
    required this.tokenCount,
    required this.textLength,
    required this.textRevision,
  });

  final int sectionIndex;
  final String path;
  final int tokenCount;
  final int textLength;
  final String textRevision;
}

/// Cooperative cancellation of an incremental index build: checked at
/// batch boundaries only — a bounded batch always finishes, so a
/// cancelled build still stops work observably in finite steps.
final class SearchIndexCancellationToken {
  bool _isCancelled = false;

  /// Whether cancellation was requested.
  bool get isCancelled => _isCancelled;

  /// Requests cancellation; the current batch finishes first.
  void cancel() => _isCancelled = true;
}
