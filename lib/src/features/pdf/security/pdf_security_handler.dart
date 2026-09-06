/// The standard PDF security handler (revisions R2-R6).
///
/// A `library` directive only to attach the algorithm 2.A `part`
/// file; the doc comment on [PdfSecurityHandler] carries the detail.
library;

import 'dart:convert' as convert;
import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../header/pdf_object.dart';
import 'pdf_crypto_primitives.dart';

part 'pdf_security_algorithm_2a.dart';

/// The PDF 32000-1:2008 §7.6.3 padding string: a 32-byte fixed value
/// used to pad or truncate passwords shorter/longer than 32 bytes.
const List<int> _standardPadding = <int>[
  0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, //
  0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
  0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80,
  0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
];

/// Authenticates a password against an encryption dictionary and,
/// on success, hands out the per-object decryption keys.
///
/// A behavioral re-expression of pypdf's `_encryption.py` (`AlgV4`,
/// `AlgV5`) cross-checked against pdf.js `src/core/crypto.js`
/// (`CipherTransformFactory`): revisions R2-R4 derive the file key
/// with MD5 (algorithms 2-7), R5-R6 with the SHA-2 family
/// (algorithm 2.A, part of [PdfSecurityAlgorithm2A]).
///
/// Supported `/V` values: 1-2 (RC4, 40-bit), 4 (crypt filters,
/// `/V2` RC4 or `/AESV2`), 5 (`/AESV3`, R5-R6). Anything else —
/// including public-key handlers (`/V` 4 with a non-standard filter
/// method, `/V` 6) — throws a [PdfException] naming the filter.
class PdfSecurityHandler {
  /// Builds the handler over a parsed `/Encrypt` dictionary whose
  /// string values are already decrypted (the dictionary's own
  /// strings never are) — exactly what [PdfSecurityHandler.of] feeds
  /// it. [fileId] is the first element of the trailer's `/ID` array
  /// (empty for the broken files that omit it).
  PdfSecurityHandler._({
    required this.version,
    required this.revision,
    required this.keyLength,
    required this.ownerValue,
    required this.userValue,
    required this.permissions,
    required this.encryptMetadata,
    required this.fileId,
    required this.ownerEncryption,
    required this.userEncryption,
    required this.permsValue,
    required this.streamFilterName,
    required this.stringFilterName,
    required this.cryptFilters,
  });

  /// Reads an `/Encrypt` dictionary (its strings still as parsed)
  /// plus the trailer `/ID`, resolving indirect entries through
  /// [resolve]; throws [PdfException] when the dictionary is
  /// structurally unusable or the handler is unsupported.
  static PdfSecurityHandler of(
    final PdfDictionary encrypt,
    final PdfObject? idObject,
    final PdfObject? Function(PdfObject? object) resolve,
  ) {
    final filter = resolve(encrypt['Filter']);
    if (filter is! PdfName || filter.value != 'Standard') {
      throw const PdfException(
        'Unsupported encryption filter: only the /Standard security '
        'handler is supported.',
      );
    }

    final version = _intValue(resolve(encrypt['V']));
    final revision = _intValue(resolve(encrypt['R']));
    if (revision == null || revision < 2 || revision > 6) {
      throw const PdfException('Unsupported encryption revision /R.');
    }
    if (version == null || version < 1 || version > 5) {
      throw const PdfException('Unsupported encryption version /V.');
    }

    var keyLength = _intValue(resolve(encrypt['Length']));
    if (keyLength == null || keyLength < 40 || keyLength % 8 != 0) {
      // pdf.js recovers: some writers state bits as bytes, some omit
      // the entry entirely (40-bit for /V 1-3, the filter's Length for
      // /V 4).
      if (version <= 3) {
        keyLength = 40;
      } else {
        final filters = _cryptFilters(encrypt, resolve);
        final streamName = _nameValue(resolve(encrypt['StmF'])) ?? 'Identity';
        final defaultLength = filters[streamName]?.$2 ?? 128;
        keyLength = defaultLength < 40 ? defaultLength * 8 : defaultLength;
      }
    }

    final ownerValue = _bytesOf(resolve(encrypt['O']));
    final userValue = _bytesOf(resolve(encrypt['U']));
    final permissions = _intValue(resolve(encrypt['P'])) ?? 0;
    final metadataFlag = resolve(encrypt['EncryptMetadata']);
    final encryptMetadata = metadataFlag is! PdfBool || metadataFlag.value;

    final id1 = _fileIdOf(idObject, resolve);

    return PdfSecurityHandler._(
      version: version,
      revision: revision,
      keyLength: keyLength,
      ownerValue: ownerValue,
      userValue: userValue,
      permissions: permissions,
      encryptMetadata: encryptMetadata,
      fileId: id1,
      ownerEncryption: _bytesOf(resolve(encrypt['OE'])),
      userEncryption: _bytesOf(resolve(encrypt['UE'])),
      permsValue: _bytesOf(resolve(encrypt['Perms'])),
      streamFilterName: _nameValue(resolve(encrypt['StmF'])) ?? 'Identity',
      stringFilterName: _nameValue(resolve(encrypt['StrF'])) ?? 'Identity',
      cryptFilters: _cryptFilters(encrypt, resolve),
    );
  }

