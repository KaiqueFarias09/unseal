/// Incremental BLAKE2sp (RFC 7693 parallel hash, 32-byte output) for the
/// RAR 5 extra-area data hash.
///
/// A direct port of the reference C implementation (`blake2s-ref.c` and
/// `blake2sp-ref.c` of the BLAKE2 package, revision
/// `ed1974ea83433eba7b2d95c5dcd9ac33cb847913`, tri-licensed CC0 /
/// OpenSSL / Apache-2.0 — see `THIRD_PARTY_NOTICES.md`): eight BLAKE2s
/// leaves (fanout 8, depth 2, node offsets 0..7, leaf 7 and the root
/// carrying the last-node flag) fed interleaved 64-byte blocks, and a
/// root instance hashing the eight leaf digests. The unkeyed 32-byte
/// parameter blocks are built the same way: state = IV XOR parameter
/// words.
///
/// All arithmetic is masked to 32 bits and state words live in
/// `Uint32List`, so the VM and compiled JavaScript agree bit for bit.
/// The state is fixed size (nine BLAKE2s states plus one 512-byte tail
/// buffer); `add` consumes its input through bounded views and copies at
/// most 512 tail bytes, so hashing never duplicates the payload.
library;

import 'dart:typed_data';

/// Byte size of one BLAKE2s block.
const int _blockBytes = 64;

/// Leaf count of the BLAKE2sp tree; one interleaved span is
/// [_lanes] * [_blockBytes] = 512 bytes.
const int _lanes = 8;

const int _spanBytes = _lanes * _blockBytes;

/// Digest byte length RAR 5 declares for hash type 0.
const int rar5Blake2spDigestBytes = 32;

const List<int> _iv = [
  0x6A09E667,
  0xBB67AE85,
  0x3C6EF372,
  0xA54FF53A,
  0x510E527F,
  0x9B05688C,
  0x1F83D9AB,
  0x5BE0CD19,
];

