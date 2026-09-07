import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

const _idpfAlgorithm = 'http://www.idpf.org/2008/embedding';
const _adobeAlgorithm = 'http://ns.adobe.com/pdf/enc#RC';
const _drmAlgorithm = 'http://www.w3.org/2001/04/xmlenc#aes256-cbc';
const _uuid = 'urn:uuid:12345678-1234-1234-1234-123456789abc';

void main() {
  group('EPUB Calibre regressions', () {
    test('classifies text/html manifest items as readable chapters', () {
      final book = _parse(
        opf: _opf(chapterMediaType: 'text/html; charset=UTF-8'),
        entries: {'OEBPS/chapter.xhtml': _chapter('HTML chapter')},
      );

      expect(book.files.html, hasLength(1));
      expect(book.files.html.single.content, contains('HTML chapter'));
    });

    test('selects the first existing supported rootfile', () {
      final archive = _archive({
        'META-INF/container.xml': _container(
          '<rootfile full-path="missing.pdf" media-type="application/pdf"/>'
          '<rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>',
        ),
        'OEBPS/content.opf': _opf(),
        'OEBPS/chapter.xhtml': _chapter('Rootfile chapter'),
      });

      expect(getEpubRootFilePath(archive), 'OEBPS/content.opf');
      final book = parseEpubArchive(archive);
      expect(book.title, 'Regression');
      expect(book.files.html.single.content, contains('Rootfile chapter'));
    });

    test('decodes UTF-16 container, OPF, navigation and XHTML documents', () {
      final archive = _archive({
        'META-INF/container.xml': _utf16(
          _container(
            '<rootfile full-path="OEBPS/content.opf" '
            'media-type="application/oebps-package+xml"/>',
          ),
          littleEndian: true,
        ),
        'OEBPS/content.opf': _utf16(_opf(version: '3.0', includeNav: true), littleEndian: false),
        'OEBPS/chapter.xhtml': _utf16(_chapter('UTF-16 chapter'), littleEndian: true),
        'OEBPS/nav.xhtml': _utf16(_nav('UTF-16 chapter'), littleEndian: false),
      });

      final book = parseEpubArchive(archive);
      final chapter = book.files.html.firstWhere(
        (final file) => file.content.contains('UTF-16 chapter'),
      );

      expect(book.title, 'Regression');
      expect(chapter.content, contains('UTF-16 chapter'));
      expect(book.navigation.navPoints.single.label, 'UTF-16 chapter');
    });

    test('keeps chapters readable when navigation is absent', () {
      final archive = _archive({
        'META-INF/container.xml': _container(
          '<rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/>',
        ),
        'OEBPS/content.opf': _opf(includeToc: false),
        'OEBPS/chapter.xhtml': _chapter('No TOC chapter'),
      });

      final book = parseEpubArchive(archive);

      expect(book.files.html.single.content, contains('No TOC chapter'));
      expect(book.navigation.navPoints, isEmpty);
    });

    test('falls back from a stale NCX to the EPUB 3 navigation document', () {
      final archive = _archive({
        'META-INF/container.xml': _container(
          '<rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/>',
        ),
        'OEBPS/content.opf': _opf(version: '3.0', spineToc: 'ncx', includeNav: true),
        'OEBPS/chapter.xhtml': _chapter('EPUB 3 chapter'),
        'OEBPS/nav.xhtml': _nav('EPUB 3 chapter'),
      });

      final book = parseEpubArchive(archive);
      final chapter = book.files.html.firstWhere(
        (final file) => file.content.contains('EPUB 3 chapter'),
      );

      expect(book.navigation.navPoints, hasLength(1));
      expect(book.navigation.navPoints.single.label, 'EPUB 3 chapter');
      expect(chapter.content, contains('EPUB 3 chapter'));
    });

    test('deobfuscates IDPF fonts using the package identifier', () {
      final original = _fontBytes();
      final key = sha1.convert(convert.utf8.encode(_uuid)).bytes;
      final obfuscated = _obfuscate(original, key, 1040);
      final book = _fontBook(algorithm: _idpfAlgorithm, fontBytes: obfuscated);

      expect(book.files.fonts.single.content, orderedEquals(original));
    });

    test('deobfuscates Adobe fonts using UUID identifier bytes', () {
      final original = _fontBytes();
      final obfuscated = _obfuscate(original, _uuidBytes(_uuid), 1024);
      final book = _fontBook(algorithm: _adobeAlgorithm, fontBytes: obfuscated);

      expect(book.files.fonts.single.content, orderedEquals(original));
    });

    test('rejects encryption algorithms outside font obfuscation', () {
      final archive = _archive({
        'META-INF/container.xml': _container(
          '<rootfile full-path="OEBPS/content.opf" '
          'media-type="application/oebps-package+xml"/>',
        ),
        'META-INF/encryption.xml': _encryption(_drmAlgorithm),
        'OEBPS/content.opf': _opf(),
        'OEBPS/chapter.xhtml': _chapter('Encrypted chapter'),
      });

      expect(() => parseEpubArchive(archive), throwsA(isA<EpubException>()));
    });

    test('discovers a valid OPF when container.xml is absent', () {
      final archive = _archive({
        'OEBPS/content.opf': _opf(),
        'OEBPS/chapter.xhtml': _chapter('Fallback chapter'),
      });

      expect(findEpubRootFilePath(archive), 'OEBPS/content.opf');
      final explicit = parseEpubArchive(archive, rootFilePath: 'OEBPS/content.opf');
      final automatic = parseEpubArchive(archive);

      expect(explicit.files.html.single.content, contains('Fallback chapter'));
      expect(automatic.files.html.single.content, contains('Fallback chapter'));
    });

    test('BookReader does not misclassify an EPUB without container.xml as CBZ', () {
      final bytes = _zip({
        'OEBPS/content.opf': _opf(),
        'OEBPS/chapter.xhtml': _chapter('Dispatcher fallback chapter'),
      });

      final book = BookReader.parseBook(bytes);
      final metadata = BookReader.readMetadataSync(bytes);

      expect(book.format, BookFormat.epub);
      expect(book.files.html.single.content, contains('Dispatcher fallback chapter'));
      expect(metadata.format, BookFormat.epub);
      expect(metadata.title, 'Regression');
    });
  });
}