  /// The `/V` version of the handler (1, 2, 4 or 5).
  final int version;

  /// The `/R` revision of the handler (2-6).
  final int revision;

  /// The file encryption key length in **bits**.
  final int keyLength;

  /// The `/O` owner entry bytes.
  final Uint8List ownerValue;

  /// The `/U` user entry bytes.
  final Uint8List userValue;

  /// The `/P` permission flags (bits set to 1 are allowed).
  final int permissions;

  /// Whether the document metadata streams are encrypted
  /// (`/EncryptMetadata`, default true).
  final bool encryptMetadata;

  /// The first `/ID` string from the trailer (empty when missing).
  final Uint8List fileId;

  /// The `/OE` value (revision 5+): the owner's encrypted file key.
  final Uint8List ownerEncryption;

  /// The `/UE` value (revision 5+): the user's encrypted file key.
  final Uint8List userEncryption;

  /// The `/Perms` value (revision 6): the encrypted permissions block.
  final Uint8List permsValue;

  /// The default crypt filter for streams (`/StmF`).
  final String streamFilterName;

  /// The default crypt filter for strings (`/StrF`).
  final String stringFilterName;

  /// The `/CF` name → (method, Length-in-bits) table.
  final Map<String, (String, int)> cryptFilters;

  /// The authenticated file encryption key, null when no password
  /// given by [authenticate] succeeded.
  Uint8List? _key;

  /// Whether the last [authenticate] call matched the owner
  /// password (as opposed to the user password).
  bool _isOwnerAuthenticated = false;

  /// Whether the last [authenticate] call matched the owner password.
  bool get isOwnerAuthenticated => _isOwnerAuthenticated;

  /// Whether the successful authentication went through a non-empty
  /// password — the owner-password-only case (an empty user password
  /// open leaves this false).
  bool get requiresNonEmptyPassword => _isOwnerAuthenticated && _passwordUsed.isNotEmpty;

  /// The password the last successful [authenticate] ran with (raw
  /// bytes, after padding); empty for a plain user-password open.
  Uint8List _passwordUsed = Uint8List(0);

  /// Authenticates [password] (user first, then owner) and stores
  /// the derived file key. Returns true when authentication
  /// succeeded.
  bool authenticate(final String password) {
    _isOwnerAuthenticated = false;
    _passwordUsed = _passwordBytes(password);
    final userKey = revision >= 5
        ? PdfSecurityAlgorithm2A.userKey(this, _passwordUsed)
        : _userKeyR2R4(_passwordUsed);
    if (userKey != null) {
      _key = userKey;

      return true;
    }
    if (_passwordUsed.isEmpty) return false;

    final ownerKey = revision >= 5
        ? PdfSecurityAlgorithm2A.ownerKey(this, _passwordUsed)
        : _ownerKeyR2R4(_passwordUsed);
    if (ownerKey == null) return false;

    _key = ownerKey;
    _isOwnerAuthenticated = true;

    return true;
  }

