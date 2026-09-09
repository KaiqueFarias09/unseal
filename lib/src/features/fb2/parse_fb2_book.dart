import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import 'container/fb2_document.dart';
import 'entities/entities.dart';
import 'metadata/fb2_metadata.dart';
import 'rendering/fb2_html_renderer.dart';
import 'resources/fb2_resources.dart';

export 'metadata/fb2_metadata.dart' show readFb2Metadata;

/// Parses an FB2 book from raw [bytes] (plain XML or zipped FB2).
Fb2Book parseFb2Book(final Uint8List bytes) => _parseFb2Source(Fb2Source.fromBytes(bytes));

/// Parses an FB2 book from a zip archive [entry].
Fb2Book parseFb2Archive(final ArchiveFile entry) => _parseFb2Source(Fb2Source.fromArchive(entry));

Fb2Book _parseFb2Source(final Fb2Source source) {
  final document = source.parseDocument();
  final resources = Fb2Resources.fromRoot(document.root);
  final metadata = mapFb2Metadata(document.root, resources);
  final converted = convertBodies(
    document.bodies,
    metadata.title ?? '',
    resources.extensionMap,
    stylesheets: extractFb2Stylesheets(document.root),
  );
  final htmlFiles = <TextFile>[
    for (final entry in converted.files.entries)
      TextFile(name: entry.key, type: 'html', path: entry.key, content: entry.value),
  ];

  return Fb2Book(
    navigation: converted.navigation,
    files: Files(
      images: resources.images,
      css: converted.css,
      html: htmlFiles,
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    cover: resources.cover,
    metadata: metadata,
  );
}
