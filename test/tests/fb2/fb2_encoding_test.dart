import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

const String pushkinTitle = 'Капитанская дочка';
const String pushkinAuthor = 'Александр Пушкин';
const String pushkinBody = '«Береги честь смолоду.» — гласит пословица. Ёлка, ёж, щука и объятие.';
const String strangerTitle = "L'Étranger à côté";
const String strangerBody = 'Déjà été, très près de la mer où çà et là nagent des ânes.';
const String arabicTitle = 'كتاب العرب';
const String arabicBody = 'هذا نص عربي للتجربة في المكتبة، وهو كتاب عن تاريخ الأدب.';

void main() {
  group('declared encodings are honoured', () {
    test('windows-1251 document decodes Cyrillic', () {
      final book = parseFb2Book(
        _cp1251(_fb2(encoding: 'windows-1251', title: pushkinTitle, body: pushkinBody)),
      );

      expect(book.metadata.title, pushkinTitle);
      expect(book.metadata.authors, [pushkinAuthor]);
      expect(book.files.html.first.content, contains('Береги честь смолоду.'));
      expect(book.files.html.first.content, isNot(contains('\uFFFD')));
    });

    test('windows-1251 metadata fast path decodes Cyrillic', () {
      final metadata = readFb2Metadata(
        _cp1251(_fb2(encoding: 'windows-1251', title: pushkinTitle, body: pushkinBody)),
      );

      expect(metadata.title, pushkinTitle);
      expect(metadata.authors, [pushkinAuthor]);
    });

    test('windows-1252 document decodes accented Latin', () {
      final book = parseFb2Book(
        _cp1252(
          _fb2(encoding: 'windows-1252', title: strangerTitle, body: strangerBody, author: ''),
        ),
      );

      expect(book.metadata.title, strangerTitle);
      expect(book.files.html.first.content, contains('Déjà été'));
    });

    test('windows-1256 document decodes Arabic', () {
      final book = parseFb2Book(
        _cp1256(_fb2(encoding: 'windows-1256', title: arabicTitle, body: arabicBody, author: '')),
      );

      expect(book.metadata.title, arabicTitle);
      expect(book.files.html.first.content, contains('عن تاريخ الأدب'));
    });

    test('utf-8 document decodes Cyrillic', () {
      final book = parseFb2Book(
        _utf8(_fb2(encoding: 'utf-8', title: pushkinTitle, body: pushkinBody)),
      );

      expect(book.metadata.title, pushkinTitle);
      expect(book.metadata.authors, [pushkinAuthor]);
    });

    test('declared UTF-16 with a BOM decodes the full document', () {
      final bytes = _utf16le(_fb2(encoding: 'UTF-16', title: pushkinTitle, body: pushkinBody));
      final withBom = Uint8List.fromList(<int>[0xFF, 0xFE, ...bytes]);

      final book = parseFb2Book(withBom);
      final metadata = readFb2Metadata(withBom);

      expect(book.metadata.title, pushkinTitle);
      expect(book.files.html.first.content, contains('Береги честь смолоду.'));
      expect(metadata.title, pushkinTitle);
    });

    test('preserves stylesheets and named styles in the generated files', () {
      const String doc =
          '<?xml version="1.0" encoding="utf-8"?>'
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
          '<description><title-info><book-title>Styled</book-title></title-info></description>'
          '<stylesheet type="text/css">style[name="warning"] { color: red; }</stylesheet>'
          '<body><section><p><style name="warning">Danger</style></p></section></body>'
          '</FictionBook>';

      final book = parseFb2Book(_utf8(doc));
      final html = book.files.html.single.content;
      final css = book.files.css.single;

      expect(book.files.css, hasLength(1));
      expect(css.name, 'styles.css');
      expect(css.content, contains('.warning'));
      expect(css.content, isNot(contains('style[name')));
      expect(html, contains('href="styles.css"'));
      expect(html, contains('<span class="warning">Danger</span>'));
    });

    test('us-ascii declaration is honoured', () {
      const String asciiDoc =
          '<?xml version="1.0" encoding="us-ascii"?>'
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
          '<description><title-info><book-title>Plain</book-title></title-info></description>'
          '<body><section><p>Plain text.</p></section></body></FictionBook>';

      expect(parseFb2Book(_utf8(asciiDoc)).metadata.title, 'Plain');
    });
  });

  group('documents without a declaration', () {
    test('cp1251 bytes are detected as windows-1251', () {
      final bytes = _cp1251(_fb2(encoding: null, title: pushkinTitle, body: pushkinBody));
      expect(sniffXmlEncoding(bytes), XmlEncoding.cp1251);

      final book = parseFb2Book(bytes);
      expect(book.metadata.title, pushkinTitle);
      expect(book.files.html.first.content, contains('Ёлка, ёж, щука'));
    });

    test('utf-8 bytes take the strict path', () {
      final bytes = _utf8(_fb2(encoding: null, title: pushkinTitle, body: pushkinBody));
      expect(sniffXmlEncoding(bytes), XmlEncoding.utf8);

      expect(parseFb2Book(bytes).metadata.title, pushkinTitle);
    });

    test('accented Latin is detected as windows-1252', () {
      final bytes = _cp1252(
        _fb2(encoding: null, title: strangerTitle, body: strangerBody, author: ''),
      );
      expect(sniffXmlEncoding(bytes), XmlEncoding.cp1252);

      expect(parseFb2Book(bytes).metadata.title, strangerTitle);
    });

    test('Arabic is detected as windows-1256', () {
      final bytes = _cp1256(_fb2(encoding: null, title: arabicTitle, body: arabicBody, author: ''));
      expect(sniffXmlEncoding(bytes), XmlEncoding.cp1256);

      expect(parseFb2Book(bytes).metadata.title, arabicTitle);
    });

    test('English with typographic quotes stays windows-1252', () {
      const String doc =
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
          '<description><title-info><book-title>Quotes</book-title></title-info></description>'
          '<body><section><p>It was the best of times\u2014really, \u201Cthe worst\u201D'
          ' of times\u2026 she said.</p></section></body></FictionBook>';

      final book = parseFb2Book(_cp1252(doc));
      expect(book.files.html.first.content, contains('times—really, “the worst” of times…'));
    });
  });

  group('unlookupable and malformed input', () {
    test('unknown declaration (koi8-r) with cp1251 bytes is detected', () {
      final bytes = _cp1251(_fb2(encoding: 'koi8-r', title: pushkinTitle, body: pushkinBody));
      expect(sniffXmlEncoding(bytes), XmlEncoding.cp1251);

      expect(parseFb2Book(bytes).metadata.title, pushkinTitle);
    });

    test('undecodable bytes become U+FFFD instead of throwing', () {
      const String head =
          '<?xml version="1.0" encoding="windows-1251"?>'
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
          '<description><title-info><book-title>Капитанская дочка</book-title>'
          '</title-info></description><body><section><p>«Береги честь смолоду.» — гласит';
      const String tail =
          ' пословица. Ёлка, ёж, щука и объятие.</p></section></body></FictionBook>';
      final bytes = BytesBuilder()
        ..add(_cp1251(head))
        ..add(const <int>[0x98]) // unassigned in windows-1251
        ..add(_cp1251(tail));

      final book = parseFb2Book(bytes.toBytes());
      expect(book.metadata.title, pushkinTitle); // metadata is unaffected
      expect(book.files.html.first.content, contains('\uFFFD'));
    });
  });

  group('byte order marks', () {
    test('utf-8 BOM is stripped', () {
      final bytes = _utf8(_fb2(encoding: null, title: pushkinTitle, body: pushkinBody));
      final withBom = Uint8List.fromList(<int>[0xEF, 0xBB, 0xBF, ...bytes]);

      expect(parseFb2Book(withBom).metadata.title, pushkinTitle);
    });

    test('utf-16le BOM wins over the byte layout', () {
      final bytes = _utf16le(_fb2(encoding: null, title: pushkinTitle, body: pushkinBody));
      final withBom = Uint8List.fromList(<int>[0xFF, 0xFE, ...bytes]);

      final book = parseFb2Book(withBom);
      expect(book.metadata.title, pushkinTitle);
      expect(book.files.html.first.content, contains('Береги честь смолоду.'));
    });
  });

  group('zipped cp1251 document', () {
    test('entry bytes are decoded with the declared encoding', () {
      final entry = ArchiveFile('book.fb2', _cp1251Bytes.length, _cp1251Bytes)
        ..compression = CompressionType.deflate;
      final archive = Archive()..addFile(entry);
      final zip = Uint8List.fromList(ZipEncoder().encode(archive));

      final book = parseFb2Book(zip);
      expect(book.metadata.title, pushkinTitle);
      expect(book.metadata.authors, [pushkinAuthor]);

      final metadata = readFb2Metadata(zip);
      expect(metadata.title, pushkinTitle);
    });
  });

  group('cover binary inside a cp1251 document', () {
    test('cover id and base64 payload survive the encoding', () {
      const String doc =
          '<?xml version="1.0" encoding="windows-1251"?>'
          '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
          'xmlns:l="http://www.w3.org/1999/xlink">'
          '<description><title-info><book-title>Обложка</book-title>'
          '<coverpage><image l:href="#cover"/></coverpage></title-info></description>'
          '<binary id="cover" content-type="image/png">$_pngBase64</binary>'
          '<body><section><p>Текст.</p></section></body></FictionBook>';

      final metadata = readFb2Metadata(_cp1251(doc));
      expect(metadata.title, 'Обложка');
      // The full parse extracts the cover binary: the base64 payload
      // is pure ASCII and survives the cp1251 decoding untouched.
      final book = parseFb2Book(_cp1251(doc));
      expect(book.cover.name, 'cover.png');
      expect(sniffImageType(book.cover.content), ImageType.png);
    });
  });
}

