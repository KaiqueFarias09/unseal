import 'dart:typed_data';

import 'package:archive/archive.dart';
import '../entities/entities.dart';

/// Builds the archive inventory used by format adapters.
List<ArchiveEntry> archiveInventory(final Archive archive) => <ArchiveEntry>[
  for (final entry in archive.files)
    if (entry.isFile) ArchiveEntry(path: entry.name, size: entry.size),
];

/// Reads a ZIP entry's content without exposing the package's mutable list.
Uint8List zipBytes(final ArchiveFile entry) {
  final content = entry.content;

  return content is Uint8List
      ? Uint8List.sublistView(content)
      : Uint8List.fromList(content as List<int>);
}
