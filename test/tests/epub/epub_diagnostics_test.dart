import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/epub.dart';

const _fixturesDirectory = 'test/resources/epub/diagnostics';

void main() {
  test('mixed Unicode and percent escapes resolve paths and fragments', () {
    for (final stem in ['café', '東京', '📚']) {
      final report = diagnoseEpub(
        _zip({
          'mimetype': 'application/epub+zip',
          'META-INF/container.xml': _containerXml,
          'OEBPS/content.opf': _opf(
            manifest:
                '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
                '<item id="ch1" href="$stem%20part.xhtml" media-type="application/xhtml+xml"/>',
            spine: '<itemref idref="ch1"/>',
          ),
          'OEBPS/nav.xhtml': _navXhtml.replaceAll('ch1.xhtml', '$stem%20part.xhtml#caf%C3%A9'),
          'OEBPS/$stem part.xhtml': _ch1Xhtml.replaceAll('id="intro"', 'id="café"'),
        }),
      );
      expect(report.findings, isEmpty, reason: stem);
    }
  });

  test('deep diagnostic XML fails typed before recovery or resource scans', () {
    final nested = '${'<x>' * 129}${'</x>' * 129}';
    for (final target in [
      'META-INF/container.xml',
      'OEBPS/content.opf',
      'OEBPS/nav.xhtml',
      'OEBPS/ch1.xhtml',
    ]) {
      final files = {
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="ch1"/>',
        ),
        'OEBPS/nav.xhtml': _navXhtml.replaceAll('ch1.xhtml', 'ch1.xhtml#intro'),
        'OEBPS/ch1.xhtml': _ch1Xhtml,
      };
      files[target] = files[target]!.replaceFirst('>', '>$nested');
      expect(() => diagnoseEpub(_zip(files)), throwsA(isA<EpubException>()), reason: target);
    }
  });

  group('EPUB diagnostics corpus', () {
    final manifest =
        jsonDecode(File('$_fixturesDirectory/manifest.json').readAsStringSync())
            as Map<String, Object?>;
    final cases = (manifest['cases']! as List<Object?>).cast<Map<String, Object?>>();

    for (final entry in cases) {
      final id = entry['id']! as String;
      final file = entry['file']! as String;
      final expectedRules = (entry['expected_rules']! as List<Object?>).cast<String>();
      final readable = entry['expected_readability'] == 'readable';

      test('$id reports exactly the pre-registered rules', () {
        final bytes = File('$_fixturesDirectory/$file').readAsBytesSync();
        final report = diagnoseEpub(bytes);

        expect(
          report.findings.map((final finding) => finding.ruleId),
          expectedRules,
          reason: '$id should report exactly the pre-registered rules',
        );
        for (final finding in report.findings) {
          expect(finding.severity, EpubDiagnosticSeverity.error);
          expect(finding.reason, isNotEmpty);
        }
        expect(report.truncated, isFalse);
      });

      test('$id reading outcome matches the fixture contract', () {
        final bytes = File('$_fixturesDirectory/$file').readAsBytesSync();
        final readableOutcome = readable ? returnsNormally : throwsA(isA<EpubException>());

        expect(() => parseEpubBook(bytes), readableOutcome);
      });
    }

    test('diagnosis is deterministic across repeated runs', () {
      final bytes = File('$_fixturesDirectory/manifest-resource-missing.epub').readAsBytesSync();
      final first = diagnoseEpub(bytes);
      final second = diagnoseEpub(bytes);

      expect(first.findings.toString(), second.findings.toString());
      expect(first.rootFilePath, second.rootFilePath);
    });
  });

  group('EPUB diagnostics reference resolution', () {
    test('percent-encoded and Unicode hrefs resolve without findings', () {
      final report = diagnoseEpub(_fixture('paths-unicode-percent-valid.epub'));
      expect(report.findings, isEmpty);
      expect(report.rootFilePath, 'OEBPS/content.opf');
    });

    test('parent escapes stay inside the container and are never fetched', () {
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '<item id="ch1" href="../../../../etc/passwd" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="ch1"/>',
        ),
        'OEBPS/nav.xhtml': _navXhtml,
      });

      final report = diagnoseEpub(bytes);
      expect(
        report.findings.map((final finding) => finding.ruleId),
        contains('epub.manifest.resource-missing'),
      );
      final finding = report.findings.firstWhere(
        (final finding) => finding.ruleId == 'epub.manifest.resource-missing',
      );
      expect(finding.resource, 'etc/passwd');
    });

    test('fragment-only navigation links resolve inside their own document', () {
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="ch1"/>',
        ),
        'OEBPS/nav.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<head><title>n</title></head><body>'
            '<nav epub:type="toc"><ol><li><a href="#start">Start</a></li></ol></nav>'
            '<div id="start"/></body></html>',
        'OEBPS/ch1.xhtml': _ch1Xhtml,
      });

      final report = diagnoseEpub(bytes);
      expect(report.findings, isEmpty);
    });
  });

  group('EPUB diagnostics typed failures', () {
    test('safety corruption fails typed before any finding is produced', () {
      expect(
        () => diagnoseEpub(Uint8List.fromList(const [0x50, 0x4b, 0x03, 0x04])),
        throwsA(isA<UnsealException>()),
      );
    });

    test('a malformed package document fails typed', () {
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': '<package><manifest>',
      });

      expect(() => diagnoseEpub(bytes), throwsA(isA<EpubException>()));
    });
  });

  group('EPUB diagnostics limits', () {
    test('maxFindings stops collection and flags truncation', () {
      final items = [
        for (var index = 0; index < 30; index++)
          '<item id="ghost$index" href="ghost$index.png" media-type="image/png"/>',
      ].join();
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '$items',
          spine: '',
        ),
        'OEBPS/nav.xhtml': _navXhtml,
      });

      final report = diagnoseEpub(bytes, options: const EpubDiagnosticsOptions(maxFindings: 5));
      expect(report.findings, hasLength(5));
      expect(report.truncated, isTrue);
      expect(report.errorCount, 5);
    });

    test('maxNavigationLinks stops link resolution and flags truncation', () {
      final links = [
        for (var index = 0; index < 20; index++)
          '<li><a href="ghost$index.xhtml">Ghost $index</a></li>',
      ].join();
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="ch1"/>',
        ),
        'OEBPS/nav.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<head><title>n</title></head><body>'
            '<nav epub:type="toc"><ol>$links</ol></nav></body></html>',
      });

      final report = diagnoseEpub(
        bytes,
        options: const EpubDiagnosticsOptions(maxNavigationLinks: 4),
      );
      expect(
        report.findings.where(
          (final finding) => finding.ruleId == 'epub.navigation.link-unresolved',
        ),
        hasLength(4),
      );
      expect(report.truncated, isTrue);
    });

    test('fragment checks skip oversized documents with truncation', () {
      final large =
          '<html xmlns="http://www.w3.org/1999/xhtml"><head>'
          '<title>${'x' * (2 << 20)}</title></head><body></body></html>';
      final bytes = _zip({
        'mimetype': 'application/epub+zip',
        'META-INF/container.xml': _containerXml,
        'OEBPS/content.opf': _opf(
          manifest:
              '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
              '<item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>',
          spine: '<itemref idref="ch1"/>',
        ),
        'OEBPS/nav.xhtml':
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<head><title>n</title></head><body>'
            '<nav epub:type="toc"><ol><li><a href="ch1.xhtml#absent">c</a></li></ol></nav>'
            '</body></html>',
        'OEBPS/ch1.xhtml': large,
      });

      final report = diagnoseEpub(bytes);
      expect(
        report.findings.where(
          (final finding) => finding.ruleId == 'epub.navigation.fragment-unresolved',
        ),
        isEmpty,
      );
      expect(report.truncated, isTrue);
    });
  });
}

