import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../tool/fuzz/cfi_strings.dart';
import '../../tool/generate_fuzz_fixtures.dart';

void main() {
  group('generated fuzz fixture reproducibility', () {
    test('building the plan twice yields byte-identical fixtures', () {
      final first = buildCorpusPlan();
      final second = buildCorpusPlan();
      expect(first.length, second.length);
      for (var i = 0; i < first.length; i++) {
        expect(
          first[i].bytes,
          hasLength(second[i].bytes.length),
          reason: 'length drift at ${first[i].relativePath}',
        );
        expect(bytesEqual(first[i].bytes, second[i].bytes), isTrue, reason: first[i].relativePath);
      }
    });

    test('committed files match the regenerated plan byte-for-byte', () {
      final plan = buildCorpusPlan();
      expect(plan, isNotEmpty);
      for (final fixture in plan) {
        final file = File('$defaultOutputRoot/${fixture.relativePath}');
        expect(file.existsSync(), isTrue, reason: '${fixture.relativePath} is not committed');
        expect(
          bytesEqual(file.readAsBytesSync(), fixture.bytes),
          isTrue,
          reason:
              '${fixture.relativePath} drifted from the generator; '
              'run dart run tool/generate_fuzz_fixtures.dart and commit the refresh',
        );
      }
    });

    test('every book-shaped generated fixture parses into readable content', () {
      final bookFixtures = buildCorpusPlan().where(
        (final f) =>
            f.relativePath.endsWith('.epub') ||
            f.relativePath.endsWith('.mobi') ||
            f.relativePath.endsWith('.pdf'),
      );
      expect(bookFixtures.length, greaterThanOrEqualTo(11));
      for (final fixture in bookFixtures) {
        final book = Unseal.parse(fixture.bytes);
        expect(book.readingOrder, isNotEmpty, reason: fixture.relativePath);
        expect(
          book.readingOrder.every((final item) => item.name.trim().isNotEmpty),
          isTrue,
          reason: fixture.relativePath,
        );
      }
    });

    test('cfi case corpus is labeled and non-trivial', () {
      final payload = buildCfiCaseJson(42);
      expect(payload, hasLength(greaterThan(400)));
      // The committed JSON must equal the generator output for the same seed.
      final committed = File('$defaultOutputRoot/cfi/cfi-cases.json').readAsBytesSync();
      expect(bytesEqual(committed, payload), isTrue);
    });
  });
}
