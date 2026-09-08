import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:e_livre/src/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/src/foundation/entities/book/book.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:e_livre/src/platform/web/worker_ops.dart';
import 'package:web/web.dart' as web;

/// The book retained from the last successful `parse`; `search`,
/// `cfiResolve` and `cfiBuild` run against it until the next parse
/// replaces it.
Book? _book;

/// Entry point of the e_livre parsing worker.
///
/// Compile it next to your web app and point
/// `WorkerBookReader.configure` at the output URL:
///
/// ```
/// dart compile js web/e_livre_worker.dart -o web/e_livre_worker.js
/// ```
///
/// The worker answers `parse` (whole book), `metadata` (fast path),
/// `search`, `cfiResolve` and `cfiBuild` — the last three against the
/// book kept back from the most recent successful parse. Every reply
/// carries a JSON wire payload plus the blob list it references
/// (binary bytes and text strings side by side). Failures travel back
/// as typed errors; infrastructure failures (script unreachable,
/// worker killed) make the main thread fall back to inline parsing.
void main() {
  globalContext.setProperty('onmessage'.toJS, _handle.toJS);
}

void _handle(final web.MessageEvent event) {
  final data = event.data as JSObject?;
  if (data == null) return;

  final id = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
  final op = (data.getProperty(wireKeyOp.toJS) as JSString).toDart;
  // `parse` / `metadata` carry bytes and no payload; the stateful ops
  // carry a payload and no bytes.
  final bytes = data.hasProperty(wireKeyBytes.toJS).toDart
      ? (data.getProperty(wireKeyBytes.toJS) as JSUint8Array).toDart
      : null;
  final payload = data.hasProperty(wireKeyPayload.toJS).toDart
      ? decodeJson((data.getProperty(wireKeyPayload.toJS) as JSString).toDart)
      : null;

  try {
    final reply = runWorkerOp(op: op, payload: payload, bytes: bytes, residentBook: _book);
    if (op == workerOpParse) {
      // Retain the freshly parsed book for the stateful ops; the
      // decode rebuilds structures without copying content and, for
      // MOBI, re-parses only the record 0 slice — cheap against the
      // parse that just ran.
      _book = decodeBookWire(reply.json, reply.blobs);
    }
    _reply(id, reply.kind, reply.json, reply.blobs);
  } on EmptyBytesException catch (error) {
    _error(id, 'EmptyBytesException', error.message);
  } on ELivreException catch (error) {
    _error(id, error.runtimeType.toString(), error.message);
  } on FormatException catch (error) {
    _error(id, 'FormatException', error.message);
  } on Object catch (error) {
    _error(id, '', error.toString());
  }
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
