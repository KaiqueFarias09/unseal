import 'dart:isolate';

/// Runs [action] away from the caller when the Dart runtime supports isolates.
Future<T> runInBackground<T>(final T Function() action) async {
  try {
    return await Isolate.run(action);
  } on UnsupportedError {
    return action();
  }
}
