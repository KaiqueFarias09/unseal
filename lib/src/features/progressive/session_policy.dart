import '../../foundation/exceptions/unseal_exception.dart';

/// A pending operation was cancelled through `BookSession.cancelPending`.
final class SessionCancelledException extends UnsealException {
  /// Creates the typed cancellation.
  const SessionCancelledException() : super('The operation was cancelled.');
}

/// The session was disposed; every operation — pending or new — fails
/// until a new session opens.
final class SessionClosedException extends UnsealException {
  /// Creates the typed closed-session failure.
  const SessionClosedException() : super('The session is closed.');
}

/// The format cannot open as a progressive session (it has no random
/// access container the session supports). Callers fall back to
/// `Unseal.read` / `Unseal.readFile`.
final class SessionUnsupportedFormatException extends UnsealException {
  /// Creates the typed unsupported-format failure.
  const SessionUnsupportedFormatException(super.message);
}

/// Byte and cover budgets of a progressive session.
///
/// [cacheBytes] bounds the worker-side LRU that holds inflated entries
/// (raw resource bytes count by their length, document text by twice
/// its code-unit count); the oldest entries evict first and the
/// container inventory never evicts. [coverMaxBytes] caps the cover
/// carried inside the header book: larger covers load like any other
/// resource instead. [rangeMaxBytes] caps the raw source slices
/// `BookSession.loadBytesRange` hands out.
///
/// The range-request budgets apply to sessions opened over an external
/// [UnsealByteSource]: at most [rangeRequestsInFlight] reads are being
/// served at once, their combined counts stay under
/// [rangeBytesInFlight], and no single request may ask for more than
/// [rangeRequestBytes] — entries whose compressed payload exceeds that
/// cap fail typed instead of downloading the container. Requests above
/// the in-flight caps queue (backpressure) rather than fail.
final class SessionPolicy {
  /// Creates a policy; the defaults target reader-class devices.
  const SessionPolicy({
    this.cacheBytes = 64 << 20,
    this.coverMaxBytes = 8 << 20,
    this.rangeMaxBytes = 8 << 20,
    this.rangeRequestsInFlight = 8,
    this.rangeBytesInFlight = 32 << 20,
    this.rangeRequestBytes = 64 << 20,
  });

  /// Worker-side LRU budget in bytes. Values below 1 MiB clamp to 1 MiB
  /// so a working chapter always fits.
  final int cacheBytes;

  /// Largest cover (in inflated bytes) kept inside the header book.
  final int coverMaxBytes;

  /// Largest raw source slice (in bytes) one `loadBytesRange` call
  /// returns. Values below 64 KiB clamp to 64 KiB so range serving
  /// stays practical.
  final int rangeMaxBytes;

  /// Range reads served concurrently over an external byte source.
  /// Values below 1 clamp to 1.
  final int rangeRequestsInFlight;

  /// Combined byte count of the range reads being served over an
  /// external byte source. Values below 1 MiB clamp to 1 MiB.
  final int rangeBytesInFlight;

  /// Largest single range request over an external byte source, in
  /// bytes. Values below 1 MiB clamp to 1 MiB; values above
  /// [rangeBytesInFlight] clamp to it.
  final int rangeRequestBytes;

  /// The effective cache budget after clamping.
  int get effectiveCacheBytes => cacheBytes < 1 << 20 ? 1 << 20 : cacheBytes;

  /// The effective range cap after clamping.
  int get effectiveRangeMaxBytes => rangeMaxBytes < 1 << 16 ? 1 << 16 : rangeMaxBytes;

  /// The effective in-flight request cap after clamping.
  int get effectiveMaxRangeRequestsInFlight =>
      rangeRequestsInFlight < 1 ? 1 : rangeRequestsInFlight;

  /// The effective in-flight byte cap after clamping.
  int get effectiveMaxRangeBytesInFlight =>
      rangeBytesInFlight < 1 << 20 ? 1 << 20 : rangeBytesInFlight;

  /// The effective per-request byte cap after clamping.
  int get effectiveMaxRangeRequestBytes =>
      rangeRequestBytes < 1 << 20 ? 1 << 20 : rangeRequestBytes;
}