// 1x1 transparent PNG binary as base64.
const String _pngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk'
    'YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Uint8List _utf8(final String text) => Uint8List.fromList(utf8.encode(text));

Uint8List _utf16le(final String text) {
  final out = BytesBuilder();
  for (final rune in text.runes) {
    if (rune > 0xFFFF) {
      throw ArgumentError('test fixture must be BMP-only');
    }
    out.addByte(rune & 0xFF);
    out.addByte(rune >> 8);
  }

  return out.toBytes();
}

/// Encodes text as windows-1251, supporting exactly the fixture
/// vocabulary (ASCII, А-Яа-яЁё, «», —).
Uint8List _cp1251(final String text) => Uint8List.fromList(
  text.runes.map((final rune) {
    if (rune < 0x80) return rune;
    if (rune >= 0x0410 && rune <= 0x042F) return 0xC0 + rune - 0x0410;
    if (rune >= 0x0430 && rune <= 0x044F) return 0xE0 + rune - 0x0430;
    if (rune == 0x0401) return 0xA8; // Ё
    if (rune == 0x0451) return 0xB8; // ё
    if (rune == 0x00AB) return 0xAB; // «
    if (rune == 0x00BB) return 0xBB; // »
    if (rune == 0x2014) return 0x97; // —

    throw ArgumentError('cp1251 test encoder lacks U+${rune.toRadixString(16)}');
  }).toList(),
);

