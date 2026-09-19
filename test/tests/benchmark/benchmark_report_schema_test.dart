// Contract test: the benchmark harness's own JSON output must conform
// to the tracked schema (benchmark/benchmark_report.schema.json).
//
// The test records a tiny benchmark (an ok row and a fail row) through
// the real contract module, writes a report exactly like a suite run
// would, then validates the document against the schema with a small
// validator covering the schema features the file uses (type, const,
// enum, required, properties, items, $ref, additionalProperties).

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../../benchmark/json_report.dart' as contract;

void main() {
  final schemaFile = File('benchmark/benchmark_report.schema.json');
  test('tracked schema file exists and parses', () {
    expect(schemaFile.existsSync(), isTrue, reason: 'benchmark_report.schema.json must be tracked');
    final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, Object?>;
    expect(schema[r'$schema'], contains('json-schema.org'));
  });

  test('a tiny benchmark run validates against the schema', () {
    final schema = jsonDecode(schemaFile.readAsStringSync()) as Map<String, Object?>;
    final directory = Directory.systemTemp.createTempSync('unseal_schema_test');
    addTearDown(() => directory.deleteSync(recursive: true));
    final reportPath = '${directory.path}/report.json';

    // Reset module state and record one ok row and one fail row — the
    // smallest possible "run".
    contract.resetForTest();
    contract.quickModeEnabled = true;
    contract.recordResult(
      suite: 'unseal',
      scenario: 'tiny — ok row',
      iterations: 3,
      warmup: 6,
      medianMicros: 12.5,
      p95Micros: 14.0,
      checksum: 7,
      fixtureId: 'FORMAT-ODT',
      sizeBytes: 100,
      meanMicros: 13.0,
      minMicros: 11.0,
      maxMicros: 15.0,
      note: 'tiny',
    );
    contract.recordResult(
      suite: 'unseal',
      scenario: 'tiny — fail row',
      iterations: 0,
      warmup: 1,
      medianMicros: 0,
      p95Micros: 0,
      checksum: 9,
      error: {'type': 'SomeException', 'phase': 'parse'},
    );
    contract.jsonMode = contract.JsonMode.file;
    contract.jsonOutputPath = reportPath;
    contract.writeJsonReport();

    final document = jsonDecode(File(reportPath).readAsStringSync()) as Map<String, Object?>;
    final problems = validate(document, schema);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('contract fields keep their stable key order', () {
    final document = _recordSample;
    const requiredOrder = <String>[
      'schemaVersion',
      'suite',
      'scenario',
      'platform',
      'sdk',
      'commit',
      'fixtureId',
      'sizeBytes',
      'iterations',
      'warmupIterations',
      'medianMicros',
      'p95Micros',
      'throughputPerSecond',
      'checksum',
      'status',
    ];
    final keys = document.keys.toList();
    for (var i = 0; i < requiredOrder.length; i++) {
      expect(
        keys[i],
        requiredOrder[i],
        reason:
            'contract key $i must be ${requiredOrder[i]} — stable order is part of the contract',
      );
    }
  });
}

Map<String, Object?> get _recordSample {
  contract.resetForTest();
  contract.recordResult(
    suite: 'unseal',
    scenario: 'order — probe',
    iterations: 1,
    warmup: 1,
    medianMicros: 1,
    p95Micros: 1,
    checksum: 1,
    processedBytes: 0,
  );
  return contract.collectedRecords().single;
}

// --- minimal JSON Schema validator (the subset the schema uses) ---

List<String> validate(final Object? document, final Map<String, Object?> schema) {
  return _validateAt(document, schema, r'#', schema);
}

List<String> _validateAt(
  final Object? value,
  final Map<String, Object?> schema,
  final String at,
  final Map<String, Object?> root,
) {
  final problems = <String>[];
  final type = schema['type'] as String?;
  final ref = schema[r'$ref'] as String?;
  if (ref != null) {
    final target = _resolveRef(root, ref);
    return _validateAt(value, target, at, root);
  }
  if (schema.containsKey('const')) {
    if (value != schema['const']) {
      problems.add('$at: expected const ${schema['const']}, got $value');
    }
  }
  if (schema.containsKey('enum')) {
    final allowed = schema['enum']! as List<Object?>;
    if (!allowed.contains(value)) {
      problems.add('$at: $value is not one of ${allowed.join(', ')}');
    }
  }
  if (type != null && !_matchesType(value, type)) {
    problems.add('$at: expected $type, got ${value.runtimeType}');
    return problems;
  }
  if (type == 'object' || schema.containsKey('properties')) {
    final properties = (schema['properties'] ?? <String, Object?>{}) as Map<String, Object?>;
    for (final entry in properties.entries) {
      if ((value as Map<String, Object?>).containsKey(entry.key)) {
        problems.addAll(
          _validateAt(
            value[entry.key],
            entry.value! as Map<String, Object?>,
            '$at/${entry.key}',
            root,
          ),
        );
      }
    }
    for (final required in (schema['required'] as List<Object?>? ?? <Object?>[])) {
      if (!(value as Map<String, Object?>).containsKey(required)) {
        problems.add('$at: missing required property "$required"');
      }
    }
    final additional = schema['additionalProperties'];
    if (additional == false) {
      for (final key in (value as Map<String, Object?>).keys) {
        if (!properties.containsKey(key)) {
          problems.add('$at: additional property "$key" is not allowed');
        }
      }
    }
  }
  if (type == 'array') {
    final items = schema['items'] as Map<String, Object?>?;
    if (items != null) {
      var index = 0;
      for (final item in value! as List<Object?>) {
        problems.addAll(_validateAt(item, items, '$at[$index]', root));
        index++;
      }
    }
  }
  return problems;
}

Map<String, Object?> _resolveRef(final Map<String, Object?> schema, final String ref) {
  expect(ref, startsWith('#/definitions/'), reason: 'only local definitions are used');
  final definitions = schema['definitions']! as Map<String, Object?>;
  return definitions[ref.split('/').last]! as Map<String, Object?>;
}

bool _matchesType(final Object? value, final String type) {
  switch (type) {
    case 'object':
      return value is Map<String, Object?>;
    case 'array':
      return value is List<Object?>;
    case 'string':
      return value is String;
    case 'integer':
      return value is int;
    case 'number':
      return value is num;
    case 'boolean':
      return value is bool;
    default:
      return true;
  }
}
