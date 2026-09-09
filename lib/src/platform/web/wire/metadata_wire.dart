import 'dart:typed_data';

import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:e_livre/src/foundation/utils/image_sniffer.dart';
import 'package:e_livre/src/platform/web/wire/book_components_wire.dart';

/// Encodes format-agnostic [metadata] into a wire payload.
(Map<String, Object?>, List<Object>) encodeMetadataWire(final BookMetadata metadata) {
  final blobs = <Object>[];

  return (encodeMetadataWireValue(metadata, blobs), blobs);
}

/// Decodes a [BookMetadata] wire payload produced by
/// [encodeMetadataWire].
BookMetadata decodeMetadataWire(final Map<String, Object?> json, final List<Object> blobs) =>
    decodeMetadataWireValue(json, blobs);

/// Encodes metadata into an existing book payload and blob list.
Map<String, Object?> encodeMetadataWireValue(
  final BookMetadata metadata,
  final List<Object> blobs,
) => <String, Object?>{
  'format': metadata.format.name,
  'title': metadata.title,
  'titleSort': metadata.titleSort,
  'authorSort': metadata.authorSort,
  'bookProducer': metadata.bookProducer,
  'publisher': metadata.publisher,
  'description': metadata.description,
  'isbn': metadata.isbn,
  'rights': metadata.rights,
  'series': metadata.series,
  'seriesIndex': metadata.seriesIndex,
  'publishedAt': metadata.publishedAt?.toIso8601String(),
  'authors': List<String>.of(metadata.authors),
  'languages': List<String>.of(metadata.languages),
  'subjects': List<String>.of(metadata.subjects),
  'identifiers': Map<String, String>.of(metadata.identifiers),
  'cover': metadata.cover == null
      ? null
      : <String, Object?>{
          'blob': pushWireBlob(blobs, metadata.cover!.bytes),
          'type': metadata.cover!.type.name,
          'width': metadata.cover!.width,
          'height': metadata.cover!.height,
        },
};

/// Decodes metadata embedded in a book payload.
BookMetadata decodeMetadataWireValue(final Map<String, Object?> json, final List<Object> blobs) {
  final cover = json['cover'] as Map<String, Object?>?;

  return BookMetadata(
    format: BookFormat.values.byName(json['format'] as String),
    title: json['title'] as String?,
    titleSort: json['titleSort'] as String?,
    authorSort: json['authorSort'] as String?,
    bookProducer: json['bookProducer'] as String?,
    publisher: json['publisher'] as String?,
    description: json['description'] as String?,
    isbn: json['isbn'] as String?,
    rights: json['rights'] as String?,
    series: json['series'] as String?,
    seriesIndex: (json['seriesIndex'] as num?)?.toDouble(),
    publishedAt: json['publishedAt'] == null ? null : DateTime.parse(json['publishedAt'] as String),
    authors: (json['authors'] as List<Object?>).cast<String>(),
    languages: (json['languages'] as List<Object?>).cast<String>(),
    subjects: (json['subjects'] as List<Object?>).cast<String>(),
    identifiers: (json['identifiers'] as Map<Object?, Object?>).cast<String, String>(),
    cover: cover == null
        ? null
        : BookCover(
            bytes: blobs[cover['blob'] as int] as Uint8List,
            type: ImageType.values.byName(cover['type'] as String),
            width: cover['width'] as int?,
            height: cover['height'] as int?,
          ),
  );
}
