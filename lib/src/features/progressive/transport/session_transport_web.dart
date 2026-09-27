import 'dart:async';
import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/exceptions/unseal_exception.dart';
import '../../../platform/web/worker_client.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../reading/book_progression.dart';
import '../../search/entities/search_mode.dart';
import '../../search/entities/search_results.dart';
import '../session_engine.dart';
import '../session_policy.dart';
import 'session_transport.dart';

/// Opens a session on the web.
///
/// The engine runs in the shared unseal Web Worker when one is
/// configured; without one (unconfigured, broken, or blocked by the
/// host) the engine runs inline in the caller, so the public contract
/// never depends on worker availability. Paths have no web source,
/// mirroring `Unseal.readFile`.
Future<(SessionTransport, Book)> openSessionTransport({
  required final Uint8List? bytes,
  required final String? path,
  required final SessionPolicy policy,
}) async {
  if (path != null) throw UnsupportedError('Opening a book from a path is not supported on web');

  final client = WorkerClient.instance;
  final header = await client.sessionOpenInWorker(bytes!, policy: policy);
  if (header != null) return (_WorkerSessionTransport(client), header);

  final engine = SessionEngine.openBytes(bytes, policy: policy);

  return (InlineSessionTransport(engine), engine.book);
}

/// Transport driving the session engine resident in the shared web
/// worker. The worker serves one message at a time, so requests
/// pipelined before a `dispose` still complete with their data; every
/// request this transport has not yet observed completes typed when
/// [dispose] or [cancelPending] lands, like the isolate transport.
final class _WorkerSessionTransport implements SessionTransport {
  _WorkerSessionTransport(this._client);

  final WorkerClient _client;
  var _disposed = false;
  var _nextRequest = 0;
  final Map<int, void Function(UnsealException error)> _pending =
      <int, void Function(UnsealException error)>{};

  Future<T> _dispatch<T>(final Future<T> Function() issue) {
    if (_disposed) throw const SessionClosedException();

    final request = _nextRequest++;
    final completer = Completer<T>();
    _pending[request] = (final UnsealException error) {
      if (!completer.isCompleted) completer.completeError(error);
    };
    unawaited(
      issue()
          .then(
            (final T value) {
              if (!completer.isCompleted) completer.complete(value);
            },
            onError: (final Object error, final StackTrace stackTrace) {
              if (!completer.isCompleted) completer.completeError(error, stackTrace);
            },
          )
          .whenComplete(() {
            _pending.remove(request);
          }),
    );

    return completer.future;
  }

  void _drain(final UnsealException error) {
    for (final fail in _pending.values) {
      fail(error);
    }
    _pending.clear();
  }

  @override
  Future<Uint8List?> resource(final String path) {
    return _dispatch(() => _client.sessionResourceInWorker(path));
  }

  @override
  Future<Map<String, Uint8List>> resources(final Set<String> paths) {
    return _dispatch(() => _client.sessionResourcesInWorker(paths));
  }

  @override
  Future<String?> documentText(final String path) {
    return _dispatch(() => _client.sessionTextInWorker(path));
  }

  @override
  Future<String?> documentSource(final String path) {
    return _dispatch(() => _client.sessionSourceInWorker(path));
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
  }) {
    return _dispatch(
      () => _client.sessionSearchInWorker(
        query,
        mode: mode,
        isCaseSensitive: isCaseSensitive,
        isTolerant: isTolerant,
        nearChars: nearChars,
        contextChars: contextChars,
        maxMatches: maxMatches,
      ),
    );
  }

  @override
  Future<BookProgression> computeProgression() => _dispatch(_client.sessionProgressionInWorker);

  @override
  Future<BookStatistics> computeStatistics() => _dispatch(_client.sessionStatisticsInWorker);

  @override
  Future<EpubCfiLocation?> resolveCfi(final String cfi) {
    return _dispatch(() => _client.sessionResolveCfiInWorker(cfi));
  }

  @override
  Future<String> buildCfi({required final int contentIndex, required final int offsetInText}) {
    return _dispatch(
      () => _client.sessionBuildCfiInWorker(contentIndex: contentIndex, offsetInText: offsetInText),
    );
  }

  @override
  void cancelPending() => _drain(const SessionCancelledException());

  @override
  void dispose() {
    if (_disposed) return;

    _disposed = true;
    _client.sessionDisposeInWorker();
    _drain(const SessionClosedException());
  }
}
