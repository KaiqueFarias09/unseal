# Proposal: shared byte-source transport (`byteSource.*`) — B02

Status: proposal registered early for coordinator review, as the campaign
README requires. B02 implements it on `codex/unseal-byte-ranges`; B04/B05
do not depend on it. PDF/MOBI/RAR over an external source are out of
scope for this round.

## Public contract (host-owned transport)

```dart
abstract interface class UnsealByteSource {
  /// Total container length in bytes.
  int get length;

  /// Opaque revision/identity token (e.g. an ETag). Reads carry the
  /// revision observed at open; a source whose revision changed fails
  /// typed instead of returning bytes from a different file state.
  /// Null means the host cannot verify identity.
  String? get revision;

  /// Reads exactly [count] bytes at [offset]. Out-of-bounds arguments
  /// throw RangeError; implementations must return exactly [count]
  /// bytes — a short or long answer is a typed failure, never a
  /// truncated success.
  Future<Uint8List> readRange(final int offset, final int count);

  /// Releases host resources. Reads after close fail typed.
  Future<void> close();
}
```

The host keeps HTTP, authentication, storage, and retries. Unseal only
orders ranges, validates answers, and enforces budgets. Entry points:

- `BookSession.openSource(source, {policy})` — EPUB and CBZ today.
  Other formats and other ZIP books are refused explicitly with
  `SessionUnsupportedFormatException` naming the format; PDF and RAR
  keep their bytes/file opens this round.

## Where the boundary now sits

`ZipByteSource` / `ArchiveRandomAccess` / `SessionEngine` were
synchronous. The resolution, explicitly:

- `SessionEngine` ops become asynchronous end to end. Sync sources
  (bytes, file) are wrapped by an adapter that completes immediately,
  so the 1.3.0 bytes/file session behavior is preserved through the
  same code path.
- A new internal async ZIP random-access layer reads, per open: one
  tail window (end-of-central-directory scan), the central directory
  in bounded windows, then — per materialized entry — the local
  header and the compressed payload. A stored entry can be served
  from an exact sub-slice; a Deflate entry's real decompression unit
  is its whole compressed payload, and that is what gets requested
  and declared.
- Header builds (`buildEpubSessionHeader`, `buildComicSessionHeader`)
  await their entry materializations; the EPUB readers downstream keep
  consuming the already-materialized archive unchanged.

## Versioned transport protocol (`byteSource.v1`)

New op prefix per campaign convention: `byteSource.*`.

- VM isolate: the bootstrap gains the source's limits; the engine-side
  reader sends `['byteSource.v1.request', requestId, offset, count,
  revision]` over the handshake reply port; the host gate answers on a
  dedicated isolate port announced as the first handshake message:
  `['byteSource.v1.reply', requestId, bytes]` or
  `['byteSource.v1.error', requestId, type, message]`.
- Browser worker: the worker posts
  `{kind: 'byteSource.v1.request', sessionId, requestId, offset,
  count, revision}`; the main-thread gate answers
  `{kind: 'byteSource.v1.reply', requestId, bytes}` (or `...error`).
  Every session op payload keeps its `sessionId`, so two sessions
  never exchange data.
- Inline fallback (no isolate / no worker): the engine-side reader is
  the gate itself, calling `readRange` directly.

## Budgets and lifecycle

`SessionPolicy` gains three additive fields (defaults chosen so real
books open without configuration):

- `maxRangeRequestsInFlight` (default 8) — requests beyond the cap
  queue on the host (backpressure), they do not fail.
- `maxRangeBytesInFlight` (default 32 MiB) — cumulative outstanding
  bytes; a request that would exceed the cap waits.
- `maxRangeRequestBytes` (default 64 MiB) — hard cap per single
  request; a container entry whose compressed payload exceeds it fails
  typed instead of silently downloading the file.

The host-side gate is authoritative; the engine-side reader repeats
the bounds/revision checks so failures are typed at the op. `dispose`
closes the gate and the source; late replies are matched against live
request ids only, so a delayed answer cannot resurrect a request or
cross into another session.

## Shared files touched (coordinator map)

`book_session.dart` (new `openSource`), `session_engine.dart` (async
ops), `session_policy.dart` (three fields), `session_transport*.dart`
(bridge plumbing), `platform/web/worker_client.dart` +
`platform/web/worker_ops.dart` + `web/unseal_worker.dart` (worker byte
bridge), `platform/web/book_wire.dart` (protocol constants),
`lib/unseal.dart` (exports), CHANGELOG/README/docs. Wire changes are
backward-consistent: new message kinds only, no existing key changes.
