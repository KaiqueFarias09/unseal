import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../header/pdf_object.dart';
import 'pdf_crypto_primitives.dart';
import 'pdf_security_handler.dart';

/// Decrypts parsed PDF objects with a [PdfSecurityHandler]: strings
/// and streams in place, indirect references left for the document
/// to resolve (each referenced object decrypts on its own key).
///
/// Edge rules follow pdf.js `crypto.js` exactly:
/// * the `/Encrypt` dictionary's own strings are never encrypted
///   (the caller never hands that dictionary here);
/// * cross-reference streams and object streams decrypt with the
///   **identity** method regardless of `/StmF` (their containers are
///   not encrypted — PDF 32000 §7.5.8.2);
/// * `/Crypt` filter arrays inside `/DecodeParms` pass through
///   untouched (make-across-the-board rare, spec-mandated).
final class PdfObjectDecryptor {
  PdfObjectDecryptor._(this._handler);

  final PdfSecurityHandler _handler;

  /// Builds a decryptor over an authenticated [handler].
  factory PdfObjectDecryptor.of(final PdfSecurityHandler handler) => PdfObjectDecryptor._(handler);

  /// Decrypts [object] for indirect object [number], generation
  /// [generation], returning a new object graph (immutably: parsed
  /// graphs stay untouched and cacheable).
  PdfObject decryptObject(final PdfObject object, final int number, final int generation) {
    if (object is PdfDictionary) {
      final entries = <String, PdfObject>{
        for (final entry in object.entries.entries)
          entry.key: decryptObject(entry.value, number, generation),
      };

      return PdfDictionary(entries);
    }
    if (object is PdfArray) {
      return PdfArray(<PdfObject>[
        for (final item in object.items) decryptObject(item, number, generation),
      ]);
    }
    if (object is PdfString) return PdfString(decryptString(object.bytes, number, generation));
    if (object is PdfStream) return decryptStream(object, number, generation);

    return object;
  }

  /// Decrypts a stream's raw payload, choosing the crypt filter per
  /// pdf.js: cross-reference streams (`/Type /XRef`) are never
  /// encrypted (PDF 32000 §7.5.8.2), so they pass through with the
  /// identity method whatever `/StmF` names; every other stream uses
  /// the `/StmF` filter.
  PdfStream decryptStream(final PdfStream stream, final int number, final int generation) {
    final type = stream.dictionary['Type'];
    final isXrefStream = type is PdfName && type.value == 'XRef';
    final method = isXrefStream ? 'Identity' : _handler.methodFor(_handler.streamFilterName);
    final plain = _decryptBytes(
      stream.bytes,
      number,
      generation,
      method,
      keyBits: _filterBits(_handler.streamFilterName, fallback: _handler.keyLength),
    );

    return PdfStream(stream.dictionary, plain);
  }

  /// Decrypts one string's bytes with the string crypt filter.
  Uint8List decryptString(final Uint8List bytes, final int number, final int generation) {
    if (bytes.isEmpty) return bytes;

    return _decryptBytes(
      bytes,
      number,
      generation,
      _handler.methodFor(_handler.stringFilterName),
      keyBits: _filterBits(_handler.stringFilterName, fallback: _handler.keyLength),
    );
  }

  Uint8List _decryptBytes(
    final Uint8List data,
    final int number,
    final int generation,
    final String method, {
    required final int keyBits,
  }) {
    switch (method) {
      case 'None':
      case 'Identity':
        return data;
      case 'V2':
        return rc4(_handler.objectKey(number, generation), data);
      case 'AESV2':
        return _aesDecrypt(_handler.objectKey(number, generation, aes: true), data);
      case 'AESV3':
        final iv = data.length >= 16 ? Uint8List.sublistView(data, 0, 16) : Uint8List(0);
        final body = data.length >= 16 ? Uint8List.sublistView(data, 16) : Uint8List(0);
        final plain = aesCbcDecryptNoPad(_handler.fileKey, iv, body);

        return _stripCbcPadding(plain);
      default:
        throw PdfException('Unsupported encryption filter method /$method.');
    }
  }

  /// The stored key length in bits for the crypt filter [name],
  /// falling back to the dictionary `/Length` for legacy handlers.
  int _filterBits(final String name, {required final int fallback}) {
    final filter = _handler.cryptFilters[name];

    return filter == null ? fallback : filter.$2;
  }

  /// AESV2 streams carry a 16-byte IV prefix and PKCS#7-style
  /// padding; both strip here (pdf.js `AESBaseCipher.decryptBlock`
  /// with `finalize`).
  Uint8List _aesDecrypt(final Uint8List key, final Uint8List data) {
    if (data.length < 32) return Uint8List(0);
    final iv = Uint8List.sublistView(data, 0, 16);
    final plain = aesCbcDecryptNoPad(key, iv, Uint8List.sublistView(data, 16));

    return _stripCbcPadding(plain);
  }

  /// Undoes the RFC 2898 padding; a block without valid padding
  /// keeps all its bytes (pdf.js treats invalid padding as none).
  static Uint8List _stripCbcPadding(final Uint8List plain) {
    if (plain.isEmpty) return plain;
    final pad = plain[plain.length - 1];
    if (pad == 0 || pad > 16 || pad > plain.length) return plain;
    for (var i = plain.length - pad; i < plain.length; i++) {
      if (plain[i] != pad) return plain;
    }

    return Uint8List.sublistView(plain, 0, plain.length - pad);
  }
}