Uint8List _fixture(final String file) => File('$_fixturesDirectory/$file').readAsBytesSync();

Uint8List _zip(final Map<String, String> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = switch (entry.key) {
      'mimetype' => latin1.encode(entry.value),
      _ => utf8.encode(entry.value),
    };
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes)..lastModTime = 946684800);
  }

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

const _containerXml =
    '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
    '<rootfiles><rootfile full-path="OEBPS/content.opf" '
    'media-type="application/oebps-package+xml"/></rootfiles></container>';

String _opf({required final String manifest, required final String spine}) =>
    '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" '
    'unique-identifier="pub-id"><metadata '
    'xmlns:dc="http://purl.org/dc/elements/1.1/">'
    '<dc:identifier id="pub-id">urn:uuid:1f0a3c5e-6d3a-4f0a-9c5e-000000000001</dc:identifier>'
    '<dc:title>t</dc:title><dc:language>en</dc:language>'
    '<meta property="dcterms:modified">2026-10-17T00:00:00Z</meta>'
    '</metadata><manifest>$manifest</manifest><spine>$spine</spine></package>';

const _navXhtml =
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>n</title></head><body>'
    '<nav epub:type="toc"><ol><li><a href="ch1.xhtml">c</a></li></ol></nav>'
    '</body></html>';

const _ch1Xhtml =
    '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c</title></head>'
    '<body><p id="intro">x</p></body></html>';
