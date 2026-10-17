import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../../../platform/io/zip_byte_source_io.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../comic/exceptions/comic_exception.dart';
import '../../epub/exceptions/exceptions.dart';
import '../../pdf/entities/pdf_page_text.dart';
import '../../pdf/exceptions/pdf_exception.dart';
import '../../pdf/layout/pdf_page_structure.dart';
import '../../reading/book_progression.dart';
import '../../search/entities/search_mode.dart';
import '../../search/entities/search_results.dart';
import '../session_engine.dart';
import '../session_policy.dart';
import 'session_transport.dart';

/// Opens a session backed by a long-lived isolate.
///
/// File opens pass the PATH and the isolate reads the container itself
/// with seek-and-slice reads, so neither side materializes the
/// compressed source. Byte opens send the bytes once at spawn. Only
/// small messages — structure, one resource at a time, search results,
/// one page's text lines — cross the boundary afterwards. When the
/// runtime refuses to spawn isolates, the engine runs inline in the
/// caller instead.
Future<(SessionTransport, Book)> openSessionTransport({
  required final Uint8List? bytes,
  required final String? path,
  required final String password,
  required final SessionPolicy policy,
}) async {
  try {
    final transport = await _IsolateSessionTransport.open(
      bytes: bytes,
      path: path,
      password: password,
      policy: policy,
    );

    return (transport, transport.header);
  } on UnsupportedError {
    final engine = _openInlineEngine(bytes: bytes, path: path, password: password, policy: policy);

    return (InlineSessionTransport(engine), engine.book);
  } on ArgumentError {
    final engine = _openInlineEngine(bytes: bytes, path: path, password: password, policy: policy);

    return (InlineSessionTransport(engine), engine.book);
  }
}

SessionEngine _openInlineEngine({
  required final Uint8List? bytes,
  required final String? path,
  required final String password,
  required final SessionPolicy policy,
}) {
  if (path != null) {
    final source = FileZipByteSource.open(path);
    try {
      return SessionEngine.openSource(source, password: password, policy: policy);
    } on Object {
      source.close();
      rethrow;
    }
  }

  return SessionEngine.openBytes(bytes!, password: password, policy: policy);
}

/// Handshake message: caller's reply port plus the open recipe.
final class _SessionBootstrap {
  _SessionBootstrap(this.replyPort, this.bytes, this.path, this.password, this.policy);

  final SendPort replyPort;
  final Uint8List? bytes;
  final String? path;
  final String password;
  final SessionPolicy policy;
}

/// The isolate entry: open the engine, report ready (or the typed open
/// failure), then serve small request/reply messages until killed.
void _isolateMain(final _SessionBootstrap bootstrap) {
  final SessionEngine engine;
  try {
    if (bootstrap.path != null) {
      final byteSource = FileZipByteSource.open(bootstrap.path!);
      try {
        engine = SessionEngine.openSource(
          byteSource,
          password: bootstrap.password,
          policy: bootstrap.policy,
        );
      } on Object {
        byteSource.close();
        rethrow;
      }
    } else {
      engine = SessionEngine.openBytes(
        bootstrap.bytes!,
        password: bootstrap.password,
        policy: bootstrap.policy,
      );
    }
  } on Object catch (error) {
    bootstrap.replyPort.send(<Object?>['error', _errorType(error), _errorMessage(error)]);

    return;
  }

  final port = ReceivePort();
  bootstrap.replyPort.send(<Object?>['ready', port.sendPort, engine.book, engine.byteLength]);
  port.listen((final message) {
    _dispatch(engine, bootstrap.replyPort, message as List<Object?>);
  });
}

