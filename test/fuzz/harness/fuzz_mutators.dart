/// Deterministic byte-level mutators for seed-derived fuzz inputs.
///
/// All randomness flows through the caller's [Random] so a seed fully
/// determines the produced input; there is no wall-clock or global
/// state anywhere in the harness.
library;

import 'dart:math';
import 'dart:typed_data';

/// Applies [rounds] random mutation rounds to [seed].
Uint8List mutateBytes(final Uint8List seed, final Random random, {final int rounds = 2}) {
  var out = Uint8List.fromList(seed);
  for (var round = 0; round < rounds; round++) {
    if (out.isEmpty) break;
    switch (random.nextInt(5)) {
      case 0: // single bit flip
        final index = random.nextInt(out.length);
        out[index] ^= 1 << random.nextInt(8);
      case 1: // random byte overwrite
        final index = random.nextInt(out.length);
        out[index] = random.nextInt(256);
      case 2: // truncate
        out = Uint8List.fromList(out.sublist(0, random.nextInt(out.length)));
      case 3: // region fill (zeros / 0xFF / random)
        if (out.length < 4) break;
        final start = random.nextInt(out.length - 1);
        final end = (start + 1 + random.nextInt(out.length - start)).clamp(0, out.length);
        final fill = random.nextInt(3);
        for (var index = start; index < end; index++) {
          out[index] = switch (fill) {
            0 => 0x00,
            1 => 0xFF,
            _ => random.nextInt(256),
          };
        }
      case 4: // append random tail
        final tailLength = random.nextInt(64);
        final merged = Uint8List(out.length + tailLength)
          ..setRange(0, out.length, out);
        for (var index = out.length; index < merged.length; index++) {
          merged[index] = random.nextInt(256);
        }
        out = merged;
    }
  }
  return out;
}

/// Random bytes with a format-conforming magic prefix, so mutations
/// land INSIDE parsers instead of being rejected by the sniffer.
Uint8List randomBytesWithMagic(
  final List<int> magic,
  final Random random, {
  final int maxLength = 2048,
}) {
  final tailLength = magic.length >= maxLength ? 0 : random.nextInt(maxLength - magic.length);
  final out = Uint8List(magic.length + tailLength);
  out.setRange(0, magic.length, magic);
  for (var index = magic.length; index < out.length; index++) {
    out[index] = random.nextInt(256);
  }

  return out;
}

/// Printable-heavy random text (keeps the TXT/HTML sniffers happy so
/// the text parsers get exercised).
Uint8List randomPrintableText(final Random random, {final int maxLength = 4096}) {
  const sample = 'abc def ghij klmnop qrstu vwxyz,\n.\t:;()[]<>&"\' 0123456789 %-';
  final length = 1 + random.nextInt(maxLength);
  final out = Uint8List(length);
  for (var index = 0; index < length; index++) {
    out[index] = sample.codeUnitAt(random.nextInt(sample.length)) & 0xFF;
  }

  return out;
}
