// pypdf _encryption.py AlgV5 (algorithm 2.A) — a `part of`
// pdf_security_handler.dart; the split keeps the R5-R6 hashing (which
// reads the handler's private fields) beside the handler itself.
part of 'pdf_security_handler.dart';

/// Algorithm 2.A: the revision 5-6 hardened key derivation
/// (PDF 32000-2 §7.6.4.3.4; pypdf `_encryption.py` `AlgV5`, pdf.js
/// `PDF17`/`PDF20`).
///
/// Revision 5 hashes once with SHA-256; revision 6 runs the
/// iterated AES-CBC-mixed loop (2.B) whose exit condition reads the
/// last encrypted byte — repeated until it drops below the iteration
/// count minus 32, at most 64 plus a final validation round.
final class PdfSecurityAlgorithm2A {
  const PdfSecurityAlgorithm2A._();

  /// Authenticates the user password (steps 1, 4 of the algorithm)
  /// and returns the 32-byte file key decrypted from `/UE`, null on
  /// mismatch.
  static Uint8List? userKey(final PdfSecurityHandler handler, final Uint8List password) {
    final truncated = _truncate(password);
    final u = handler.userValue;
    final validation = u.length >= 40 ? Uint8List.sublistView(u, 32, 40) : Uint8List(0);
    final keySalt = u.length >= 48 ? Uint8List.sublistView(u, 40, 48) : Uint8List(0);
    if (u.length < 32) return null;
    final check = _hash(handler.revision, truncated, validation, Uint8List(0));
    for (var i = 0; i < 32; i++) {
      if (check[i] != u[i]) return null;
    }

    final intermediate = _hash(handler.revision, truncated, keySalt, Uint8List(0));
    final ue = handler.userEncryption;
    if (ue.length < 32) return null;

    return Uint8List.sublistView(aesCbcDecryptNoPad(intermediate, Uint8List(16), ue), 0, 32);
  }

  /// Authenticates the owner password (steps 1, 3 of the algorithm)
  /// and returns the 32-byte file key decrypted from `/OE`, null on
  /// mismatch.
  static Uint8List? ownerKey(final PdfSecurityHandler handler, final Uint8List password) {
    final truncated = _truncate(password);
    final o = handler.ownerValue;
    final u = handler.userValue;
    if (o.length < 48 || u.length < 48) return null;
    final ownerValidation = Uint8List.sublistView(o, 32, 40);
    final ownerKeySalt = Uint8List.sublistView(o, 40, 48);
    final u48 = Uint8List.sublistView(u, 0, 48);
    final check = _hash(handler.revision, truncated, ownerValidation, u48);
    for (var i = 0; i < 32; i++) {
      if (check[i] != o[i]) return null;
    }

    final intermediate = _hash(handler.revision, truncated, ownerKeySalt, u48);
    final oe = handler.ownerEncryption;
    if (oe.length < 32) return null;

    return Uint8List.sublistView(aesCbcDecryptNoPad(intermediate, Uint8List(16), oe), 0, 32);
  }

  /// Verifies the decrypted `/Perms` block against the `/P` flags
  /// (step 5): bytes 0-3 are the little-endian permissions, bytes 8
  /// flag metadata encryption and bytes 9-11 read `adb`.
  static bool verifyPerms(final PdfSecurityHandler handler, final Uint8List fileKey) {
    final perms = handler.permsValue;
    if (perms.length != 16) return false;
    final plain = aesEcbDecrypt(fileKey, perms);
    final p = handler.permissions;
    if (plain[0] != (p & 0xFF) ||
        plain[1] != ((p >> 8) & 0xFF) ||
        plain[2] != ((p >> 16) & 0xFF) ||
        plain[3] != ((p >> 24) & 0xFF)) {
      return false;
    }
    if (plain[8] != (handler.encryptMetadata ? 0x54 : 0x46)) return false;

    return plain[9] == 0x61 && plain[10] == 0x64 && plain[11] == 0x62;
  }

  /// The password hash: one SHA-256 round for revision 5, the
  /// hardened algorithm 2.B loop for revision 6.
  static Uint8List _hash(
    final int revision,
    final Uint8List password,
    final Uint8List salt,
    final Uint8List uData,
  ) {
    if (revision < 6) return sha256(_concat(<Uint8List>[password, salt, uData]));

    return _hashR6(password, salt, uData);
  }

  /// Algorithm 2.B: the revision 6 iterated hash (pdf.js `PDF20
  /// ._hash`, qpdf `QPDF_encryption.cc` — the modulo-3 selector
  /// exploits 256 ≡ 1 mod 3, so only the first 16 bytes' sum feeds
  /// it).
  static Uint8List _hashR6(final Uint8List password, final Uint8List salt, final Uint8List uData) {
    var k = sha256(_concat(<Uint8List>[password, salt, uData]));
    var e = Uint8List(0);
    var round = 0;
    var stop = false;
    while (!stop) {
      round++;
      final combined = _concat(<Uint8List>[password, k, uData]);
      final repeated = Uint8List(combined.length * 64);
      for (var pass = 0; pass < 64; pass++) {
        repeated.setRange(pass * combined.length, (pass + 1) * combined.length, combined);
      }
      // AES-128-CBC with no padding: key = k[0..16], iv = k[16..32].
      e = aes128CbcEncryptNoPad(
        Uint8List.sublistView(k, 0, 16),
        Uint8List.sublistView(k, 16, 32),
        repeated,
      );
      var modulo = 0;
      for (var i = 0; i < 16; i++) {
        modulo += e[i];
      }
      modulo %= 3;
      k = switch (modulo) {
        0 => sha256(e),
        1 => sha384(e),
        _ => sha512(e),
      };
      // The exit check: past round 64, stop when the last byte of e
      // compares below round - 32.
      stop = round >= 64 && e[e.length - 1] <= round - 32;
    }

    return Uint8List.sublistView(k, 0, 32);
  }

  /// Truncates the UTF-8 password to the algorithm's 127-byte cap.
  static Uint8List _truncate(final Uint8List password) =>
      password.length <= 127 ? password : Uint8List.sublistView(password, 0, 127);

  static Uint8List _concat(final List<Uint8List> parts) {
    final out = BytesBuilder(copy: false);
    for (final part in parts) {
      out.add(part);
    }

    return out.toBytes();
  }
}
