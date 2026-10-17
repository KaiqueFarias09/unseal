import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:unseal/src/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:unseal/src/features/progressive/session_engine.dart';
import 'package:unseal/src/features/progressive/session_policy.dart';
import 'package:unseal/src/foundation/entities/book/book.dart';
import 'package:unseal/src/foundation/exceptions/unseal_exception.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/byte_source_bridge.dart';
import 'package:unseal/src/platform/web/worker_ops.dart';
import 'package:web/web.dart' as web;

/// The book retained from the last successful `parse`; `search`,
/// `cfiResolve` and `cfiBuild` run against it until the next parse
/// replaces it.
Book? _book;

/// Session engines retained by their client-assigned IDs. A session op
/// can address only the engine associated with its own ID, and dispose
/// removes only that entry.
final Map<int, SessionEngine> _sessions = <int, SessionEngine>{};

/// ByteSource.v1 bridges for source-opened sessions, keyed by the same
/// client-assigned IDs. The bridge posts range requests to the main
/// thread and completes from the replies routed here.
final Map<int, WorkerByteBridge> _byteBridges = <int, WorkerByteBridge>{};

/// Entry point of the unseal parsing worker.
///
/// Compile it next to your web app and point
/// `UnsealWorker.configure` at the output URL:
///
/// ```
/// dart compile js web/unseal_worker.dart -o web/unseal_worker.js
/// ```
///
/// The worker answers `parse` (whole book), `metadata` (fast path),
/// `search`, `cfiResolve` and `cfiBuild` — the last three against the
/// book kept back from the most recent successful parse — and the
/// progressive `session*` ops against the engine selected by its
/// `sessionId`. Source-opened sessions additionally exchange
/// byteSource.v1 range messages with the main thread's gate. Every
/// reply carries a JSON wire payload plus the blob list it references
/// (binary bytes and text strings side by side). Failures travel back
/// as typed errors; infrastructure failures (script unreachable,
/// worker killed) make the main thread fall back to inline parsing.
void main() {
  globalContext.setProperty('onmessage'.toJS, _handle.toJS);
}

void _handle(final web.MessageEvent event) {
  final data = event.data as JSObject?;
  if (data == null) return;

  // byteSource.v1 messages carry a `kind`, never an `op`; route them
  // to the session's bridge before the op path looks at anything.
  if (data.hasProperty(wireKeyKind.toJS).toDart) {
    final kind = (data.getProperty(wireKeyKind.toJS) as JSString).toDart;
    if (kind == wireKindByteSourceReply || kind == wireKindByteSourceError) {
      _routeByteReply(kind, data);

      return;
    }
  }

  final id = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
  final op = (data.getProperty(wireKeyOp.toJS) as JSString).toDart;
  // `parse` / `metadata` carry bytes and no payload. `sessionOpen`
  // carries both bytes and its ID/policy payload; later session ops
  // carry a payload and no bytes.
  final bytes = data.hasProperty(wireKeyBytes.toJS).toDart
      ? (data.getProperty(wireKeyBytes.toJS) as JSUint8Array).toDart
      : null;
  final payload = data.hasProperty(wireKeyPayload.toJS).toDart
      ? decodeJson((data.getProperty(wireKeyPayload.toJS) as JSString).toDart)
      : null;

  unawaited(_process(id, op, bytes, payload));
}

