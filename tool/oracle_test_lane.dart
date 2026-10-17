import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Executes a verification lane and retains its command, output and checkpoint.
/// A cached success flag cannot substitute for running the current Dart code.
Map<String, Object?> runOracleDartLane(
  final Directory output,
  final String name,
  final List<String> arguments,
) {
  output.createSync(recursive: true);
  final watch = Stopwatch()..start();
  final result = Process.runSync(Platform.resolvedExecutable, arguments);
  final log = File('${output.path}/$name.log');
  log.writeAsStringSync('${result.stdout}\n${result.stderr}');
  final head = Process.runSync('git', ['rev-parse', 'HEAD']);
  return <String, Object?>{
    'argv': [Platform.resolvedExecutable, ...arguments],
    'head': head.stdout.toString().trim(),
    'exitCode': result.exitCode,
    'elapsedMillis': watch.elapsedMilliseconds,
    'log': log.path,
    'logSha256': sha256.convert(utf8.encode(log.readAsStringSync())).toString(),
  };
}
