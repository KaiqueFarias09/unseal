import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import '../../foundation/archive/archive_access.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../../foundation/metadata/series_index.dart';
import '../../foundation/text/xml_encoding.dart';
import 'entities/entities.dart';
import 'exceptions/exceptions.dart';

part 'container/fb2_document.dart';
part 'metadata/fb2_metadata.dart';
part 'rendering/fb2_html_renderer.dart';
part 'resources/fb2_resources.dart';

/// Parses an FB2 book from raw [bytes] (plain XML or zipped FB2).
Fb2Book parseFb2Book(final Uint8List bytes) => _parseFb2Source(_Fb2Source.fromBytes(bytes));

/// Parses an FB2 book from a zip archive [entry].
Fb2Book parseFb2Archive(final ArchiveFile entry) => _parseFb2Source(_Fb2Source.fromArchive(entry));

/// Reads only the metadata of an FB2 book from [bytes].
BookMetadata readFb2Metadata(final Uint8List bytes) {
  return _readFb2SourceMetadata(_Fb2Source.fromBytes(bytes));
}

Fb2Book _parseFb2Source(final _Fb2Source source) {
  final document = source.parseDocument();
  final resources = _Fb2Resources.fromRoot(document.root);
  final metadata = _mapFb2Metadata(document.root, resources);
  final converted = _convertBodies(
    document.bodies,
    metadata.title ?? '',
    resources.extensionMap,
    stylesheets: _extractFb2Stylesheets(document.root),
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