Future<void> _process(
  final int id,
  final String op,
  final Uint8List? bytes,
  final Map<String, Object?>? payload,
) async {
  var sessionId = -1;
  try {
    final rawSessionId = op.startsWith('session') && payload != null
        ? payload[wireKeySessionId]
        : null;
    if (op.startsWith('session') && (rawSessionId is! int || rawSessionId < 0)) {
      throw const SessionClosedException();
    }
    sessionId = rawSessionId is int ? rawSessionId : -1;

    // A source open brings the byteSource.v1 bridge up before the
    // engine reads its first range.
    WorkerByteBridge? bridge;
    if (op == workerOpSessionOpen && payload?[wireKeyByteSource] == true) {
      bridge = WorkerByteBridge(
        sessionId: sessionId,
        length: payload![wireKeySourceLength]! as int,
        revision: payload[wireKeyRevision] as String?,
        post: _postByteRequest,
      );
      _byteBridges[sessionId] = bridge;
    }

    final reply = await runWorkerOp(
      op: op,
      payload: payload,
      bytes: bytes,
      residentBook: _book,
      residentSession: sessionId < 0 ? null : _sessions[sessionId],
      byteBridge: bridge,
    );
    if (op == workerOpParse) {
      // Retain the freshly parsed book for the stateful ops; the
      // decode rebuilds structures without copying content and, for
      // MOBI, re-parses only the record 0 slice — cheap against the
      // parse that just ran.
      _book = decodeBookWire(reply.json, reply.blobs);
    }
    if (op == workerOpSessionOpen) {
      // The op already closed the engine with this ID, if any; adopt
      // the new engine without affecting other resident sessions.
      _sessions[sessionId] = reply.session!;
    }
    if (op == workerOpSessionDispose) {
      _sessions.remove(sessionId);
      _byteBridges.remove(sessionId)?.close();
    }
    _reply(id, reply.kind, reply.json, reply.blobs);
  } on EmptyBytesException catch (error) {
    _dropOpenBridge(op, sessionId);
    _error(id, 'EmptyBytesException', error.message);
  } on UnsealException catch (error) {
    _dropOpenBridge(op, sessionId);
    _error(id, error.runtimeType.toString(), error.message);
  } on FormatException catch (error) {
    _dropOpenBridge(op, sessionId);
    _error(id, 'FormatException', error.message);
  } on RangeError catch (error) {
    _dropOpenBridge(op, sessionId);
    _error(id, 'RangeError', error.message == null ? error.toString() : '${error.message}');
  } on Object catch (error) {
    _dropOpenBridge(op, sessionId);
    _error(id, '', error.toString());
  }
}

/// A failed source open never leaves its bridge registered: the main
/// thread's gate for that session is dropped on its side, and a dead
/// bridge cannot answer anything.
void _dropOpenBridge(final String op, final int sessionId) {
  if (op == workerOpSessionOpen) _byteBridges.remove(sessionId)?.close();
}

void _routeByteReply(final String kind, final JSObject data) {
  final sessionId = (data.getProperty(wireKeySessionId.toJS) as JSNumber).toDartInt;
  final requestId = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
  final bridge = _byteBridges[sessionId];
  if (bridge == null) return;

  if (kind == wireKindByteSourceReply) {
    bridge.handleReply(<String, Object?>{
      'kind': kind,
      wireKeyRequestId: requestId,
      wireKeyBytes: (data.getProperty(wireKeyBytes.toJS) as JSUint8Array).toDart,
    });
  } else {
    bridge.handleReply(<String, Object?>{
      'kind': kind,
      wireKeyRequestId: requestId,
      wireKeyType: (data.getProperty(wireKeyType.toJS) as JSString).toDart,
      wireKeyMessage: (data.getProperty(wireKeyMessage.toJS) as JSString).toDart,
    });
  }
}

void _postByteRequest(final Map<String, Object?> message) {
  final outgoing = JSObject();
  outgoing.setProperty(wireKeyId.toJS, (message[wireKeyRequestId]! as int).toJS);
  outgoing.setProperty(wireKeyKind.toJS, (message['kind']! as String).toJS);
  outgoing.setProperty(wireKeySessionId.toJS, (message[wireKeySessionId]! as int).toJS);
  outgoing.setProperty('offset'.toJS, (message['offset']! as int).toJS);
  outgoing.setProperty('count'.toJS, (message['count']! as int).toJS);
  final revision = message[wireKeyRevision] as String?;
  if (revision != null) outgoing.setProperty(wireKeyRevision.toJS, revision.toJS);
  globalContext.callMethod('postMessage'.toJS, outgoing);
}

void _reply(
  final int id,
  final String kind,
  final Map<String, Object?> json,
  final List<Object> blobs,
) {
  final message = JSObject();
  message.setProperty(wireKeyId.toJS, id.toJS);
  message.setProperty(wireKeyKind.toJS, kind.toJS);
  message.setProperty(wireKeyJson.toJS, encodeJson(json).toJS);
  // The blob list carries Uint8List entries and String entries side
  // by side; each one crosses as its native structured-clone type.
  final blobArray = JSArray<JSAny?>.withLength(blobs.length);
  for (var i = 0; i < blobs.length; i++) {
    final blob = blobs[i];
    blobArray[i] = blob is Uint8List ? blob.toJS : (blob as String).toJS;
  }
  message.setProperty(wireKeyBlobs.toJS, blobArray);
  globalContext.callMethod('postMessage'.toJS, message);
}

void _error(final int id, final String type, final String message) {
  final reply = JSObject();
  reply.setProperty(wireKeyId.toJS, id.toJS);
  reply.setProperty(wireKeyKind.toJS, wireReplyError.toJS);
  reply.setProperty(wireKeyType.toJS, type.toJS);
  reply.setProperty(wireKeyMessage.toJS, message.toJS);
  globalContext.callMethod('postMessage'.toJS, reply);
}