void _dispatch(final SessionEngine engine, final SendPort replyPort, final List<Object?> message) {
  final id = message[1]! as int;
  try {
    final result = switch (message[0]! as String) {
      _opResource => engine.resource(message[2]! as String),
      _opRange => engine.bytesRange(message[2]! as int, message[3]! as int),
      _opResources => <String, Uint8List>{
        for (final path in (message[2]! as List).cast<String>())
          if (engine.resource(path) case final Uint8List bytes) path: bytes,
      },
      _opText => engine.documentText(message[2]! as String),
      _opSource => engine.documentSource(message[2]! as String),
      _opPdfLines => engine.loadPdfPageLines(message[2]! as int),
      _opPdfStructure => engine.loadPdfPageStructure(message[2]! as int),
      _opSearch => engine.search(
        message[2]! as String,
        mode: SearchMode.values.byName(message[3]! as String),
        isCaseSensitive: message[4]! as bool,
        isTolerant: message[5]! as bool,
        nearChars: message[6]! as int,
        contextChars: message[7]! as int,
        maxMatches: message[8]! as int,
      ),
      _opProgression => engine.computeProgression(),
      _opStatistics => engine.computeStatistics(),
      _opCfiResolve => engine.resolveCfi(message[2]! as String),
      _opCfiBuild => engine.buildCfi(
        contentIndex: message[2]! as int,
        offsetInText: message[3]! as int,
      ),
      _ => throw UnsealException('Session isolate received an unknown op: ${message[0]}'),
    };
    replyPort.send(<Object?>['ok', id, result]);
  } on Object catch (error) {
    replyPort.send(<Object?>['err', id, _errorType(error), _errorMessage(error)]);
  }
}

const _opResource = 'resource';
const _opResources = 'resources';
const _opRange = 'range';
const _opText = 'text';
const _opSource = 'source';
const _opPdfLines = 'pdfLines';
const _opPdfStructure = 'pdfStructure';
const _opSearch = 'search';
const _opProgression = 'progression';
const _opStatistics = 'statistics';
const _opCfiResolve = 'cfiResolve';
const _opCfiBuild = 'cfiBuild';

/// Rebuilds a typed failure from the error wire the isolate carries
/// (type name + message). The known names map to their classes; unknown
/// names degrade to [UnsealException] with the original text preserved.
Object rebuildSessionError(final String type, final String message) {
  return switch (type) {
    'SessionClosedException' => const SessionClosedException(),
    'SessionCancelledException' => const SessionCancelledException(),
    'SessionUnsupportedFormatException' => SessionUnsupportedFormatException(message),
    'EmptyBytesException' => EmptyBytesException(),
    'InvalidBookException' => InvalidBookException(message),
    'EpubException' => EpubException(message),
    'ComicException' => ComicException(message),
    'PdfException' => PdfException(message),
    'PdfEncryptedException' => const PdfEncryptedException(),
    'RangeError' => RangeError(message),
    'FormatException' => FormatException(message),
    'ArgumentError' => ArgumentError(message),
    'FileSystemException' => FileSystemException(message),
    _ => UnsealException(type.isEmpty ? message : '$type: $message'),
  };
}

String _errorType(final Object error) => error.runtimeType.toString();

String _errorMessage(final Object error) {
  if (error is UnsealException) return error.message;
  if (error is FileSystemException) return error.message;
  if (error is FormatException) return error.message;

  // ArgumentError covers RangeError too; its message is dynamic.
  if (error is ArgumentError) {
    final message = error.message;

    return message == null ? error.toString() : '$message';
  }

  return error.toString();
}

final class _IsolateSessionTransport implements SessionTransport {
  _IsolateSessionTransport._(this._isolate, this._replies);

