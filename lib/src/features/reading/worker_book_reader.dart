import 'package:e_livre/src/platform/web/worker_client.dart'
    if (dart.library.io) 'package:e_livre/src/platform/io/worker_client.dart';

/// Routes web parsing through a dedicated web worker so heavy books
/// never block the UI thread.
///
/// Point it at the compiled worker script once at startup (see
/// `web/e_livre_worker.dart` in the package sources for the entry
/// point and its build command):
///
/// ```dart
/// WorkerBookReader.configure(Uri.parse('e_livre_worker.js'));
/// ```
///
/// From then on `BookReader.openFromBytes` and
/// `BookReader.readMetadataFromBytes` run inside the worker. Books
/// that fail to parse throw exactly like the inline path; if the
/// worker itself is unavailable (script unreachable, workers blocked
/// by the host), parsing silently falls back to the main thread.
///
/// Native runtimes ignore the configuration: parsing already runs on
/// a background isolate there.
abstract final class WorkerBookReader {
  /// Points the reader at a compiled [workerScript]. Must be
  /// same-origin unless served with proper CORS worker headers.
  static void configure(final Uri workerScript) {
    WorkerClient.instance.configure(workerScript);
  }

  /// Whether a worker script is configured and the worker has not
  /// broken; parse requests still fall back to inline when `false`.
  static bool get isConfigured => WorkerClient.instance.isConfigured;

  /// Terminates the worker and forgets the configuration.
  static void dispose() {
    WorkerClient.instance.dispose();
  }
}