EpubBook _parse({required final String opf, required final Map<String, Object> entries}) {
  return parseEpubBook(
    _zip({
      'META-INF/container.xml': _container(
        '<rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/>',
      ),
      'OEBPS/content.opf': opf,
      ...entries,
    }),
  );
}

EpubBook _fontBook({required final String algorithm, required final List<int> fontBytes}) {
  final archive = _archive({
    'META-INF/container.xml': _container(
      '<rootfile full-path="OEBPS/content.opf" '
      'media-type="application/oebps-package+xml"/>',
    ),
    'META-INF/encryption.xml': _encryption(algorithm),
    'OEBPS/content.opf': _opf(includeFont: true),
    'OEBPS/chapter.xhtml': _chapter('Font chapter'),
    'OEBPS/font.ttf': fontBytes,
  });

  return parseEpubArchive(archive);
}

Archive _archive(final Map<String, Object> entries) {
  final archive = Archive();
  for (final entry in entries.entries) {
    final bytes = _entryBytes(entry.value, entry.key);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }

  return archive;
}

List<int> _entryBytes(final Object value, final String path) {
  if (value is String) return convert.utf8.encode(value);
  if (value is List<int>) return value;

  throw ArgumentError('Unsupported fixture entry $path');
}

Uint8List _zip(final Map<String, Object> entries) {
  return Uint8List.fromList(ZipEncoder().encode(_archive(entries))!);
}

String _container(final String rootfiles) {
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">'
      '<rootfiles>$rootfiles</rootfiles></container>';
}

String _opf({
  final String version = '2.0',
  final String chapterMediaType = 'application/xhtml+xml',
  final bool includeToc = true,
  final String? spineToc,
  final bool includeNav = false,
  final bool includeFont = false,
}) {
  final toc = spineToc ?? (includeToc ? 'ncx' : null);
  final manifest = StringBuffer()
    ..write('<item id="chapter" href="chapter.xhtml" media-type="$chapterMediaType"/>');
  if (includeToc || spineToc != null) {
    manifest.write('<item id="ncx" href="missing.ncx" media-type="application/x-dtbncx+xml"/>');
  }
  if (includeNav) {
    manifest.write(
      '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>',
    );
  }
  if (includeFont) {
    manifest.write('<item id="font" href="font.ttf" media-type="font/ttf"/>');
  }

  final spineAttribute = toc == null ? '' : ' toc="$toc"';
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<package xmlns="http://www.idpf.org/2007/opf" version="$version" '
      'unique-identifier="uid">'
      '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
      '<dc:title>Regression</dc:title><dc:language>en</dc:language>'
      '<dc:identifier id="uid">$_uuid</dc:identifier></metadata>'
      '<manifest>$manifest</manifest><spine$spineAttribute><itemref idref="chapter"/>'
      '</spine></package>';
}

String _chapter(final String title) {
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>$title</title></head>'
      '<body><h1>$title</h1></body></html>';
}

String _nav(final String title) {
  return '<?xml version="1.0" encoding="UTF-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" '
      'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>'
      '<body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">$title</a></li></ol>'
      '</nav></body></html>';
}

String _encryption(final String algorithm) {
  return '<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
      '<EncryptedData xmlns="http://www.w3.org/2001/04/xmlenc#">'
      '<EncryptionMethod Algorithm="$algorithm"/><CipherData>'
      '<CipherReference URI="OEBPS/font.ttf"/></CipherData></EncryptedData></encryption>';
}

Uint8List _fontBytes() {
  final bytes = Uint8List(2048);
  bytes.setRange(0, 4, const [0, 1, 0, 0]);
  for (var i = 4; i < bytes.length; i++) {
    bytes[i] = i & 0xff;
  }

  return bytes;
}

Uint8List _obfuscate(final List<int> bytes, final List<int> key, final int extent) {
  final output = Uint8List.fromList(bytes);
  for (var i = 0; i < output.length && i < extent; i++) {
    output[i] ^= key[i % key.length];
  }

  return output;
}

Uint8List _uuidBytes(final String value) {
  final hex = value.substring(value.lastIndexOf(':') + 1).replaceAll('-', '');
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

Uint8List _utf16(final String value, {required final bool littleEndian}) {
  final units = value.codeUnits;
  final bytes = Uint8List(2 + units.length * 2);
  if (littleEndian) {
    bytes.setRange(0, 2, const [0xff, 0xfe]);
  } else {
    bytes.setRange(0, 2, const [0xfe, 0xff]);
  }
  for (var i = 0; i < units.length; i++) {
    final offset = 2 + i * 2;
    final unit = units[i];
    if (littleEndian) {
      bytes[offset] = unit & 0xff;
      bytes[offset + 1] = unit >> 8;
    } else {
      bytes[offset] = unit >> 8;
      bytes[offset + 1] = unit & 0xff;
    }
  }

  return bytes;
}
