import 'dart:async';
import 'dart:typed_data';

import '../../foundation/archive/async_byte_reader.dart';
import 'book_wire.dart';

/// Engine-side half of the byteSource.v1 bridge inside a Web Worker:
/// sends range requests to the main thread and completes them from the
/// replies the worker shell routes here. Pure Dart — the shell does
/// the `postMessage` plumbing, tests drive [handleReply] directly.
///
/// The container length and the revision token arrive in the
/// `sessionOpen` payload (no handshake round trip), so the reader can
/// serve the engine's first open read immediately.
final class WorkerByteBridge implements AsyncByteReader {
  /// Creates the bridge for session [sessionId] over a source of
  /// [length] bytes whose reads are stamped with [revision]. Posted
  /// requests travel through [post] as plain JSON maps.
  WorkerByteBridge({
    required this.sessionId,
    required this.length,
    required this.revision,
    required final void Function(Map<String, Object?> message) post,
  }) : _post = post;

  /// The session id every posted request carries.
  final int sessionId;

  final void Function(Map<String, Object?> message) _post;

  @override
  final int length;

  @override
  final String? revision;

  var _nextRequestId = 0;
  var _closed = false;
  final Map<int, Completer<Uint8List>> _pending = <int, Completer<Uint8List>>{};

  @override
  Future<Uint8List> read(final int offset, final int count) {
    if (_closed) {
      return Future<Uint8List>.error(StateError('Byte bridge is closed.'));
    }

    final requestId = _nextRequestId++;
    final completer = Completer<Uint8List>();
    _pending[requestId] = completer;
    _post(<String, Object?>{
      'kind': wireKindByteSourceRequest,
      wireKeySessionId: sessionId,
      wireKeyRequestId: requestId,
      'offset': offset,
      'count': count,
      if (revision != null) wireKeyRevision: revision,
    });

    return completer.future;
  }

  /// Routes one main-thread reply into its pending read. Late replies
  /// to dead requests serve nobody.
  void handleReply(final Map<String, Object?> message) {
    final kind = message['kind'];
    final requestId = message[wireKeyRequestId] as int?;
    if (requestId == null) return;

    final completer = _pending.remove(requestId);
    if (completer == null) return;

    if (kind == wireKindByteSourceReply) {
      completer.complete(message[wireKeyBytes]! as Uint8List);
    } else {
      completer.completeError(
        decodeErrorWire(message[wireKeyType]! as String, message[wireKeyMessage]! as String),
      );
    }
  }

  /// Fails every pending read — the session is going away.
  void drain(final Object error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  void close() {
    _closed = true;
    drain(StateError('Byte bridge is closed.'));
  }
}
