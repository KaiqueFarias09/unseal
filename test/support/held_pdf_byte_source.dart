import 'dart:async';
import 'dart:typed_data';
import 'package:unseal/unseal.dart';

/// Arms one specific post-open range, leaving subsequent host requests usable.
final class HeldPdfByteSource implements UnsealByteSource {
  /// Serves exact slices of [bytes].
  HeldPdfByteSource(this.bytes);

  /// Immutable source bytes.
  final Uint8List bytes;

  /// Set after opening to hold the next physical host read.
  bool holdNext = false;

  /// Completes only when the armed post-open read actually enters the host.
  final Completer<void> entered = Completer<void>();

  /// Releases the held host read after lifecycle assertions finish.
  final Completer<void> release = Completer<void>();

  /// Current physical host reads, including cancelled but unsettled requests.
  int active = 0;

  /// Observed physical host concurrency.
  int peak = 0;

  /// Whether disposal reached the host.
  bool closed = false;
  @override
  int get length => bytes.length;
  @override
  String? get revision => 'review-fixed';
  @override
  Future<Uint8List> readRange(final int offset, final int count) async {
    if (closed) throw const ByteSourceClosedException();
    active++;
    if (active > peak) peak = active;
    try {
      if (holdNext) {
        holdNext = false;
        entered.complete();
        await release.future;
      }
      if (closed) throw const ByteSourceClosedException();
      return Uint8List.sublistView(bytes, offset, offset + count);
    } finally {
      active--;
    }
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}
