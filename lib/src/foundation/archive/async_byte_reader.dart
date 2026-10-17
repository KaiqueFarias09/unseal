import 'dart:typed_data';

import 'zip_byte_source.dart';

/// Asynchronous bounded byte reads over a book container source.
///
/// This is the async twin of [`ZipByteSource`]: the progressive
/// session engine reads every byte through it, whether the bytes sit
/// in memory, in a file, or behind the host's remote byte source. The
/// remote implementation lives with the transports (a request/reply
/// bridge to the isolate or Web Worker); the synchronous sources wrap
/// through [SyncAsyncByteReader], whose futures complete immediately.
abstract interface class AsyncByteReader {
  /// Total source length in bytes.
  int get length;

  /// The source's revision token, or null when the source cannot
  /// verify identity. Remote readers stamp every request with it.
  String? get revision;

  /// Reads exactly [count] bytes at [offset].
  ///
  /// Throws [RangeError] when the range leaves the source; callers
  /// gate offsets against [length] first.
  Future<Uint8List> read(final int offset, final int count);

  /// Releases the underlying resource, when this reader owns one.
  /// Readers that proxy a host-owned source only mark themselves
  /// closed; the host closes the actual source.
  void close();
}

/// Reader over a synchronous [ZipByteSource]: every read completes in
/// the current turn, so bytes and file sessions keep their exact
/// 1.3.0 behavior while running the same engine code as remote
/// sessions.
final class SyncAsyncByteReader implements AsyncByteReader {
  /// Wraps [source] without copying.
  SyncAsyncByteReader(this.source);

  /// The wrapped synchronous source.
  final ZipByteSource source;

  @override
  int get length => source.length;

  @override
  String? get revision => null;

  @override
  Future<Uint8List> read(final int offset, final int count) {
    return Future<Uint8List>.value(source.read(offset, count));
  }

  @override
  void close() => source.close();
}

/// Reader that serves reads from an in-memory function — the seam the
/// transports plug their bridges into. A gate-backed inline transport
/// passes its budget-checked gate read; the isolate and worker
/// transports pass their request/reply bridge.
final class CallbackAsyncByteReader implements AsyncByteReader {
  /// Creates the reader.
  CallbackAsyncByteReader({
    required this.length,
    required this.revision,
    required Future<Uint8List> Function(int offset, int count) read,
  }) : _read = read;

  @override
  final int length;

  @override
  final String? revision;

  final Future<Uint8List> Function(int offset, int count) _read;
  var _closed = false;

  @override
  Future<Uint8List> read(final int offset, final int count) {
    if (_closed) return Future<Uint8List>.error(StateError('Byte reader is closed.'));

    return _read(offset, count);
  }

  @override
  void close() => _closed = true;
}
