import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';

/// A host-owned random-access source for one book container.
///
/// The host keeps every transport concern — HTTP, authentication,
/// storage, retries, caching. Unseal orders byte ranges against this
/// contract, validates every answer, and enforces budgets; it never
/// opens connections itself. Implement it to open an EPUB, CBZ or PDF
/// through the `BookSession.openSource` entry point without handing
/// Unseal the whole file:
///
/// ```dart
/// class HttpByteSource implements UnsealByteSource {
///   @override
///   final int length;
///   @override
///   final String? revision; // e.g. the ETag observed on a HEAD request
///
///   HttpByteSource(this.length, this.revision);
///
///   @override
///   Future<Uint8List> readRange(final int offset, final int count) async {
///     // One HTTP Range request; the answer must be exactly [count]
///     // bytes — shorter or longer answers fail the session op typed.
///     return http.fetchRange(offset, count);
///   }
///
///   @override
///   Future<void> close() async {}
/// }
/// ```
///
/// [readRange] is the only read primitive. For EPUB and CBZ, Unseal
/// requests the end-of-central-directory tail and the central
/// directory at open, then per entry the local header and the
/// compressed payload — the whole compressed payload for Deflate
/// entries, whose real decompression unit is the entry; stored entries
/// can be served from an exact sub-slice. For PDF, Unseal parses
/// demand-driven: the header and `startxref` tails, the xref chain
/// windows, the object windows the structure walk touches and each
/// materialized page's streams arrive as separate exact ranges, so
/// open and first-content requests stay a small fraction of [length]
/// for any normally shaped document.
abstract interface class UnsealByteSource {
  /// Total container length in bytes.
  int get length;

  /// Opaque revision/identity token, or null when the host cannot
  /// verify identity. Sessions capture the revision at open and stamp
  /// every range request with it; a source whose revision changed
  /// under an open session fails its reads typed instead of returning
  /// bytes from a different file state.
  String? get revision;

  /// Reads exactly [count] bytes at [offset].
  ///
  /// Out-of-bounds arguments throw [RangeError]. The returned bytes
  /// must be exactly [count] long: a short answer completes with
  /// [ByteSourceShortReadException] and a long one with
  /// [ByteSourceLongReadException] — never as a truncated success.
  /// Host failures surface as [ByteSourceReadException]. Reads after
  /// [close] fail with [ByteSourceClosedException].
  Future<Uint8List> readRange(final int offset, final int count);

  /// Releases the underlying transport resources. Unseal calls this
  /// when the session over the source is disposed; sources may also be
  /// closed by their owner, which fails the session's pending reads.
  Future<void> close();
}

/// A read against a [UnsealByteSource] failed its contract. The
/// concrete subclasses distinguish the failure modes a host can
/// produce; the message names the range involved.
sealed class ByteSourceException extends UnsealException {
  /// Creates the typed byte-source failure.
  const ByteSourceException(super.message);
}

/// The source was closed before or while a read was in flight.
final class ByteSourceClosedException extends ByteSourceException {
  /// Creates the typed closed-source failure.
  const ByteSourceClosedException() : super('The byte source is closed.');
}

/// The host returned fewer bytes than requested.
final class ByteSourceShortReadException extends ByteSourceException {
  /// Creates the typed short-read failure.
  const ByteSourceShortReadException({
    required final int offset,
    required final int count,
    required final int received,
  }) : super('Byte source returned $received of $count bytes at offset $offset.');
}

/// The host returned more bytes than requested.
final class ByteSourceLongReadException extends ByteSourceException {
  /// Creates the typed long-read failure.
  const ByteSourceLongReadException({
    required final int offset,
    required final int count,
    required final int received,
  }) : super(
         'Byte source returned $received bytes for the $count-byte read '
         'at offset $offset.',
       );
}

/// The host's read failed: an exception escaped [UnsealByteSource.readRange].
/// The original message is preserved; transport-specific error objects
/// stay with the host.
final class ByteSourceReadException extends ByteSourceException {
  /// Creates the typed host-failure wrapper.
  const ByteSourceReadException(Object error) : super('Byte source read failed: $error');
}

/// The source's [UnsealByteSource.revision] no longer matches the
/// revision the session captured at open. The bytes on the wire may
/// belong to a different file state, so the read fails instead of
/// mixing revisions. Reopen the session over the new revision.
final class ByteSourceRevisionChangedException extends ByteSourceException {
  /// Creates the typed revision-change failure.
  const ByteSourceRevisionChangedException({
    required final String? expected,
    required final String? actual,
  }) : super(
         'Byte source revision changed under the open session '
         '(expected ${expected ?? 'null'}, found ${actual ?? 'null'}).',
       );
}

/// A read exceeded one of the session's range budgets. Requests above
/// the per-request cap fail instead of silently downloading the
/// container; in-flight caps queue requests rather than failing them.
final class ByteSourceLimitExceededException extends ByteSourceException {
  /// Creates the typed limit failure.
  const ByteSourceLimitExceededException(super.message);
}
