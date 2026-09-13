import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

import '../exceptions/elivre_exception.dart';

/// Hard cap on the TOTAL uncompressed size a book zip container may
/// declare (1 GiB) — the first zip-bomb guard, checked from the
/// central directory before any entry is inflated.
const int maxZipTotalUncompressedBytes = 1 << 30;

/// Hard cap on the uncompressed size a single zip entry may declare
/// (512 MiB).
const int maxZipEntryUncompressedBytes = 512 << 20;

/// Maximum aggregate expansion ratio (declared uncompressed bytes vs
/// container bytes) tolerated for books. Real-world books stay below
/// ~20x; hostile archives reach 1000x and beyond.
const int maxZipExpansionRatio = 200;

/// Declared totals below this size skip the ratio check so small
/// legitimate books are never rejected on ratio grounds.
const int minZipBytesForRatioCheck = 32 << 20;

/// Decodes a book zip container under the typed-error contract and
/// bounded-expansion guards.
///
/// Corrupt container bytes make package:archive throw untyped errors
/// (`ArchiveException`, `RangeError`, `FormatException`); those are
/// converted to [InvalidBookException] here, before they can escape a
/// parse entry point. Archive structures declaring more expansion
/// than [maxZipTotalUncompressedBytes] / [maxZipEntryUncompressedBytes]
/// / [maxZipExpansionRatio] are rejected the same way WITHOUT being
/// inflated — a hostile container must never get the chance to
/// allocate gigabytes from kilobytes.
///
/// Known limitation: the caps read DECLARED sizes from the central
/// directory; a forged pair (tiny declared size, bomb-sized deflate
/// stream) is caught only when the entry is inflated.
Archive decodeBookZip(final Uint8List bytes) {
  assertZipExpansionBounded(bytes);
  try {
    final archive = ZipDecoder().decodeBytes(bytes);
    // package:archive decodes entries LAZILY: a corrupt deflate stream
    // only throws when a parser first touches the entry's content, far
    // away from any typed boundary. Materialize every entry HERE so
    // hostile payloads fail typed at the container boundary.
    for (final file in archive.files) {
      if (file.isFile) contentBytes(file);
    }
    return archive;
  } on ELivreException {
    rethrow;
  } on Object catch (error) {
    throw InvalidBookException('Zip container could not be decoded (${error.runtimeType}).');
  }
}

/// Reads the central directory header sizes without inflating
/// anything and rejects containers whose declared expansion breaks
/// the caps. Returns silently when the directory is unreadable —
/// [ZipDecoder] produces the typed failure for those.
void assertZipExpansionBounded(final Uint8List bytes) {
  final declared = _declaredUncompressed(bytes);
  if (declared == null) return;
  final (total, largest) = declared;

  if (total > maxZipTotalUncompressedBytes) {
    throw InvalidBookException(
      'Zip container declares $total uncompressed bytes, above the '
      '$maxZipTotalUncompressedBytes-byte safety cap.',
    );
  }
  if (largest > maxZipEntryUncompressedBytes) {
    throw InvalidBookException(
      'Zip entry declares $largest uncompressed bytes, above the '
      '$maxZipEntryUncompressedBytes-byte safety cap.',
    );
  }
  if (total > minZipBytesForRatioCheck && bytes.isNotEmpty) {
    final ratio = total ~/ bytes.length;
    if (ratio > maxZipExpansionRatio) {
      throw InvalidBookException(
        'Zip container expansion ratio $ratio exceeds the '
        '$maxZipExpansionRatio zip-bomb safety cap.',
      );
    }
  }
}

/// Total and largest declared uncompressed sizes from the zip central
/// directory, or null when it cannot be located/parsed.
(int, int)? _declaredUncompressed(final Uint8List bytes) {
  const eocdSignature = 0x06054b50;
  const centralSignature = 0x02014b50;
  const maxComment = 65535 + 22;
  final eocdStart = bytes.length - maxComment < 0 ? 0 : bytes.length - maxComment;
  var eocd = -1;
  for (var pos = bytes.length - 4; pos >= eocdStart && pos >= 0; pos--) {
    if (_readUint32(bytes, pos) == eocdSignature) {
      eocd = pos;
      break;
    }
  }
  if (eocd < 0) return null;

  var entryCount = _readUint16(bytes, eocd + 10);
  var cursor = _readUint32(bytes, eocd + 16);
  final directoryEnd = cursor < bytes.length && cursor + _readUint32(bytes, eocd + 12) <= bytes.length
      ? cursor + _readUint32(bytes, eocd + 12)
      : bytes.length;
  var total = 0;
  var largest = 0;
  while (entryCount > 0 && cursor + 46 <= directoryEnd) {
    if (_readUint32(bytes, cursor) != centralSignature) return null;
    final uncompressed = _readUint32(bytes, cursor + 24);
    total += uncompressed;
    if (uncompressed > largest) largest = uncompressed;
    final nameLength = _readUint16(bytes, cursor + 28);
    final extraLength = _readUint16(bytes, cursor + 30);
    final commentLength = _readUint16(bytes, cursor + 32);
    cursor += 46 + nameLength + extraLength + commentLength;
    entryCount--;
  }
  return (total, largest);
}

int _readUint16(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 2 > bytes.length) return 0;
  return ByteData.sublistView(bytes, offset, offset + 2).getUint16(0, Endian.little);
}

int _readUint32(final Uint8List bytes, final int offset) {
  if (offset < 0 || offset + 4 > bytes.length) return 0;
  return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
}

/// Finds an archive entry by [entryPath] with exact, normalized and case-insensitive matching.
///
/// Manifest hrefs are relative to their manifest file, so callers should resolve them with
/// [resolveItemPath] first.
ArchiveFile? findArchiveFile(final Archive archive, final String entryPath) {
  final normalized = normalizeZipPath(entryPath);
  if (normalized.isEmpty) return null;

  for (final file in archive.files) {
    if (!file.isFile) continue;

    final normalizedFileName = normalizeZipPath(file.name).toLowerCase();
    if (file.name != normalized && normalizedFileName != normalized.toLowerCase()) continue;

    return file;
  }

  return null;
}

/// Resolves a manifest [href] against its [rootFilePath], handling fragments and `..` segments.
String resolveItemPath(final String? rootFilePath, final String href) {
  final hrefWithoutFragment = href.split('#').first;
  final directory = path.posix.dirname(rootFilePath ?? '');

  return normalizeZipPath(
    directory == '.' || directory.isEmpty ? hrefWithoutFragment : '$directory/$hrefWithoutFragment',
  );
}

/// Normalizes a zip entry path: forward slashes, resolved `.`/`..` segments, no leading slash.
String normalizeZipPath(final String zipPath) {
  final segments = <String>[];
  for (final segment in zipPath.split('/')) {
    if (segment.isEmpty || segment == '.') continue;

    if (segment == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }

    segments.add(segment);
  }

  return segments.join('/');
}

/// Returns archive entry content as a [Uint8List] without copying when the archive already decoded
/// it into one.
Uint8List contentBytes(final ArchiveFile entry) {
  final content = entry.content;
  if (content is Uint8List) return Uint8List.sublistView(content);

  return Uint8List.fromList(content as List<int>);
}
