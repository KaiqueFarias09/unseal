import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart' show BookReader;
import 'package:e_livre/src/features/epub/exceptions/empty_bytes_exception.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/foundation/entities/book_format.dart';
import 'package:e_livre/src/foundation/exceptions/elivre_exception.dart';
import 'package:e_livre/src/platform/web/book_wire.dart';
import 'package:web/web.dart' as web;

/// Entry point of the e_livre parsing worker.
///
/// Compile it next to your web app and point
/// `WorkerBookReader.configure` at the output URL:
///
/// ```
/// dart compile js web/e_livre_worker.dart -o web/e_livre_worker.js
/// ```
///
/// The worker answers two requests — `parse` (whole book) and
/// `metadata` (fast path) — and replies with a JSON wire payload plus
/// the binary blobs it references. Parse failures travel back as
/// typed errors; infrastructure failures (script unreachable, worker
/// killed) make the main thread fall back to inline parsing.
void main() {
  globalContext.setProperty('onmessage'.toJS, _handle.toJS);
}

void _handle(final web.MessageEvent event) {
  final data = event.data as JSObject?;
  if (data == null) return;

  final id = (data.getProperty(wireKeyId.toJS) as JSNumber).toDartInt;
  final op = (data.getProperty(wireKeyOp.toJS) as JSString).toDart;
  final bytes = (data.getProperty(wireKeyBytes.toJS) as JSUint8Array).toDart;

  try {
    switch (op) {
      case workerOpParse:
        final book = BookReader.parseBook(bytes);
        Uint8List? record0;
        String? ident;
        if (book.format == BookFormat.mobi || book.format == BookFormat.azw3) {
          final pdb = PdbHeader.parse(bytes);
          record0 = pdb.record(0);
          ident = pdb.ident;
        }
        final (json, blobs) = encodeBookWire(book, mobiRecord0: record0, mobiIdent: ident);
        _reply(id, wireReplyBook, json, blobs);
      case workerOpMetadata:
        final (json, blobs) = encodeMetadataWire(BookReader.readMetadataSync(bytes));
        _reply(id, wireReplyMetadata, json, blobs);
      default:
        _error(id, '', 'Worker request holds an unknown op: $op');
    }
  } on EmptyBytesException catch (error) {
    _error(id, 'EmptyBytesException', error.message);
  } on ELivreException catch (error) {
    _error(id, error.runtimeType.toString(), error.message);
  } on Object catch (error) {
    _error(id, '', error.toString());
  }
}

void _reply(
  final int id,
  final String kind,
  final Map<String, Object?> json,
  final List<Uint8List> blobs,
) {
  final message = JSObject();
  message.setProperty(wireKeyId.toJS, id.toJS);
  message.setProperty(wireKeyKind.toJS, kind.toJS);
  message.setProperty(wireKeyJson.toJS, encodeJson(json).toJS);
  final blobArray = JSArray<JSUint8Array>.withLength(blobs.length);
  for (var i = 0; i < blobs.length; i++) {
    blobArray[i] = blobs[i].toJS;
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
