/// Runs [action] on the current isolate for web runtimes.
Future<T> runInBackground<T>(final T Function() action) async => action();
