import 'dart:convert' as convert;

/// Decodes a wire JSON object exchanged over the worker channel.
Map<String, Object?> decodeJson(final String source) {
  return convert.jsonDecode(source) as Map<String, Object?>;
}

/// Encodes a wire JSON object exchanged over the worker channel.
String encodeJson(final Map<String, Object?> json) => convert.jsonEncode(json);
