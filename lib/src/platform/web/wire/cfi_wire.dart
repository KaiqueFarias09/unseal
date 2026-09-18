import '../../../features/cfi/epub_cfi_resolver.dart';

/// Encodes a resolved CFI [location] into a wire payload; `null`
/// (the CFI resolved nowhere) travels as JSON null. Every field is
/// written explicitly so a field added to [EpubCfiLocation] shows up
/// as a visible diff here.
Map<String, Object?>? encodeCfiLocationWire(final EpubCfiLocation? location) {
  return location == null
      ? null
      : <String, Object?>{
          'contentIndex': location.contentIndex,
          'contentPath': location.contentPath,
          'charOffset': location.charOffset,
          'endCharOffset': location.endCharOffset,
          'textExcerpt': location.textExcerpt,
          'elementTrail': List<String>.of(location.elementTrail),
        };
}

/// Decodes an [EpubCfiLocation] wire payload produced by
/// [encodeCfiLocationWire]; `null` means the CFI resolved nowhere.
EpubCfiLocation? decodeCfiLocationWire(final Map<String, Object?>? json) {
  if (json == null) return null;

  return EpubCfiLocation(
    contentIndex: json['contentIndex'] as int,
    contentPath: json['contentPath'] as String,
    charOffset: json['charOffset'] as int?,
    endCharOffset: json['endCharOffset'] as int?,
    textExcerpt: json['textExcerpt'] as String?,
    elementTrail: (json['elementTrail'] as List<Object?>?)?.cast<String>() ?? const <String>[],
  );
}
