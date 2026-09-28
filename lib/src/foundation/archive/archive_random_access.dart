import 'dart:typed_data';

/// One entry of a random-access book container.
abstract interface class ArchiveEntry {
  /// Archive path as stored in the container.
  String get name;

  /// Whether the record carries a payload (directories do not).
  bool get isFile;

  /// Declared uncompressed payload size in bytes.
  int get uncompressedSize;
}

/// Random access over a book container: the container's index is parsed
/// once at open and each entry is inflated on demand.
///
/// This is the format-neutral contract behind the progressive session
/// engine — zip containers ([`ZipRandomAccess`]) and RAR containers
/// ([`RarRandomAccess`]) implement it, so the engine and the comic
/// session header stay format-blind. Implementations read only the
/// slices they need from a [`ZipByteSource`], keep no more than one
/// inflated entry resident per call, and never leak parser errors:
/// failures surface as the typed `UnsealException` hierarchy.
abstract interface class ArchiveRandomAccess {
  /// Every indexed entry in container order, directories included
  /// (with [ArchiveEntry.isFile] false).
  List<ArchiveEntry> get entries;

  /// Finds an entry by [path] — exact, then normalized, then
  /// case-insensitive; null when no entry matches.
  ArchiveEntry? find(final String path);

  /// Inflates one entry, bounded by [maxBytes] (default: the
  /// implementation's declared-size cap). Corrupt or unsupported
  /// payloads are typed rejections naming the entry.
  Uint8List inflate(final ArchiveEntry entry, {final int? maxBytes});

  /// Returns the first [byteCount] bytes of [entry]'s payload — enough
  /// for content sniffing without materializing the whole payload.
  Uint8List head(final ArchiveEntry entry, final int byteCount);

  /// Releases the underlying byte source.
  void close();
}