  /// Spawns the session isolate and completes the handshake.
  static Future<_IsolateSessionTransport> open({
    required final Uint8List? bytes,
    required final String? path,
    required final String password,
    required final SessionPolicy policy,
  }) async {
    final replies = ReceivePort();
    final isolate = await Isolate.spawn(
      _isolateMain,
      _SessionBootstrap(replies.sendPort, bytes, path, password, policy),
      errorsAreFatal: true,
    );

    final transport = _IsolateSessionTransport._(isolate, replies);
    final ready = Completer<void>();
    replies.listen((final message) {
      final reply = message as List<Object?>;
      switch (reply[0] as String) {
        case 'ready':
          transport._bind(reply[1]! as SendPort, reply[2]! as Book, reply[3]! as int);
          ready.complete();
        case 'error':
          if (!ready.isCompleted) {
            ready.completeError(rebuildSessionError(reply[1]! as String, reply[2]! as String));
          }
        default:
          transport._onReply(reply);
      }
    }, onDone: () => transport._drain(const SessionClosedException()));

    try {
      await ready.future;
    } on Object {
      isolate.kill(priority: Isolate.immediate);
      replies.close();
      rethrow;
    }

    return transport;
  }

  final Isolate _isolate;
  final ReceivePort _replies;
  SendPort? _port;
  Book? _header;
  int? _byteLength;
  var _nextId = 0;
  var _disposed = false;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  /// The header book handed over during the handshake.
  Book get header => _header!;

  /// The container byte length handed over during the handshake.
  @override
  int get byteLength => _byteLength!;

  void _bind(final SendPort port, final Book header, final int byteLength) {
    _port = port;
    _header = header;
    _byteLength = byteLength;
  }

  Future<Object?> _request(final List<Object> message) {
    if (_disposed) throw const SessionClosedException();

    final port = _port;
    if (port == null) throw const SessionClosedException();

    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    port.send(<Object>[message[0], id, ...message.sublist(1)]);

    return completer.future;
  }

  void _onReply(final List<Object?> reply) {
    final id = reply[1]! as int;
    final completer = _pending.remove(id);
    if (completer == null) return;

    if (reply[0] == 'ok') {
      completer.complete(reply[2]);
    } else {
      completer.completeError(rebuildSessionError(reply[2]! as String, reply[3]! as String));
    }
  }

  void _drain(final UnsealException error) {
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
  }

  @override
  Future<Uint8List?> resource(final String path) async {
    return await _request([_opResource, path]) as Uint8List?;
  }

  @override
  Future<Uint8List?> bytesRange(final int offset, final int count) async {
    return await _request([_opRange, offset, count]) as Uint8List?;
  }

  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) async {
    return await _request([_opResources, paths.toList()]) as Map<String, Uint8List>;
  }

  @override
  Future<String?> documentText(final String path) async {
    return await _request([_opText, path]) as String?;
  }

  @override
  Future<String?> documentSource(final String path) async {
    return await _request([_opSource, path]) as String?;
  }

  @override
  Future<PdfPageText?> pdfLines(final int pageIndex) async {
    return await _request([_opPdfLines, pageIndex]) as PdfPageText?;
  }

  @override
  Future<PdfPageStructure?> pdfStructure(final int pageIndex) async {
    return await _request([_opPdfStructure, pageIndex]) as PdfPageStructure?;
  }

  @override
  Future<SearchResults> search(
    final String query, {
    required final SearchMode mode,
    required final bool isCaseSensitive,
    required final bool isTolerant,
    required final int nearChars,
    required final int contextChars,
    required final int maxMatches,
  }) async {
    return await _request([
          _opSearch,
          query,
          mode.name,
          isCaseSensitive,
          isTolerant,
          nearChars,
          contextChars,
          maxMatches,
        ])
        as SearchResults;
  }

  @override
  Future<BookProgression> computeProgression() async {
    return await _request([_opProgression]) as BookProgression;
  }

  @override
  Future<BookStatistics> computeStatistics() async {
    return await _request([_opStatistics]) as BookStatistics;
  }

  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) async {
    return await _request([_opCfiResolve, cfi]) as EpubCfiLocation?;
  }

  @override
  Future<String> buildCfi({
    required final int contentIndex,
    required final int offsetInText,
  }) async => await _request([_opCfiBuild, contentIndex, offsetInText]) as String;

  @override
  void cancelPending() => _drain(const SessionCancelledException());

  @override
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _isolate.kill(priority: Isolate.immediate);
    _replies.close();
    _drain(const SessionClosedException());
  }
}