  /// Whether authentication succeeded at all.
  bool get isAuthenticated => _key != null;

  /// The file encryption key; valid only after a successful
  /// [authenticate].
  Uint8List get fileKey => _key!;

  /// Builds the per-object decryption key for object [number],
  /// generation [generation]: `MD5(fileKey + num(3 LE) + gen(2 LE)
  /// + [AES marker])` truncated to `min(keyBytes + 5, 16)` for
  /// revisions below 5; the raw file key for revision 5+.
  Uint8List objectKey(final int number, final int generation, {final bool aes = false}) {
    if (revision >= 5) return _key!;

    final input = BytesBuilder(copy: false)
      ..add(_key!)
      ..add(Uint8List(5));
    final raw = input.toBytes();
    raw[_key!.length] = number & 0xFF;
    raw[_key!.length + 1] = (number >> 8) & 0xFF;
    raw[_key!.length + 2] = (number >> 16) & 0xFF;
    raw[_key!.length + 3] = generation & 0xFF;
    raw[_key!.length + 4] = (generation >> 8) & 0xFF;

    var seed = raw;
    if (aes) {
      final withMarker = BytesBuilder(copy: false)
        ..add(raw)
        ..addByte(0x73)
        ..addByte(0x41)
        ..addByte(0x6C)
        ..addByte(0x54);
      seed = withMarker.toBytes();
    }
    final digest = md5(seed);
    final length = (_key!.length + 5).clamp(0, 16);

    return Uint8List.sublistView(digest, 0, length);
  }

  /// The crypt filter method for [name] (`/V2`, `/AESV2`, `/AESV3`,
  /// `/None` or the identity), defaulted per pdf.js: absent `/StmF`
  /// and `/StrF` mean the identity filter (no encryption).
  String methodFor(final String name) {
    if (name == 'Identity' || !cryptFilters.containsKey(name)) {
      return version >= 4 ? 'None' : _legacyMethod;
    }

    return cryptFilters[name]!.$1;
  }

  /// The legacy (revision < 4) whole-document method: RC4 under V1-2.
  String get _legacyMethod => 'V2';

  /// Algorithm 2: the R2-R4 file encryption key from a padded
  /// password (pypdf `_encryption.py` `AlgV4.compute_key`).
  Uint8List _computeKeyR2R4(final Uint8List padded) {
    final input = BytesBuilder(copy: false)
      ..add(padded)
      ..add(ownerValue)
      ..add(Uint8List(4))
      ..add(fileId);
    final packed = input.toBytes();
    packed[padded.length + ownerValue.length] = permissions & 0xFF;
    packed[padded.length + ownerValue.length + 1] = (permissions >> 8) & 0xFF;
    packed[padded.length + ownerValue.length + 2] = (permissions >> 16) & 0xFF;
    packed[padded.length + ownerValue.length + 3] = (permissions >> 24) & 0xFF;
    if (revision >= 4 && !encryptMetadata) {
      packed[packed.length - 1] = 0xFF;
      packed[packed.length - 2] = 0xFF;
      packed[packed.length - 3] = 0xFF;
      packed[packed.length - 4] = 0xFF;
    }

    var digest = md5(packed);
    if (revision >= 3) {
      final keyBytes = keyLength ~/ 8;
      for (var i = 0; i < 50; i++) {
        digest = md5(Uint8List.sublistView(digest, 0, keyBytes));
      }
    }

    return Uint8List.sublistView(digest, 0, keyLength ~/ 8);
  }

  /// Algorithm 6: authenticate the user password (R2-R4) and return
  /// the file key, null on mismatch.
  Uint8List? _userKeyR2R4(final Uint8List password) {
    final Uint8List key = _computeKeyR2R4(_pad(password));
    if (revision <= 2) {
      final expected = rc4(key, Uint8List.fromList(_standardPadding));
      if (_bytesEqual(expected, userValue)) return key;

      return null;
    }

    final input = BytesBuilder(copy: false)
      ..add(Uint8List.fromList(_standardPadding))
      ..add(fileId);
    var check = rc4(key, md5(input.toBytes()));
    for (var i = 1; i <= 19; i++) {
      check = rc4(_xorKey(key, i), check);
    }
    final expected = Uint8List.sublistView(userValue, 0, 16);
    if (check.length >= 16 && _bytesEqual(Uint8List.sublistView(check, 0, 16), expected)) {
      return key;
    }

    return null;
  }

