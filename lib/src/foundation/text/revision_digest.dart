import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The one revision-digest implementation the common text contract uses.
///
/// Every digest here hashes the little-endian UTF-16 code units of a
/// canonical serialization — no BOM, no normalization — so isolated
/// surrogates already present in the input survive bit for bit. The
/// same bytes and the same hashes come out of the VM and the browser;
/// `test/support/text_identity_vectors.dart` pins both.
///
/// `textRevision` digests the snapshot text itself. `readingOrderRevision`
/// digests the compact JSON of the ordered `[[resourcePath, isHtml], …]`
/// array; the array position identifies the occurrence and duplicates
/// are preserved. `textProfileRevision` digests a text profile's
/// algorithm, options and extraction-plan revision into the profile id.
abstract final class RevisionDigest {
  const RevisionDigest._();

  /// The `sha256:`-prefixed digest of [text]'s UTF-16LE code units.
  static String textRevision(final String text) => _prefixed(utf16leBytes(text));

  /// The `sha256:`-prefixed digest over the compact JSON of the
  /// ordered `[resourcePath, isHtml]` pairs.
  ///
  /// [order] must already be in reading order; the position in the
  /// array is part of the identity, so reordering changes the digest
  /// and repeated paths stay distinct occurrences.
  static String readingOrderRevision(final List<(String, bool)> order) {
    return _prefixed(
      utf16leBytes(
        encodeCompactJson(<Object?>[
          for (final (path, isHtml) in order) <Object?>[path, isHtml],
        ]),
      ),
    );
  }

  /// The `sha256:`-prefixed digest identifying one text profile from
  /// its [algorithm], its [options] (sorted by key before hashing) and
  /// the [planRevision] of the extraction plan that produced the text.
  static String textProfileRevision({
    required final String algorithm,
    required final Map<String, String> options,
    required final String planRevision,
  }) {
    final sortedKeys = options.keys.toList()..sort();
    return _prefixed(
      utf16leBytes(
        encodeCompactJson(<String, Object?>{
          'algorithm': algorithm,
          'options': <String, Object?>{for (final key in sortedKeys) key: options[key]},
          'planRevision': planRevision,
        }),
      ),
    );
  }

  /// The little-endian UTF-16 bytes of [text]: two bytes per code unit,
  /// low byte first, no BOM and no normalization.
  static Uint8List utf16leBytes(final String text) {
    final out = Uint8List(text.length * 2);
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      out[i * 2] = unit & 0xFF;
      out[i * 2 + 1] = (unit >> 8) & 0xFF;
    }

    return out;
  }

  /// Encodes [value] — maps, lists, strings, bools, ints and null — as
  /// the compact JSON text the digests hash.
  ///
  /// This is the package's own serializer, not `jsonEncode`: the output
  /// must be identical on every platform, and platform JSON encoders
  /// are free to escape lone surrogates or line separators differently.
  /// Strings keep non-ASCII code units raw, so the digest input is the
  /// exact UTF-16 text.
  static String encodeCompactJson(final Object? value) {
    final out = StringBuffer();
    _writeJson(value, out);

    return out.toString();
  }

  /// The `sha256:` prefix plus the lowercase hex of [digest].
  static String hex(final Uint8List digest) {
    final out = StringBuffer('sha256:');
    for (final byte in digest) {
      out.write((byte >> 4).toRadixString(16));
      out.write((byte & 0xF).toRadixString(16));
    }

    return out.toString();
  }

  static String _prefixed(final Uint8List data) => hex(SHA256Digest().process(data));

  static void _writeJson(final Object? value, final StringBuffer out) {
    switch (value) {
      case null:
        out.write('null');
      case final bool value:
        out.write(value ? 'true' : 'false');
      case final int value:
        out.write(value.toString());
      case final String value:
        _writeJsonString(value, out);
      case final List<Object?> value:
        out.write('[');
        for (var i = 0; i < value.length; i++) {
          if (i > 0) out.write(',');
          _writeJson(value[i], out);
        }
        out.write(']');
      case final Map<String, Object?> value:
        out.write('{');
        var first = true;
        for (final key in value.keys.toList()..sort()) {
          if (!first) out.write(',');
          first = false;
          _writeJsonString(key, out);
          out.write(':');
          _writeJson(value[key], out);
        }
        out.write('}');
      default:
        throw ArgumentError.value(value, 'value', 'Not a compact-JSON value');
    }
  }

  static void _writeJsonString(final String value, final StringBuffer out) {
    out.write('"');
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      switch (unit) {
        case 0x22:
          out.write(r'\"');
        case 0x5C:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x09:
          out.write(r'\t');
        case 0x0A:
          out.write(r'\n');
        case 0x0C:
          out.write(r'\f');
        case 0x0D:
          out.write(r'\r');
        default:
          if (unit < 0x20) {
            out.write(r'\u');
            out.write(unit.toRadixString(16).padLeft(4, '0'));
          } else {
            out.writeCharCode(unit);
          }
      }
    }
    out.write('"');
  }
}

/// Whether [value] carries the `sha256:<64 lowercase hex>` shape the
/// digest helpers produce.
bool isSha256Revision(final String value) {
  if (!value.startsWith('sha256:')) return false;
  final hex = value.substring('sha256:'.length);
  if (hex.length != 64) return false;
  for (var i = 0; i < hex.length; i++) {
    final unit = hex.codeUnitAt(i);
    final isDigit = unit >= 0x30 && unit <= 0x39;
    final isLowerHex = unit >= 0x61 && unit <= 0x66;
    if (!isDigit && !isLowerHex) return false;
  }

  return true;
}

/// Decodes a `sha256:`-prefixed revision back to its raw digest bytes,
/// for tests and comparators; null when the shape is wrong.
Uint8List? sha256RevisionBytes(final String value) {
  if (!isSha256Revision(value)) return null;
  final hex = value.substring('sha256:'.length);
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }

  return out;
}
