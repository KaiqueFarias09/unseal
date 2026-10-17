import 'dart:typed_data';

import 'archive_random_access.dart';

/// Asynchronous twin of [ArchiveRandomAccess]: the container's index
/// is parsed once at open and each entry inflates on demand through
/// awaited reads.
///
/// The progressive session engine runs every content operation against
/// this contract. The zip implementation reads over an async byte
/// reader (memory, file, or a host's remote byte source); synchronous
/// containers — the RAR entry source — wrap through
/// [SyncAsyncArchive].
abstract interface class AsyncArchiveRandomAccess {
  /// Every indexed entry in container order, directories included
  /// (with [ArchiveEntry.isFile] false).
  List<ArchiveEntry> get entries;

  /// Finds an entry by [path] — exact, then normalized, then
  /// case-insensitive; null when no entry matches.
  ArchiveEntry? find(final String path);

  /// Inflates one entry, bounded by [maxBytes] (default: the
  /// implementation's declared-size cap). Corrupt, unsupported, or
  /// over-budget payloads are typed rejections naming the entry.
  Future<Uint8List> inflate(final ArchiveEntry entry, {final int? maxBytes});

  /// Returns the first [byteCount] bytes of [entry]'s payload — enough
  /// for content sniffing without materializing the whole payload.
  Future<Uint8List> head(final ArchiveEntry entry, final int byteCount);

  /// Releases the underlying byte source.
  Future<void> close();
}

/// Adapter completing immediately over a synchronous
/// [ArchiveRandomAccess] — the RAR entry source keeps its exact
/// 1.3.0 decode behavior while the engine runs one async code path.
final class SyncAsyncArchive implements AsyncArchiveRandomAccess {
  /// Wraps [source] without copying.
  SyncAsyncArchive(this.source);

  /// The wrapped synchronous archive.
  final ArchiveRandomAccess source;

  @override
  List<ArchiveEntry> get entries => source.entries;

  @override
  ArchiveEntry? find(final String path) => source.find(path);

  @override
  Future<Uint8List> inflate(final ArchiveEntry entry, {final int? maxBytes}) {
    return Future<Uint8List>.value(source.inflate(entry, maxBytes: maxBytes));
  }

  @override
  Future<Uint8List> head(final ArchiveEntry entry, final int byteCount) {
    return Future<Uint8List>.value(source.head(entry, byteCount));
  }

  @override
  Future<void> close() async => source.close();
}