  /// Algorithm 7: authenticate the owner password (R2-R4) by
  /// recovering the user password from `/O`, then re-running
  /// algorithm 6 (pypdf `AlgV4.verify_owner_password`). Step (a)
  /// hashes the password alone — algorithm 3, not algorithm 2: no
  /// `/O`, `/P` or `/ID` mixing here.
  Uint8List? _ownerKeyR2R4(final Uint8List password) {
    var digest = md5(_pad(password));
    if (revision >= 3) {
      for (var i = 0; i < 50; i++) {
        digest = md5(digest);
      }
    }
    final Uint8List rc4Key = Uint8List.sublistView(digest, 0, keyLength ~/ 8);
    Uint8List recovered;
    if (revision <= 2) {
      recovered = rc4(rc4Key, ownerValue);
    } else {
      recovered = ownerValue;
      for (var i = 19; i >= 0; i--) {
        recovered = rc4(_xorKey(rc4Key, i), recovered);
      }
    }

    return _userKeyR2R4(recovered);
  }

  /// The key XORed byte-wise with [value] (algorithms 5/7 stepping).
  static Uint8List _xorKey(final Uint8List key, final int value) {
    final out = Uint8List(key.length);
    for (var i = 0; i < key.length; i++) {
      out[i] = key[i] ^ value;
    }

    return out;
  }

  /// Pads or truncates [password] to exactly 32 bytes (algorithm 2
  /// step a).
  static Uint8List _pad(final Uint8List password) {
    final out = Uint8List(32);
    final take = password.length < 32 ? password.length : 32;
    out.setRange(0, take, password);
    out.setRange(take, 32, _standardPadding);

    return out;
  }

  /// Encodes [password]: revisions below 5 use PDFDocEncoding —
  /// Latin-1 is the near-exact, lossless-for-ASCII choice every
  /// extractor makes — while revision 5+ mandates UTF-8.
  Uint8List _passwordBytes(final String password) {
    if (revision >= 5) return Uint8List.fromList(convert.utf8.encode(password));

    return Uint8List.fromList(password.codeUnits.map((final c) => c & 0xFF).toList());
  }

  /// The trailer `/ID` first element (empty when the array is
  /// missing — broken files still decrypt because qpdf and pdf.js
  /// treat the missing entry as empty bytes for R2-R4 hashing).
  static Uint8List _fileIdOf(
    final PdfObject? idObject,
    final PdfObject? Function(PdfObject? object) resolve,
  ) {
    final array = resolve(idObject);
    if (array is PdfArray && array.items.isNotEmpty) {
      return _bytesOf(resolve(array.items.first));
    }
    if (array is PdfString) return array.bytes;

    return Uint8List(0);
  }

  /// The `/CF` table: name → (CFM method, Length in bits).
  static Map<String, (String, int)> _cryptFilters(
    final PdfDictionary encrypt,
    final PdfObject? Function(PdfObject? object) resolve,
  ) {
    final table = <String, (String, int)>{};
    final cf = resolve(encrypt['CF']);
    if (cf is! PdfDictionary) return table;
    for (final entry in cf.entries.entries) {
      final spec = resolve(entry.value);
      if (spec is! PdfDictionary) continue;
      final method = _nameValue(resolve(spec['CFM'])) ?? 'None';
      final bits = _intValue(resolve(spec['Length'])) ?? 40;
      table[entry.key] = (method, bits);
    }

    return table;
  }

  static int? _intValue(final PdfObject? object) => object is PdfNumber ? object.intValue : null;

  static String? _nameValue(final PdfObject? object) => object is PdfName ? object.value : null;

  static Uint8List _bytesOf(final PdfObject? object) =>
      object is PdfString ? object.bytes : Uint8List(0);

  static bool _bytesEqual(final Uint8List a, final Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }

    return true;
  }
}
