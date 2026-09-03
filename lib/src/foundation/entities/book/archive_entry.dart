/// A physical entry of a book's container archive.
///
/// The inventory comes from the container itself (e.g. the EPUB zip),
/// independent of the publication manifest: infrastructure files such
/// as `META-INF/container.xml` and stray entries show up alongside the
/// manifest content. Mirrors the container view of Calibre's
/// `mime_map`. Nothing is parsed — the extracted, typed content files
/// live in the book's `Files`.
final class ArchiveEntry {
  /// Creates an [ArchiveEntry].
  const ArchiveEntry({required this.path, required this.size});

  /// Entry name as stored in the archive (e.g. `OEBPS/text/ch1.xhtml`).
  final String path;

  /// Uncompressed byte size of the entry.
  final int size;

  @override
  String toString() => 'ArchiveEntry($path, $size)';
}