final Uint8List _cp1251Bytes = _cp1251(
  _fb2(encoding: 'windows-1251', title: pushkinTitle, body: pushkinBody),
);

/// Encodes text as windows-1252, supporting exactly the fixture
/// vocabulary (ASCII plus the accented/punctuation bytes below).
Uint8List _cp1252(final String text) => Uint8List.fromList(
  text.runes.map((final rune) {
    const Map<int, int> table = <int, int>{
      0x00C0: 0xC0, // À
      0x00C8: 0xC8, // È
      0x00C9: 0xC9, // É
      0x00E0: 0xE0, // à
      0x00E2: 0xE2, // â
      0x00E7: 0xE7, // ç
      0x00E8: 0xE8, // è
      0x00E9: 0xE9, // é
      0x00EA: 0xEA, // ê
      0x00EE: 0xEE, // î
      0x00F1: 0xF1, // ñ
      0x00F4: 0xF4, // ô
      0x00F6: 0xF6, // ö
      0x00FB: 0xFB, // û
      0x00FC: 0xFC, // ü
      0x00F9: 0xF9, // ù
      0x2014: 0x97, // —
      0x2019: 0x92, // ’
      0x201C: 0x93, // “
      0x201D: 0x94, // ”
      0x2026: 0x85, // …
    };
    if (rune < 0x80) return rune;
    final byte = table[rune];
    if (byte == null) {
      throw ArgumentError('cp1252 test encoder lacks U+${rune.toRadixString(16)}');
    }

    return byte;
  }).toList(),
);

/// Encodes text as windows-1256, supporting exactly the fixture
/// vocabulary (ASCII plus Arabic letters).
Uint8List _cp1256(final String text) => Uint8List.fromList(
  text.runes.map((final rune) {
    // windows-1256 maps bytes 0xC1-0xD6 contiguously to U+0621-U+0636.
    if (rune < 0x80) return rune;
    if (rune >= 0x0621 && rune <= 0x0636) return 0xC1 + rune - 0x0621;
    const Map<int, int> table = <int, int>{
      0x0637: 0xD8, // ط
      0x0639: 0xDA, // ع
      0x063A: 0xDB, // غ
      0x0640: 0xDC, // ـ
      0x0641: 0xDD, // ف
      0x0642: 0xDE, // ق
      0x0643: 0xDF, // ك
      0x0644: 0xE1, // ل
      0x0645: 0xE3, // م
      0x0646: 0xE4, // ن
      0x0647: 0xE5, // ه
      0x0648: 0xE6, // و
      0x0649: 0xEC, // ى
      0x064A: 0xED, // ي
      0x060C: 0xA1, // ،
    };
    final byte = table[rune];
    if (byte == null) {
      throw ArgumentError('cp1256 test encoder lacks U+${rune.toRadixString(16)}');
    }

    return byte;
  }).toList(),
);

String _fb2({
  required final String? encoding,
  required final String title,
  required final String body,
  String author = 'Александр Пушкин',
}) {
  final declaration = encoding == null ? '' : '<?xml version="1.0" encoding="$encoding"?>\n';
  final authorXml = author.isEmpty
      ? ''
      : '<author><first-name>Александр</first-name><last-name>Пушкин</last-name></author>';

  return '$declaration<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0">'
      '<description><title-info><book-title>$title</book-title>$authorXml</title-info></description>'
      '<body><section><p>$body</p></section></body>'
      '</FictionBook>';
}
