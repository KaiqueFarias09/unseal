import 'dart:typed_data';

import 'package:e_livre/src/foundation/entities/entities.dart';

/// Encodes navigation into its wire-map representation.
Map<String, Object?> encodeNavigationWireValue(final Navigation navigation) => <String, Object?>{
  'title': navigation.title,
  'points': <Object?>[for (final point in navigation.navPoints) _encodeNavPoint(point)],
};

Map<String, Object?> _encodeNavPoint(final NavPoint point) => <String, Object?>{
  'classAttribute': point.classAttribute,
  'id': point.id,
  'playOrder': point.playOrder,
  'label': point.label,
  'content': point.content,
  'subNavPoints': <Object?>[for (final sub in point.subNavPoints) _encodeNavPoint(sub)],
};

/// Decodes navigation from its wire-map representation.
Navigation decodeNavigationWireValue(final Map<String, Object?> json) => Navigation(
  title: json['title'] as String,
  navPoints: <NavPoint>[
    for (final point in json['points'] as List<Object?>)
      _decodeNavPoint(point as Map<String, Object?>),
  ],
);

NavPoint _decodeNavPoint(final Map<String, Object?> json) => NavPoint(
  classAttribute: json['classAttribute'] as String,
  id: json['id'] as String,
  playOrder: json['playOrder'] as String,
  label: json['label'] as String,
  content: json['content'] as String,
  subNavPoints: <NavPoint>[
    for (final sub in json['subNavPoints'] as List<Object?>)
      _decodeNavPoint(sub as Map<String, Object?>),
  ],
);

/// Encodes categorized book files, pushing their contents into [blobs].
Map<String, Object?> encodeFilesWireValue(final Files files, final List<Object> blobs) =>
    <String, Object?>{
      'html': <Object?>[for (final file in files.html) _encodeTextFile(file, blobs)],
      'css': <Object?>[for (final file in files.css) _encodeTextFile(file, blobs)],
      'images': <Object?>[for (final file in files.images) encodeBinaryFileWireValue(file, blobs)],
      'fonts': <Object?>[for (final file in files.fonts) encodeBinaryFileWireValue(file, blobs)],
      'others': <Object?>[for (final file in files.others) encodeBinaryFileWireValue(file, blobs)],
    };

/// Decodes categorized book files using content from [blobs].
Files decodeFilesWireValue(final Map<String, Object?> json, final List<Object> blobs) => Files(
  html: _decodeTextFiles(json['html'] as List<Object?>, blobs),
  css: _decodeTextFiles(json['css'] as List<Object?>, blobs),
  images: _decodeBinaryFiles(json['images'] as List<Object?>, blobs),
  fonts: _decodeBinaryFiles(json['fonts'] as List<Object?>, blobs),
  others: _decodeBinaryFiles(json['others'] as List<Object?>, blobs),
);

Map<String, Object?> _encodeTextFile(final TextFile file, final List<Object> blobs) =>
    <String, Object?>{
      'path': file.path,
      'name': file.name,
      'type': file.type,
      'blob': pushWireBlob(blobs, file.content),
    };

TextFile _decodeTextFile(final Map<String, Object?> json, final List<Object> blobs) => TextFile(
  path: json['path'] as String,
  name: json['name'] as String,
  type: json['type'] as String,
  content: blobs[json['blob'] as int] as String,
);

List<TextFile> _decodeTextFiles(final List<Object?> json, final List<Object> blobs) => <TextFile>[
  for (final file in json) _decodeTextFile(file as Map<String, Object?>, blobs),
];

/// Encodes a binary file, pushing its contents into [blobs].
Map<String, Object?> encodeBinaryFileWireValue(final BinaryFile file, final List<Object> blobs) =>
    <String, Object?>{
      'path': file.path,
      'name': file.name,
      'type': file.type,
      'blob': pushWireBlob(blobs, file.content),
    };

/// Decodes a binary file using content from [blobs].
BinaryFile decodeBinaryFileWireValue(final Map<String, Object?>? json, final List<Object> blobs) =>
    json == null
    ? BinaryFile.empty()
    : BinaryFile(
        path: json['path'] as String,
        name: json['name'] as String,
        type: json['type'] as String,
        content: blobs[json['blob'] as int] as Uint8List,
      );

List<BinaryFile> _decodeBinaryFiles(final List<Object?> json, final List<Object> blobs) =>
    <BinaryFile>[
      for (final file in json) decodeBinaryFileWireValue(file as Map<String, Object?>, blobs),
    ];

/// Decodes the archive inventory stored in a book payload.
List<ArchiveEntry> decodeArchiveEntriesWireValue(final List<Object?> json) => <ArchiveEntry>[
  for (final entry in json)
    ArchiveEntry(
      path: (entry as Map<String, Object?>)['path'] as String,
      size: entry['size'] as int,
    ),
];

/// Appends a blob payload and returns the index referenced by the JSON map.
int pushWireBlob(final List<Object> blobs, final Object payload) {
  blobs.add(payload);

  return blobs.length - 1;
}
