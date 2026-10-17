import '../../../foundation/exceptions/unseal_exception.dart';

/// Failures of the optional per-publication search index.
///
/// The index API distinguishes the failure kinds of the shared campaign
/// contract: invalid argument, incompatible revision/profile, exceeded
/// limit, cancelled construction and disposed instance. Every kind is a
/// distinct subtype, so callers (and the session error wire) can tell
/// them apart without parsing messages.
final class SearchIndexException extends UnsealException {
  /// Creates the base index failure.
  const SearchIndexException(super.message);
}

/// A query argument cannot be interpreted: too many tokens, a negative
/// limit, or a term above the term-length cap. Not a content mismatch —
/// fixing the argument re-runs the same query.
final class SearchIndexInvalidArgumentException extends SearchIndexException {
  /// Creates the invalid-argument failure.
  const SearchIndexInvalidArgumentException(super.message);
}

/// A serialized index (or one reused against a book) does not match the
/// target: schema version, tokenizer/normalization profile, reading
/// order revision, text revision, or identity fields disagree. The
/// index is rejected as a whole — stale postings never surface as if
/// they were valid.
final class SearchIndexIncompatibleException extends SearchIndexException {
  /// Creates the incompatibility failure.
  const SearchIndexIncompatibleException(super.message);
}

/// Work or output crossed a declared limit: expansion fan-out on a
/// prefix/fuzzy token, total postings while indexing, or a serialized
/// payload above the import cap. The limit is part of
/// `SearchIndexLimits`; raising it is the caller's explicit decision.
final class SearchIndexLimitExceededException extends SearchIndexException {
  /// Creates the exceeded-limit failure.
  const SearchIndexLimitExceededException(super.message);
}

/// Index construction was cancelled at a batch boundary. Work already
/// finished stays visible through the coverage counters; no complete
/// index is produced from a cancelled build.
final class SearchIndexCancelledException extends SearchIndexException {
  /// Creates the cancellation failure.
  const SearchIndexCancelledException(super.message);
}

/// The index was disposed; every further operation fails until a new
/// index is built or imported. Mirrors `SessionClosedException` for
/// the index lifecycle.
final class SearchIndexDisposedException extends SearchIndexException {
  /// Creates the disposed failure.
  const SearchIndexDisposedException(super.message);
}

/// The requested index behavior exists but is deliberately withheld in
/// this delivery: persisting an index over PDF text waits for the P1
/// position-mapping acceptance. In-memory querying stays available.
final class SearchIndexUnsupportedException extends SearchIndexException {
  /// Creates the unsupported-behavior failure.
  const SearchIndexUnsupportedException(super.message);
}