const List<List<int>> _sigma = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
  [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
  [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
  [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
  [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
  [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
  [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
  [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
  [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
];

/// One BLAKE2s compression instance (leaf or root).
final class _Blake2s {
  /// Builds the unkeyed instance from its parameter words: the state is
  /// the IV XOR the parameter block's leading little-endian words.
  _Blake2s({
    required final int fanout,
    required final int depth,
    required final int nodeOffset,
    required final int nodeDepth,
    required final bool lastNode,
  }) : _lastNode = lastNode {
    // State = IV XOR the parameter block's leading words; salt and
    // personalization are zero, so words 4..7 keep the plain IV.
    for (var i = 0; i < 8; i++) {
      _h[i] = _iv[i];
    }
    // Parameter word 0: digest(1B) | key(1B) | fanout(1B) | depth(1B),
    // all little-endian — digest 32, key 0.
    _h[0] ^= 32 | (fanout << 16) | (depth << 24);
    // Word 1: leaf length, 0 for the unkeyed RAR 5 use.
    // Word 2: node offset.
    _h[2] ^= nodeOffset;
    // Word 3: xof(2B) | node depth<<16 | inner length<<24 (32).
    _h[3] ^= (nodeDepth << 16) | (32 << 24);
  }

  final Uint32List _h = Uint32List(8);
  final Uint32List _v = Uint32List(16);
  final Uint32List _m = Uint32List(16);
  final Uint8List _buf = Uint8List(_blockBytes);
  int _buflen = 0;
  int _t0 = 0;
  int _t1 = 0;
  int _f0 = 0;
  int _f1 = 0;
  final bool _lastNode;
  bool _done = false;

  /// Consumes [input[start..end)) — the port of `blake2s_update`: fill
  /// the buffer, compress it, compress whole direct blocks while more
  /// than one block remains (the last block is never compressed here),
  /// and keep the tail.
  void update(final Uint8List input, final int start, final int end) {
    var position = start;
    var remaining = end - start;
    if (remaining <= 0) return;
    final fill = _blockBytes - _buflen;
    if (remaining > fill) {
      _buf.setRange(_buflen, _blockBytes, input, position);
      _incrementCounter(_blockBytes);
      _compress(_buf);
      position += fill;
      remaining -= fill;
      while (remaining > _blockBytes) {
        _incrementCounter(_blockBytes);
        _compressAt(input, position);
        position += _blockBytes;
        remaining -= _blockBytes;
      }
      _buflen = 0;
    }
    _buf.setRange(_buflen, _buflen + remaining, input, position);
    _buflen += remaining;
  }

  /// Finishes the stream into [output[offset..offset+32]) — the port of
  /// `blake2s_final`: charge the tail to the counter, raise the final
  /// block (and last-node) flags, zero-pad, compress, emit little-endian.
  void finish(final Uint8List output, final int offset) {
    if (_done) {
      throw StateError('BLAKE2s instance already finished.');
    }
    _done = true;
    _incrementCounter(_buflen);
    if (_lastNode) _f1 = 0xFFFFFFFF;
    _f0 = 0xFFFFFFFF;
    for (var i = _buflen; i < _blockBytes; i++) {
      _buf[i] = 0;
    }
    _compress(_buf);
    for (var i = 0; i < 8; i++) {
      final word = _h[i];
      output[offset + i * 4] = word & 0xFF;
      output[offset + i * 4 + 1] = (word >> 8) & 0xFF;
      output[offset + i * 4 + 2] = (word >> 16) & 0xFF;
      output[offset + i * 4 + 3] = (word >> 24) & 0xFF;
    }
  }

  void _incrementCounter(final int inc) {
    _t0 += inc;
    if (_t0 >= 0x100000000) {
      _t0 -= 0x100000000;
      _t1 += 1;
    }
  }

  void _compress(final Uint8List block) => _compressAt(block, 0);

  void _compressAt(final Uint8List block, final int start) {
    final m = _m;
    for (var i = 0; i < 16; i++) {
      final o = start + i * 4;
      m[i] = block[o] | (block[o + 1] << 8) | (block[o + 2] << 16) | (block[o + 3] << 24);
    }
    final v = _v;
    for (var i = 0; i < 8; i++) {
      v[i] = _h[i];
    }
    v[8] = _iv[0];
    v[9] = _iv[1];
    v[10] = _iv[2];
    v[11] = _iv[3];
    v[12] = _iv[4] ^ _t0;
    v[13] = _iv[5] ^ _t1;
    v[14] = _iv[6] ^ _f0;
    v[15] = _iv[7] ^ _f1;

    for (var round = 0; round < 10; round++) {
      final sigma = _sigma[round];
      _g(v, m, sigma[0], sigma[1], 0, 4, 8, 12);
      _g(v, m, sigma[2], sigma[3], 1, 5, 9, 13);
      _g(v, m, sigma[4], sigma[5], 2, 6, 10, 14);
      _g(v, m, sigma[6], sigma[7], 3, 7, 11, 15);
      _g(v, m, sigma[8], sigma[9], 0, 5, 10, 15);
      _g(v, m, sigma[10], sigma[11], 1, 6, 11, 12);
      _g(v, m, sigma[12], sigma[13], 2, 7, 8, 13);
      _g(v, m, sigma[14], sigma[15], 3, 4, 9, 14);
    }

    for (var i = 0; i < 8; i++) {
      _h[i] = _h[i] ^ v[i] ^ v[i + 8];
    }
  }

  // One mixing step. Operands are read from [v] (always normalized to
  // unsigned 32-bit values) and written back through the same list, so
  // the sums wrap modulo 2^32 identically on the VM and on dart2js.
  static void _g(
    final Uint32List v,
    final Uint32List m,
    final int x,
    final int y,
    final int a,
    final int b,
    final int c,
    final int d,
  ) {
    v[a] = _mask(v[a] + v[b] + m[x]);
    v[d] = _rotr(v[d] ^ v[a], 16);
    v[c] = _mask(v[c] + v[d]);
    v[b] = _rotr(v[b] ^ v[c], 12);
    v[a] = _mask(v[a] + v[b] + m[y]);
    v[d] = _rotr(v[d] ^ v[a], 8);
    v[c] = _mask(v[c] + v[d]);
    v[b] = _rotr(v[b] ^ v[c], 7);
  }

  static int _mask(final int value) => value & 0xFFFFFFFF;

  static int _rotr(final int value, final int bits) {
    final masked = _mask(value);
    return (masked >>> bits) | ((masked << (32 - bits)) & 0xFFFFFFFF);
  }
}

/// Incremental BLAKE2sp hasher producing the 32-byte digest RAR 5
/// declares for hash type `0x00`.
///
/// The instance carries fixed-size state only. Feed the payload with
/// [add] in any chunking and take [rar5Blake2spDigestBytes] bytes out of
/// [close]; the input is the entry's full decompressed post-filter
/// output in order.
final class Rar5Blake2spHasher {
  /// Creates a hasher over an empty stream.
  Rar5Blake2spHasher();

  late final List<_Blake2s> _leaves = List<_Blake2s>.generate(_lanes, (final i) {
    return _Blake2s(
      fanout: _lanes,
      depth: 2,
      nodeOffset: i,
      nodeDepth: 0,
      // Leaf 7 is the last node of the leaf layer.
      lastNode: i == _lanes - 1,
    );
  });
  late final _Blake2s _root = _Blake2s(
    fanout: _lanes,
    depth: 2,
    nodeOffset: 0,
    nodeDepth: 1,
    lastNode: true,
  );
  final Uint8List _buf = Uint8List(_spanBytes);
  int _buflen = 0;
  bool _closed = false;

  /// Consumes one more chunk of the payload. Any chunking produces the
  /// same digest.
  void add(final Uint8List chunk) {
    if (_closed) {
      throw StateError('BLAKE2sp hasher already closed.');
    }
    if (chunk.isEmpty) return;
    var position = 0;
    var remaining = chunk.length;
    final fill = _spanBytes - _buflen;
    if (_buflen > 0 && remaining >= fill) {
      _buf.setRange(_buflen, _spanBytes, chunk, position);
      _flushBuffer();
      position += fill;
      remaining -= fill;
      _buflen = 0;
    }
    for (var i = 0; i < _lanes; i++) {
      var lane = position + i * _blockBytes;
      var laneRemaining = remaining;
      while (laneRemaining >= _spanBytes) {
        _leaves[i].update(chunk, lane, lane + _blockBytes);
        lane += _spanBytes;
        laneRemaining -= _spanBytes;
      }
    }
    final tail = remaining % _spanBytes;
    if (tail > 0) {
      _buf.setRange(_buflen, _buflen + tail, chunk, position + remaining - tail);
    }
    _buflen += tail;
  }

  /// Ends the stream and returns the 32-byte digest. The hasher cannot
  /// be reused afterwards.
  Uint8List close() {
    if (_closed) {
      throw StateError('BLAKE2sp hasher already closed.');
    }
    _closed = true;
    final hashes = Uint8List(_lanes * rar5Blake2spDigestBytes);
    for (var i = 0; i < _lanes; i++) {
      if (_buflen > i * _blockBytes) {
        var left = _buflen - i * _blockBytes;
        if (left > _blockBytes) left = _blockBytes;
        _leaves[i].update(_buf, i * _blockBytes, i * _blockBytes + left);
      }
      _leaves[i].finish(hashes, i * rar5Blake2spDigestBytes);
    }
    _root.update(hashes, 0, hashes.length);
    final out = Uint8List(rar5Blake2spDigestBytes);
    _root.finish(out, 0);
    return out;
  }

  void _flushBuffer() {
    for (var i = 0; i < _lanes; i++) {
      _leaves[i].update(_buf, i * _blockBytes, (i + 1) * _blockBytes);
    }
  }
}

/// Computes the unkeyed BLAKE2sp digest of [data] in one call.
Uint8List rar5Blake2spDigest(final Uint8List data) {
  final hasher = Rar5Blake2spHasher();
  hasher.add(data);
  return hasher.close();
}
