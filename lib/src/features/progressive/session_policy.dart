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
/// resource instead.
final class SessionPolicy {
  /// Creates a policy; the defaults target reader-class devices.
  const SessionPolicy({this.cacheBytes = 64 << 20, this.coverMaxBytes = 8 << 20});

  /// Worker-side LRU budget in bytes. Values below 1 MiB clamp to 1 MiB
  /// so a working chapter always fits.
  final int cacheBytes;

  /// Largest cover (in inflated bytes) kept inside the header book.
  final int coverMaxBytes;

  /// The effective cache budget after clamping.
  int get effectiveCacheBytes => cacheBytes < 1 << 20 ? 1 << 20 : cacheBytes;
}
