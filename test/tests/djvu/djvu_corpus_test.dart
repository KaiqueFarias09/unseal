import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../../support/djvu_fixture.dart';

/// The scanned-archive corpus (test/resources/djvu, PROVENANCE.md) against
/// the archived djvulibre 3.5.29 oracles. Text parity is pinned through the
/// reference files' own SHA-256 hashes (see references.sha256 in the
/// bench-artifacts oracle directory): the reconstruction below must hash to
/// exactly what `djvutxt` wrote. Pixel pins carry the raster hash of this
/// decoder; pages marked "ddjvu-identical" were verified byte-for-byte
/// against `ddjvu -format=ppm` renders of the same page at dev time, and the
/// remaining composed pages follow the house MRC rendering convention
/// (hard mask selection over bilinear layer expansion) whose bounded
/// deviation from ddjvu's blended stencil is recorded in the README.
void main() {
  final corpus = <String, Uint8List>{};
  Uint8List corpusBytes(final String name) =>
      corpus.putIfAbsent(name, () => File('test/resources/djvu/$name').readAsBytesSync());

  final books = <String, DjvuBook>{};
  DjvuBook open(final String name) => books.putIfAbsent(name, () => parseDjvuBook(corpusBytes(name)));

  /// Rebuilds the positional djvutxt document text from page texts: each
  /// text page contributes its rendered text and a trailing LF + form feed
  /// separator unless the page text already ends with one.
  Uint8List documentText(final DjvuBook book) {
    final joined = BytesBuilder();
    for (final page in book.pages) {
      if (page.text.isEmpty) continue;
      final rendered = <int>[];
      for (final byte in utf8.encode(page.text)) {
        if (byte == 0) {
          rendered
            ..add(0x0A)
            ..add(0x0C);
        } else {
          rendered.add(byte);
        }
      }
      joined.add(rendered);
      final endsWithSeparator =
          rendered.length >= 2 && rendered[rendered.length - 2] == 0x0A && rendered.last == 0x0C;
      if (!endsWithSeparator) joined.add(const <int>[0x0A, 0x0C]);
    }
    return joined.toBytes();
  }

  group('corpus documents open with djvudump page counts', () {
    final expectations = <String, int>{
      'cyrillic.djvu': 12,
      'spec-bundled.djvu': 71,
      'navm-fgbz.djvu': 6,
      'links.djvu': 1,
      'goody-twoshoes.djvu': 16,
      'speller-1921.djvu': 121,
    };
    for (final entry in expectations.entries) {
      test('${entry.key} opens ${entry.value} pages', () {
        expect(open(entry.key).pageCount, entry.value);
      });
    }
  });

  group('TXTz text parity against djvutxt', () {
    final textHashes = <String, String>{
      'cyrillic.djvu': 'fd9b8b0fd9d025e6720c0591dc5e8b7c495189a4eb47d23b11c8a4501814609f',
      'spec-bundled.djvu': '6f59cb00d6fc55dd5b1271185643b8367b6785e6f08347a34779b34db9a4e041',
      'navm-fgbz.djvu': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'links.djvu': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'goody-twoshoes.djvu': '781e428d01a88dd48b28eb7f85bd9ca09da4501569c522d3359a8187c2bcc309',
      'speller-1921.djvu': '2ad2490a2bf62def0623dbeb3edba72412b31baaf735bd8164f5a35aa5bcf072',
    };
    for (final entry in textHashes.entries) {
      test('${entry.key} document text hashes like the djvutxt reference', () {
        expect(sha256.convert(documentText(open(entry.key))).toString(), entry.value);
      });
    }

    test('cyrillic page 1 keeps its pre-reform Cyrillic text', () {
      final text = open('cyrillic.djvu').pages.first.text;
      expect(text, startsWith('(ЩУ И МШИ \nРУКОВОДСТВО ДЛЯ УЧИТЕЛЕЙ \n'));
      expect(text, contains('Снладь Евдаяія—жнііпіші овладъ Тверсхаго гувернерам земства. \n'));
      expect(text, endsWith('{Твпографіа губврвскаго адметва. \n1905 г. \n'));
    });

    test('spec-bundled page 1 keeps its reference text', () {
      expect(
        open('spec-bundled.djvu').pages.first.text,
        startsWith('Release Copy Pag e 1 of 71 Lizardtech DjVu Reference DjVu v3'),
      );
    });

    test('speller page 1 keeps its Google-pipeline OCR text', () {
      expect(
        open('speller-1921.djvu').pages.first.text,
        startsWith('Google \n\x1F\x1D\x0BThis is a digital copy of a book that was preserved'),
      );
    });

    test('TXTz wins over a legacy TXTa chunk when a page stores both', () {
      final jpeg = File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync();
      final txtz = djvuCorpusChunk(corpusBytes('cyrillic.djvu'), 'TXTz');
      final page = djvuPageWithChunks(
        jpeg,
        chunks: <(String, Uint8List)>[
          ('TXTa', Uint8List.fromList(<int>[..._int24(5), ...ascii.encode('TXTa!'), 1])),
          ('TXTz', txtz),
        ],
      );
      final book = parseDjvuBook(page);
      expect(book.pages.single.text, startsWith('(ЩУ И МШИ'));
    });
  });

  group('pixel goldens', () {
    void expectRasterHash(final DjvuBook book, final int index, final String hash) {
      expect(sha256.convert(book.pages[index].image.content).toString(), hash);
    }

    test('shared-dictionary mask pages are ddjvu-identical', () {
      final cyrillic = open('cyrillic.djvu');
      expectRasterHash(
        cyrillic,
        0,
        '54eec78df7f69b0f5cff494b0d66e1039246430c95082a488680ceaa9f6ac2bc',
      );
      expectRasterHash(
        cyrillic,
        5,
        'd989bcbaff7f5ab3ad98da5cc0b275417148f62cecf3c46ec5d49cc06809c289',
      );
      expectRasterHash(
        cyrillic,
        11,
        'f5a8049f10ffae44ab9e80a983db6a44be9c7d1127f5d7e7e772c81141b983a3',
      );
    });

    test('spec-bundled pages across three dictionaries are ddjvu-identical', () {
      // Page 1 uses the inline Djbz; pages 36 and 71 inherit dict0040 and
      // dict0071 through INCL — the byte-identical renders pin the
      // mid-document dictionary switching.
      final spec = open('spec-bundled.djvu');
      expectRasterHash(spec, 0, '26fea0319312a126578ee8256df06d50296f2f6bc6ad70d2d404695781d1e601');
      expectRasterHash(
        spec,
        35,
        '3a007ba08355ed94abf7cfe6e37c198818ea2c7686d987d6717fcc83e0b1e983',
      );
      expectRasterHash(
        spec,
        70,
        '063d1a86ccb3f03b23ae07abd2fff4d39b8a5a1db6e11bd65aad3312825b556c',
      );
    });

    test('links and speller mask and photo pages are ddjvu-identical', () {
      expectRasterHash(
        open('links.djvu'),
        0,
        'fbaa49958383a38557b0b46c8556160aec7e9034ae4697581ba7a5da52ce8274',
      );
      expectRasterHash(
        open('speller-1921.djvu'),
        60,
        'e77298ccb2f35ca739817c02103484b4ff261444de00c20f237a0dbba91e301c',
      );
      expectRasterHash(
        open('speller-1921.djvu'),
        120,
        '6197f5ee63babc6d411f26c294c97f1e24ee201e98a5ee254f2ad52967467380',
      );
    });

    test('composed MRC pages follow the house rendering convention', () {
      // Deviation from ddjvu's blended stencil is bounded: measured against
      // the archived renders, the mean channel error stays under 3.3/255
      // (goody) and 0.7/255 (speller page 1), maximum 91 and 176. The FGbz
      // pages of navm-fgbz render black ink where ddjvu paints palette
      // colors, so their deviation is pinned as our own raster hashes.
      expectRasterHash(
        open('goody-twoshoes.djvu'),
        0,
        'b1b2db8c8fa16b2042345e95650c12e0977dffe31795b15b4f4f13adf2bd6f8c',
      );
      expectRasterHash(
        open('goody-twoshoes.djvu'),
        7,
        '065bc92cd50ea910f1788473b842678f4e9ea8155c039f8b5686b0b58d644f4b',
      );
      expectRasterHash(
        open('goody-twoshoes.djvu'),
        15,
        '6612bb70591780cd558dbce89bf3f539413660922d5e3501788b99890e7a75f0',
      );
      expectRasterHash(
        open('speller-1921.djvu'),
        0,
        '5ef2b022fefcd26fe5d62ff5340c3c261d21d2103be98069fe44c9f8e718fa6d',
      );
      expectRasterHash(
        open('navm-fgbz.djvu'),
        0,
        'f2d40734b2e512bf01fdb204b1ca42be0a8e0b8d488b15d397fb1c88938219b1',
      );
      expectRasterHash(
        open('navm-fgbz.djvu'),
        5,
        'ebdd921434842557a8b8982272d1b3f9a2c16e22b221a204aa50c2fe792a795b',
      );
    });
  });

  group('NAVM navigation', () {
    test('links.djvu carries its two corpus bookmarks', () {
      final points = open('links.djvu').navigation.navPoints;
      expect(points.map((final point) => point.label), <String>['Relative Link', 'Absolute Link']);
      expect(points[0].content, 'colorbook.djvu');
      expect(points[1].content, 'https://djvu.js.org/assets/djvu_examples/DjVu3Spec.djvu');
    });

    test('navm-fgbz.djvu nests Stamps under its claimed children', () {
      final points = open('navm-fgbz.djvu').navigation.navPoints;
      expect(points.map((final point) => point.label), <String>[
        'Links',
        'Ink, Rectangles, Ellipses, Lines',
        'Stamps',
        'Last Page',
      ]);
      expect(points[2].subNavPoints.map((final point) => point.label), <String>[
        'Stamps - Faces',
        'Stamps - Pointers',
      ]);
    });

    test('spec-bundled.djvu keeps its document outline tree', () {
      final points = open('spec-bundled.djvu').navigation.navPoints;
      expect(points, hasLength(1));
      expect(points.single.label, 'DjVu3SpecFinal.djvu');
      expect(points.single.subNavPoints, hasLength(13));
      expect(points.single.subNavPoints.first.label, 'Introduction');
    });

    test('documents without NAVM keep empty navigation', () {
      expect(open('cyrillic.djvu').navigation.navPoints, isEmpty);
    });
  });

  group('indirect components', () {
    test('bytes-only parse keeps rejecting indirect directories', () {
      expect(
        () => Unseal.parse(
          File('test/resources/djvu/derived/cyrillic-page1-index.djvu').readAsBytesSync(),
        ),
        throwsA(isA<DjvuUnsupportedCodecException>()),
      );
    });

    test('readFile resolves sibling components into the bundled page', () async {
      final book =
          await Unseal.readFile('test/resources/djvu/derived/cyrillic-page1-index.djvu')
              as DjvuBook;
      expect(book.pageCount, 1);
      final bundled = open('cyrillic.djvu');
      expect(book.pages.single.image.content, bundled.pages.first.image.content);
      expect(book.pages.single.text, bundled.pages.first.text);
    });

    test('a missing component fails with a typed message', () async {
      // The real derived index names two components; copying only the page
      // leaves the shared dictionary missing next to the document.
      final directory = await Directory.systemTemp.createTemp('unseal-indirect-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final index = File('test/resources/djvu/derived/cyrillic-page1-index.djvu').readAsBytesSync();
      final names = Uint8List.sublistView(index, 16 + 8 + 3 + 2 * 4);
      final indexPath = djvuWriteIndirect(
        directory,
        djvuIndirectIndex(names, const <String>['00012.djbz', '00001.djvu']),
        <String, Uint8List>{},
      );
      await expectLater(Unseal.readFile(indexPath), throwsA(isA<DjvuException>()));
    });
  });

  group('shared-dictionary hostile inputs', () {
    test('an INCL target without a dictionary fails typed', () {
      // Resolution looks up the named component's Djbz without following its
      // own INCL chunks, so reference cycles stay a typed lookup failure.
      final cyrillicSjbz = djvuCorpusChunk(corpusBytes('cyrillic.djvu'), 'Sjbz');
      final page = djvuJb2Page(
        Uint8List.sublistView(cyrillicSjbz, 0, 64),
        width: 764,
        height: 1112,
      );
      final withIncl = Uint8List.fromList(<int>[
        ...ascii.encode('AT&T'),
        ..._form('DJVU', <int>[
          ..._chunk('INFO', <int>[0x02, 0xFC, 0x04, 0x58, 26, 0, 44, 1, 22, 1]),
          ..._chunk('INCL', ascii.encode('nowhere.djbz')),
          ..._chunk('Sjbz', Uint8List.sublistView(cyrillicSjbz, 0, 64)),
        ]),
      ]);
      expect(() => parseDjvuBook(withIncl), throwsA(isA<DjvuException>()));
      expect(() => parseDjvuBook(page), throwsA(isA<DjvuException>()));
    });

    test('a hostile TXTz declaration fails typed inside a page', () {
      final jpeg = File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync();
      final page = djvuPageWithChunks(
        jpeg,
        chunks: <(String, Uint8List)>[
          ('TXTz', Uint8List.fromList(<int>[0x80, 0x00, 0xFF, 0xFF])),
        ],
      );
      expect(() => parseDjvuBook(page), throwsA(isA<DjvuException>()));
    });

    test('a truncated NAVM chunk fails typed', () {
      final navm = djvuCorpusChunk(corpusBytes('links.djvu'), 'NAVM');
      final pages = <Uint8List>[
        djvuJpegPage(File('test/resources/fuzz/generated/images/tiny.jpg').readAsBytesSync()),
      ];
      final document = _bundleWithNavm(pages, Uint8List.sublistView(navm, 0, 12));
      expect(() => parseDjvuBook(document), throwsA(isA<DjvuException>()));
    });
  });
}

Uint8List _bundleWithNavm(final List<Uint8List> standalonePages, final Uint8List navm) {
  final components = <List<int>>[for (final page in standalonePages) page.sublist(4)];
  final dirmDataLength = 3 + components.length * 4;
  final directoryChunkLength = 8 + dirmDataLength + (dirmDataLength & 1);
  var offset = 4 + 8 + 4 + directoryChunkLength + 8 + navm.length + (navm.length & 1);
  final offsets = <int>[];
  for (final component in components) {
    offsets.add(offset);
    offset += component.length;
  }
  final directory = _chunk('DIRM', <int>[
    0x81,
    ..._int16(components.length),
    for (final value in offsets) ..._int32(value),
  ]);
  return Uint8List.fromList(<int>[
    ...ascii.encode('AT&T'),
    ..._form('DJVM', <int>[
      ...directory,
      ..._chunk('NAVM', navm),
      for (final component in components) ...component,
    ]),
  ]);
}

List<int> _chunk(final String type, final List<int> bytes) => <int>[
  ...ascii.encode(type),
  ..._int32(bytes.length),
  ...bytes,
  if (bytes.length.isOdd) 0,
];

List<int> _form(final String type, final List<int> chunks) =>
    _chunk('FORM', <int>[...ascii.encode(type), ...chunks]);

List<int> _int16(final int value) => <int>[value >> 8 & 255, value & 255];

List<int> _int24(final int value) => <int>[value >> 16 & 255, value >> 8 & 255, value & 255];

List<int> _int32(final int value) => <int>[
  value >> 24 & 255,
  value >> 16 & 255,
  value >> 8 & 255,
  value & 255,
];
