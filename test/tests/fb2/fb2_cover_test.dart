import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

// 1x1 transparent PNG binary as base64.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
final Uint8List _pngBytes = Uint8List.fromList(base64.decode(_pngBase64));

void main() {
  group('coverpage references resolve on the metadata fast path', () {
    for (final attr in const <String>['l:href', 'xlink:href', 'fb:href', 'href']) {
      test('`<image $attr="#cover">` resolves the embedded binary', () {
        final bytes = _fb2Bytes(imageAttrs: <String>['$attr="#cover"']);

        final metadata = readFb2Metadata(bytes);
        expect(metadata.cover, isNotNull);
        expect(metadata.cover!.type, ImageType.png);
        expect(metadata.cover!.bytes, _pngBytes);

        // The fast path agrees with the full parse.
        expect(metadata.cover!.bytes, parseFb2Book(bytes).cover.content);
      });
    }

    test('the fast path resolves the cover without a full parse', () {
      // The body is truncated, so the full parse cannot build a DOM;
      // succeeding anyway proves the sliced fast path served the cover.
      final bytes = _truncatedFb2Bytes(imageAttrs: <String>['xlink:href="#cover"']);

      expect(() => parseFb2Book(bytes), throwsA(isA<Fb2Exception>()));

      final metadata = readFb2Metadata(bytes);
      expect(metadata.title, 'Cover Book');
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.bytes, _pngBytes);
    });
  });

  group('coverpage edge cases', () {
    test('a document without a coverpage yields no cover and no crash', () {
      final metadata = readFb2Metadata(_fb2Bytes(imageAttrs: const <String>[]));

      expect(metadata.title, 'Cover Book');
      expect(metadata.cover, isNull);
    });

    test('a multi-part coverpage resolves the first image, like the full parse', () {
      const String otherBase64 =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgAD'
          'Njd8qAAAAABJRU5ErkJggg==';
      final bytes = _fb2Bytes(
        imageAttrs: const <String>['xlink:href="#primary"', 'l:href="#secondary"'],
        binaries: <String, String>{'primary': _pngBase64, 'secondary': otherBase64},
      );

      final metadata = readFb2Metadata(bytes);
      expect(metadata.cover, isNotNull);
      expect(metadata.cover!.bytes, _pngBytes);
      expect(metadata.cover!.bytes, parseFb2Book(bytes).cover.content);
    });

    test('a dangling coverpage reference yields no cover and no crash', () {
      final bytes = _fb2Bytes(imageAttrs: <String>['l:href="#missing"']);

      final metadata = readFb2Metadata(bytes);
      expect(metadata.title, 'Cover Book');
      expect(metadata.cover, isNull);
    });
  });
}

Uint8List _fb2Bytes({
  required final List<String> imageAttrs,
  final Map<String, String> binaries = const <String, String>{'cover': _pngBase64},
}) {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>')
    ..write('<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" ')
    ..write('xmlns:l="http://www.w3.org/1999/xlink" ')
    ..write('xmlns:xlink="http://www.w3.org/1999/xlink">')
    ..write('<description><title-info><book-title>Cover Book</book-title>');
  if (imageAttrs.isNotEmpty) {
    buffer.write('<coverpage>');
    for (final attr in imageAttrs) {
      buffer.write('<image $attr/>');
    }
    buffer.write('</coverpage>');
  }
  buffer.write('</title-info></description>');
  for (final entry in binaries.entries) {
    buffer
      ..write('<binary id="${entry.key}" content-type="image/png">')
      ..write(entry.value)
      ..write('</binary>');
  }
  buffer
    ..write('<body><section><p>Body text.</p></section></body>')
    ..write('</FictionBook>');

  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

/// Builds a document whose `<description>` and `<binary>` slices are
/// intact but whose body never closes, so the full XML parse fails.
Uint8List _truncatedFb2Bytes({required final List<String> imageAttrs}) {
  final head = _fb2Bytes(imageAttrs: imageAttrs);
  final text = utf8.decode(head);
  const String tail = '<body><section><p>Never closed';

  return Uint8List.fromList(utf8.encode('${text.substring(0, text.lastIndexOf("<body>"))}$tail'));
}
