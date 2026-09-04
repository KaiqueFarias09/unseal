import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/book_metadata.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:web/web.dart' as web;

import 'book_wire.dart';

/// Owns the configured web worker and the request/reply protocol.
///
/// Failures that mean "no worker" (nothing configured, the script
/// failed to load, the worker died) surface as `null` results so
/// callers fall back to inline parsing; genuine parse failures surface
/// as the original [ELivreException] hierarchy, rebuilt through
/// [decodeErrorWire].
final class WorkerClient {
  WorkerClient._();

  /// Process-wide client.
  static final WorkerClient instance = WorkerClient._();

  web.Worker? _worker;
  Uri? _script;
  bool _broken = false;
  int _nextId = 0;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  /// Whether a worker script has been configured and not broken.
  bool get isConfigured => _script != null && !_broken;

  /// Points the client at a compiled [workerScript] (see
  /// `web/e_livre_worker.dart` for the build command). The worker is
  /// spawned lazily on the first parse.
  void configure(final Uri workerScript) {
    dispose();
    _script = workerScript;
    _broken = false;
  }

  /// Terminates the worker and forgets the configuration.
  void dispose() {
    _worker?.terminate();
    _worker = null;
    _script = null;
    _broken = false;
    _drainPending();
  }

  /// Parses [bytes] inside the worker; `null` means the worker was
  /// unavailable and the caller should parse inline.
  Future<Book?> parseInWorker(final Uint8List bytes) async =>
      await _request(workerOpParse, bytes) as Book?;

  /// Reads metadata inside the worker; `null` means inline fallback.
  Future<BookMetadata?> metadataInWorker(final Uint8List bytes) async =>
      await _request(workerOpMetadata, bytes) as BookMetadata?;

  Future<Object?> _request(final String op, final Uint8List bytes) {
    final worker = _acquire();
    if (worker == null) return Future<Object?>.value();

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;

    final message = JSObject();
    message.setProperty(wireKeyId.toJS, id.toJS);
    message.setProperty(wireKeyOp.toJS, op.toJS);
    message.setProperty(wireKeyBytes.toJS, bytes.toJS);
    worker.postMessage(message);

    return completer.future;
  }

  /// Returns the live worker, spawning one when needed. `null` means
  /// workers are unavailable and parsing must stay on the main thread.
  web.Worker? _acquire() {
    if (!isConfigured) return null;
    final existing = _worker;
    if (existing != null) return existing;

    try {
      final worker = web.Worker(_script!.toString().toJS);
      worker.onmessage = ((web.Event event) => _onReply(event as web.MessageEvent)).toJS;
      worker.onerror = ((web.Event event) => _onWorkerError()).toJS;
      _worker = worker;

      return worker;
    } on UnsupportedError {
      // The runtime exposes no worker support (native VM, or a host
      // blocking workers); parsing stays on the main thread.
      _broken = true;

      return null;
    }
  }

  void _onReply(final web.MessageEvent event) {
    final data = event.data as JSObject?;
    if (data == null) return;

    final id = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
    final completer = _pending.remove(id);
    if (completer == null) return;

    final kind = (data.getProperty(wireKeyKind.toJS) as JSString).toDart;
    try {
      switch (kind) {
        case wireReplyBook:
        case wireReplyMetadata:
          final json = decodeJson((data.getProperty(wireKeyJson.toJS) as JSString).toDart);
          final blobs = <Uint8List>[
            for (final blob
                in (data.getProperty(wireKeyBlobs.toJS) as JSArray<JSUint8Array>).toDart)
              blob.toDart,
          ];
          completer.complete(
            kind == wireReplyBook ? decodeBookWire(json, blobs) : decodeMetadataWire(json, blobs),
          );
        case wireReplyError:
          completer.completeError(
            decodeErrorWire(
              (data.getProperty(wireKeyType.toJS) as JSString).toDart,
              (data.getProperty(wireKeyMessage.toJS) as JSString).toDart,
            ),
          );
        default:
          completer.completeError(ELivreException('Worker reply holds an unknown kind: $kind'));
      }
    } on Object catch (error) {
      completer.completeError(error);
    }
  }

  void _onWorkerError() {
    // Script failed to load or the worker died: never retry it, every
    // pending and future request falls back to inline parsing.
    _broken = true;
    _worker = null;
    _drainPending();
  }

  void _drainPending() {
    for (final completer in _pending.values) {
      completer.complete();
    }
    _pending.clear();
  }
}
