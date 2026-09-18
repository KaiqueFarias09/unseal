/// The symmetric and hash primitives the standard security handler needs.
///
/// AES (all key sizes), SHA-256/384/512, HMAC and MD5 come from
/// pointycastle, the package's one approved crypto dependency — pure Dart,
/// so the same code runs on the VM, in the browser and inside the web
/// worker. RC4 is implemented here (~20 lines of state machine) because
/// PDF uses it as a whole-buffer primitive with no streaming, key
/// schedule reuse or error surface; the local form keeps the security
/// handler's loops single-expression simple.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ---------------------------------------------------------------------------
// Hashes
// ---------------------------------------------------------------------------

/// The MD5 digest of [data] (PDF algorithms 2-7).
Uint8List md5(final Uint8List data) => MD5Digest().process(data);

/// The SHA-256 digest of [data] (PDF 32000 §7.6.4.3.4 algorithm 2.A).
Uint8List sha256(final Uint8List data) => SHA256Digest().process(data);

/// The SHA-384 digest of [data] (algorithm 2.B's middle rung).
Uint8List sha384(final Uint8List data) => SHA384Digest().process(data);

/// The SHA-512 digest of [data] (algorithm 2.B's top rung).
Uint8List sha512(final Uint8List data) => SHA512Digest().process(data);

// ---------------------------------------------------------------------------
// RC4
// ---------------------------------------------------------------------------

/// Encrypts or decrypts [data] with RC4 under [key] (the cipher is
/// symmetric, one routine serves both).
Uint8List rc4(final Uint8List key, final Uint8List data) {
  // KSA: the 256-byte state permutation.
  final state = List<int>.generate(256, (final i) => i);
  var j = 0;
  for (var i = 0; i < 256; i++) {
    j = (j + state[i] + key[i % key.length]) & 0xFF;
    final swap = state[i];
    state[i] = state[j];
    state[j] = swap;
  }

  // PRGA: XOR the stream in place.
  final out = Uint8List(data.length);
  var a = 0;
  j = 0;
  for (var i = 0; i < data.length; i++) {
    a = (a + 1) & 0xFF;
    j = (j + state[a]) & 0xFF;
    final swap = state[a];
    state[a] = state[j];
    state[j] = swap;
    out[i] = data[i] ^ state[(state[a] + state[j]) & 0xFF];
  }

  return out;
}

// ---------------------------------------------------------------------------
// AES-CBC / AES-ECB
// ---------------------------------------------------------------------------

/// Decrypts [ciphertext] with AES-CBC under [key] and [iv], no padding
/// removal: lengths stay multiples of 16 and trailing padding bytes are
/// meaningful data for `/UE`, `/OE` and algorithm 2.B's KDF.
Uint8List aesCbcDecryptNoPad(final Uint8List key, final Uint8List iv, final Uint8List ciphertext) {
  final blocks = ciphertext.length ~/ 16;
  final out = Uint8List(blocks * 16);
  final cipher = CBCBlockCipher(AESEngine())..init(false, ParametersWithIV(KeyParameter(key), iv));
  for (var block = 0; block < blocks; block++) {
    cipher.processBlock(ciphertext, block * 16, out, block * 16);
  }

  return out;
}

/// Encrypts [plaintext] with AES-CBC under [key] and [iv], no padding
/// added ([plaintext] must already be a multiple of 16).
Uint8List aesCbcEncryptNoPad(final Uint8List key, final Uint8List iv, final Uint8List plaintext) {
  final blocks = plaintext.length ~/ 16;
  final out = Uint8List(blocks * 16);
  final cipher = CBCBlockCipher(AESEngine())..init(true, ParametersWithIV(KeyParameter(key), iv));
  for (var block = 0; block < blocks; block++) {
    cipher.processBlock(plaintext, block * 16, out, block * 16);
  }

  return out;
}

/// Decrypts one or more 16-byte blocks with AES-ECB under [key] — the
/// `/Perms` check of R6 (PDF 32000 §7.6.4.3.4 step 5).
Uint8List aesEcbDecrypt(final Uint8List key, final Uint8List data) {
  final blocks = data.length ~/ 16;
  final out = Uint8List(blocks * 16);
  final cipher = ECBBlockCipher(AESEngine())..init(false, KeyParameter(key));
  for (var block = 0; block < blocks; block++) {
    cipher.processBlock(data, block * 16, out, block * 16);
  }

  return out;
}

/// Encrypts [plaintext] (a whole multiple of 16 bytes) with AES-128-CBC
/// under [key] and [iv] — algorithm 2.B's mixing step.
Uint8List aes128CbcEncryptNoPad(
  final Uint8List key,
  final Uint8List iv,
  final Uint8List plaintext,
) {
  return aesCbcEncryptNoPad(key, iv, plaintext);
}
