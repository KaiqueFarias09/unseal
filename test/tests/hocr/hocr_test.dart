import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

Uint8List _bytes(final String html) => Uint8List.fromList(utf8.encode(html));

Uint8List _fixture(final String relative) =>
    File('test/resources/hocr/$relative').readAsBytesSync();

/// Wraps [body] in the smallest valid hOCR document.
String _document(final String body, {final String head = ''}) =>
    '<html><head><meta name="ocr-system" content="test 1"/>$head</head><body>$body</body></html>';

void main() {
  group('real producers', () {
    test('Tesseract 5.5.3 phototest: full hierarchy, baselines, confidence', () {
      final document = parseHocrDocument(_fixture('tesseract/phototest.hocr'));
      expect(document.system, 'tesseract 5.5.3');
      expect(document.capabilities, contains('ocrp_wconf'));
      final page = document.pages.single;
      expect(page.box, HocrBox(x0: 0, y0: 0, x1: 640, y1: 480));
      expect(page.frameSource, HocrFrameSource.declared);
      expect(page.imageName, 'phototest.tif');
      expect(page.physicalPageNumber, 0);
      expect((page.scanResolutionX, page.scanResolutionY), (200, 200));
      expect(page.children.single, isA<HocrBlock>());
      final block = page.children.single as HocrBlock;
      expect(block.className, 'ocr_carea');
      expect(block.children, hasLength(2));
      expect(block.children.first, isA<HocrParagraph>());
      expect(page.lines, hasLength(8));
      expect(page.words, hasLength(60));
      final line = page.lines.first;
      expect(line.box, HocrBox(x0: 36, y0: 92, x1: 580, y1: 122));
      expect(line.baseline!.coefficients, <double>[0.0, -6.0]);
      expect(line.baseline!.order, 1);
      expect(line.properties.keys, containsAll(<String>['x_size', 'x_descenders', 'x_ascenders']));
      final word = page.words.first;
      expect(word.text, 'This');
      expect(word.box, HocrBox(x0: 36, y0: 92, x1: 96, y1: 116));
      expect(word.confidence!.declared, 96.0);
      expect(word.confidence!.shared, 0.96);
      expect(word.confidence!.isUnknown, isFalse);
      // The paragraph carries Tesseract's language; the words do not.
      expect((block.children.first as HocrParagraph).language, 'eng');
      expect(word.language, isNull);
    });

    test('Tesseract 5.5.3 UNLV pages: line-role classes stay lines with their token', () {
      final document = parseHocrDocument(_fixture('tesseract/unlv-8087.hocr'));
      final page = document.pages.single;
      final roles = <String, int>{};
      for (final line in page.lines) {
        roles[line.className] = (roles[line.className] ?? 0) + 1;
      }
      expect(roles['ocr_line'], 107);
      expect(roles['ocr_header'], 2);
      expect(roles['ocr_caption'], 7);
      expect(page.lines, hasLength(116));
      expect(page.words, hasLength(694));
      // Every header and caption keeps its baseline and its words.
      final caption = page.lines.firstWhere((final line) => line.className == 'ocr_caption');
      expect(caption.baseline, isNotNull);
      expect(caption.words, isNotEmpty);
      expect(caption.words.first.text, 'Tue');
      // Photo and separator blocks are transparent: no block for them,
      // six content areas carry the words.
      expect(page.children.whereType<HocrBlock>(), hasLength(6));
      // The pull-out in the other UNLV page is a line too.
      final other = parseHocrDocument(_fixture('tesseract/unlv-8071.hocr'));
      expect(
        other.pages.single.lines.where((final line) => line.className == 'ocr_textfloat'),
        hasLength(1),
      );
      expect(other.pages.single.words, hasLength(647));
    });

    test('Tesseract multipage: two pages in document order with their own frames', () {
      final document = parseHocrDocument(_fixture('tesseract/multipage.hocr'));
      expect(document.pages, hasLength(2));
      expect(document.pages[0].physicalPageNumber, 0);
      expect(document.pages[1].physicalPageNumber, 1);
      expect(document.pages[0].box, HocrBox(x0: 0, y0: 0, x1: 640, y1: 480));
      expect(document.pages[1].box, HocrBox(x0: 0, y0: 0, x1: 1024, y1: 800));
      expect(document.pages[0].words, hasLength(60));
      expect(document.pages[1].words, hasLength(66));
      expect(document.pages[1].words.first.text, 'The');
    });

    test('eurotext keeps diacritics and guillemets as written', () {
      final document = parseHocrDocument(_fixture('tesseract/eurotext.hocr'));
      final texts = document.pages.single.words.map((final word) => word.text).toList();
      expect(texts, contains('«rapide»'));
      expect(texts, contains('céo'));
      expect(texts.any((final text) => text.contains('”')), isTrue);
    });

    test('ABBYY FineReader 11: page > par > line > word, no block, no confidence', () {
      final document = parseHocrDocument(_fixture('external/417576986_0012.hocr'));
      expect(document.system, 'ABBYY FineReader Engine 11');
      final page = document.pages.single;
      expect(page.children.whereType<HocrBlock>(), isEmpty);
      expect(page.children.single, isA<HocrParagraph>());
      final paragraph = page.children.single as HocrParagraph;
      expect(paragraph.language, 'fr');
      expect(paragraph.direction, 'ltr');
      expect(page.lines, hasLength(25));
      expect(page.words, hasLength(140));
      expect(page.words.every((final word) => word.confidence == null), isTrue);
      expect(page.lines.every((final line) => line.baseline == null), isTrue);
      // `image ;` imports as no image name, not as an empty string.
      expect(page.imageName, isNull);
    });

    test('ocropy: plain-text lines, no words, no page bbox, unknown property as data', () {
      final document = parseHocrDocument(_fixture('external/433934212_0017.html'));
      expect(document.system, 'ocropus-0.4');
      expect(document.capabilities, <String>['ocr_line', 'ocr_page']);
      final page = document.pages.single;
      expect(page.box, isNull);
      expect(page.frameSource, HocrFrameSource.derivedFromContent);
      expect(page.frame, HocrBox(x0: 9, y0: 434, x1: 1313, y1: 2582));
      expect(page.properties['file'], <String>['433934212_0017.bin.png']);
      expect(page.lines, hasLength(29));
      expect(page.words, isEmpty);
      expect(page.lines[1].text, 't W-');
      expect(page.lines[1].id, isNull);
    });

    test('OCRopus 2007: no doctype, ocr-id meta ignored, paragraphs of plain lines', () {
      final document = parseHocrDocument(_fixture('external/alice.hocr'));
      expect(document.system, isNull);
      expect(document.capabilities, isEmpty);
      final page = document.pages.single;
      expect(page.frameSource, HocrFrameSource.derivedFromContent);
      expect(page.children.whereType<HocrParagraph>(), hasLength(5));
      expect(page.lines, hasLength(37));
      expect(page.lines.first.text, '1 Down the Rabbit-Hole');
    });

    test('kraken: HTML5 doctype, comma-separated titles, cuts and x_confs as data', () {
      final document = parseHocrDocument(_fixture('external/kraken_bw_example.hocr'));
      expect(document.system, 'kraken');
      expect(document.capabilities, isEmpty);
      final page = document.pages.single;
      expect(page.box, HocrBox(x0: 0, y0: 0, x1: 924, y1: 1624));
      expect(page.imageName, 'tests/resources/bw.png');
      expect(page.lines, hasLength(30));
      expect(page.words, hasLength(392));
      final line = page.lines.first;
      expect(line.properties['cuts'], <String>['0,0,20,0', '27,0,41,0', '21,0,39,0']);
      final word = page.words.first;
      expect(word.text, 's14');
      expect(word.box, HocrBox(x0: 86, y0: 61, x1: 152, y1: 101));
      expect(word.confidence, isNull);
      expect(word.properties['x_confs'], hasLength(3));
    });

    test('gcv2hocr: zero-extent page bbox derives its frame from 700 boxed lines', () {
      final document = parseHocrDocument(_fixture('external/jp_vert.hocr'));
      final page = document.pages.single;
      expect(page.box, HocrBox(x0: 0, y0: 0, x1: 0, y1: 0));
      expect(page.box!.isDegenerate, isTrue);
      expect(page.frameSource, HocrFrameSource.derivedFromContent);
      expect(page.frame, HocrBox(x0: 108, y0: 78, x1: 726, y1: 1090));
      expect(page.lines, hasLength(700));
      expect(page.words.first.text, '  光学  ');
      expect(page.words.first.language, 'jpn');
      expect(page.words.first.direction, 'ltr');
    });

    test('Tesseract 3.x: strong/em inside words, lang and dir and xml:lang verbatim', () {
      final old = parseHocrDocument(_fixture('external/060.hocr'));
      expect(old.system, 'tesseract 3.04.01');
      final words = old.pages.single.words;
      expect(words, hasLength(338));
      expect(words.first.text, ' ');
      expect(words.first.language, 'ces');
      expect(words.first.direction, 'ltr');
      final dev = parseHocrDocument(_fixture('external/417576986_0013.hocr'));
      final word = dev.pages.single.words.first;
      expect(word.language, 'lat');
      expect(word.xmlLanguage, 'lat');
      expect(word.direction, 'ltr');
      // Indentation inside the word span is model text; the binding trims.
      expect(word.text.trim(), 'P');
      expect(word.text, isNot('P'));
      final fraktur = parseHocrDocument(_fixture('external/wetzel_reisebegleiter_1901_0021.hocr'));
      expect(fraktur.pages.single.words.first.language, 'deu-frak');
    });
  });

  group('derived feature document', () {
    final document = parseHocrDocument(_fixture('derived/features.hocr'));
    final page = document.pages.first;

    test('metadata, page properties and the three frame sources', () {
      expect(document.system, 'unseal-derived 1');
      expect(document.numberOfPages, 3);
      expect(document.languages, <String>['en', 'de', 'ja']);
      expect(document.scripts, <String>['Latn', 'Jpan']);
      expect(document.pages, hasLength(3));
      expect(page.logicalPageNumber, 'iv.');
      expect(page.imageMd5, '0123456789abcdef0123456789abcdef');
      expect((page.scanResolutionX, page.scanResolutionY), (300, 300));
      expect(page.textAngle, 0.5);
      expect(page.frameSource, HocrFrameSource.declared);
      expect(document.pages[1].frameSource, HocrFrameSource.derivedFromContent);
      expect(document.pages[1].frame, HocrBox(x0: 300, y0: 100, x1: 460, y1: 400));
      expect(document.pages[2].frameSource, HocrFrameSource.none);
      expect(document.pages[2].frame, isNull);
      expect(document.pages[2].physicalPageNumber, 2);
    });

    test('text: entities, inline markup, ins/del, nbsp and shy, astral code units', () {
      final words = page.lines.first.words;
      expect(words[0].text, 'Café');
      expect(words[1].text, 'naïve');
      expect(words[1].className, 'ocrx_word');
      expect(words[2].text, '𝄞\u00A0𝕌𝕟𝕚𝕔𝕠𝕕𝕖');
      expect(words[2].text.length, 1 + 1 + 7 * 2 + 1, reason: 'UTF-16 code units, not code points');
      expect(words[3].text, 'fin2&done');
      final second = page.lines[1];
      expect(second.words[0].text, 'hello');
      expect(second.words[0].hasAlternativeReadings, isTrue);
      expect(second.hasAlternativeReadings, isTrue);
      expect(second.words[1].text, 'soft\u00ADhyphen');
      expect(second.words[2].text, '  padded  ');
      expect(second.words[3].text, ' ');
      expect(page.lines[2].text, 'plain line text without words');
      expect(page.lines[2].words, isEmpty);
      expect(page.lines.first.hasAlternativeReadings, isFalse);
    });

    test('geometry: boxes, baseline polynomial, text angle, hard break', () {
      final line = page.lines.first;
      expect(line.hasHardBreak, isTrue);
      expect(line.baseline!.coefficients, <double>[0.01, -8.0]);
      expect(line.baseline!.intercept, -8.0);
      expect(line.baseline!.evaluate(0), -8.0);
      expect(line.baseline!.evaluate(100), closeTo(-7.0, 1e-9));
      // Named projection into page space: bottom edge plus the native value.
      expect(line.baselineYAt(100), closeTo(160 - 8.0, 1e-9));
      expect(line.baselineYAt(200), closeTo(160 - 7.0, 1e-9));
      final quadratic = page.lines[1];
      expect(quadratic.baseline!.order, 2);
      expect(quadratic.baseline!.evaluate(2), closeTo(0.02 * 4 + 0.5 * 2 - 6, 1e-9));
      expect(quadratic.textAngle, 2.5);
      expect(quadratic.direction, 'rtl');
      expect(page.lines[2].baselineYAt(500), 300.0);
      expect(page.lines[2].hasHardBreak, isNull);
      expect(page.words.last.box!.rect, SpatialRect(x: 620, y: 720, width: 480, height: 80));
    });

    test('confidence: numeric, zero, unknown and absent stay distinct', () {
      final words = page.lines.first.words;
      expect(words[0].confidence!.declared, 96.5);
      expect(words[0].confidence!.shared, 0.965);
      expect(words[1].confidence!.declared, 0.0);
      expect(words[1].confidence!.shared, 0.0);
      expect(words[1].confidence!.isUnknown, isFalse);
      expect(words[2].confidence!.isUnknown, isTrue);
      expect(words[2].confidence!.declaredToken, 'unknown');
      expect(words[2].confidence!.shared, isNull);
      expect(words[3].confidence, isNull);
    });

    test('classification: line-role classes, spec-style header, engine block, column', () {
      final roles = page.lines.map((final line) => line.className).toList();
      expect(roles, contains('ocr_caption'));
      expect(roles, contains('ocr_header'));
      expect(roles, contains('ocrx_line'));
      // The spec-style header block is transparent: its line hangs off the page.
      final specLine = page.children.whereType<HocrLine>().single;
      expect(specLine.words.map((final word) => word.text), <String>['spec-style', 'header']);
      final blocks = page.children.whereType<HocrBlock>().toList();
      expect(blocks.map((final block) => block.className), <String>[
        'ocr_carea',
        'ocrx_block',
        'ocr_column',
      ]);
      expect(blocks[0].language, 'en');
      expect(blocks[0].properties['file'], <String>['derived-1.png']);
      expect(blocks[0].properties['poly'], hasLength(8));
      final paragraph = blocks[0].children.first as HocrParagraph;
      expect(paragraph.xmlLanguage, 'en-GB');
    });

    test('title grammar: comma rule, quoted strings with spaces, trailing separators', () {
      final legacy = page.lines.last;
      expect(legacy.properties['x_font'], <String>['Comic Sans MS']);
      expect(legacy.properties['x_fsize'], <String>['12']);
      expect(legacy.words.single.properties['x_confs'], <String>['0.9', '0.8']);
      expect(legacy.words.single.confidence!.declared, 94.0);
      final cjk = document.pages[1].lines.first;
      expect(cjk.properties['cuts'], <String>['0,0,20,0', '27,0,41,0']);
      expect(cjk.language, 'ja');
    });
  });

  group('title grammar unit', () {
    test('splits on semicolons, applies the comma rule, strips quotes', () {
      final properties = parseHocrTitle(
        'bbox 1 2 3 4 ; image "a b;c", x_confs 0.9 0,1 , x_font "F", cuts 0,0,20,0 27,0',
        maxProperties: 16,
        maxTokens: 16,
      );
      expect(properties.map((final property) => property.name), <String>[
        'bbox',
        'image',
        'x_confs',
        'x_font',
        'cuts',
      ]);
      expect(properties[1].tokens, <String>['a b;c']);
      expect(properties[2].tokens, <String>['0.9', '0,1']);
      expect(properties[4].tokens, <String>['0,0,20,0', '27,0']);
    });

    test('refuses duplicates, bad names, unterminated quotes and budgets', () {
      expect(
        () => parseHocrTitle('bbox 1 2 3 4; bbox 1 2 3 4', maxProperties: 8, maxTokens: 8),
        throwsA(isA<HocrException>()),
      );
      expect(
        () => parseHocrTitle('Bbox 1 2 3 4', maxProperties: 8, maxTokens: 8),
        throwsA(isA<HocrException>()),
      );
      expect(
        () => parseHocrTitle('1bbox 1', maxProperties: 8, maxTokens: 8),
        throwsA(isA<HocrException>()),
      );
      expect(
        () => parseHocrTitle('image "open', maxProperties: 8, maxTokens: 8),
        throwsA(isA<HocrException>()),
      );
      expect(
        () => parseHocrTitle('a 1; b 2; c 3', maxProperties: 2, maxTokens: 8),
        throwsA(isA<HocrException>()),
      );
      expect(
        () => parseHocrTitle('a 1 2 3 4 5', maxProperties: 8, maxTokens: 3),
        throwsA(isA<HocrException>()),
      );
    });
  });

  group('typed refusals', () {
    test('order and cflow are out of subset', () {
      expect(
        () => parseHocrDocument(
          _bytes(
            _document(
              '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 5 5; order 1">a</span></div>',
            ),
          ),
        ),
        throwsA(isA<HocrUnsupportedFeatureException>()),
      );
      expect(
        () => parseHocrDocument(
          _bytes(
            _document(
              '<div class="ocr_page" title="bbox 0 0 9 9"><div class="ocr_carea" title=\'bbox 0 0 5 5; cflow "x"\'></div></div>',
            ),
          ),
        ),
        throwsA(isA<HocrUnsupportedFeatureException>()),
      );
      expect(
        () => parseHocrDocument(
          _bytes(_document('<div class="ocr_page" title="bbox 0 0 9 9; order 1"></div>')),
        ),
        throwsA(isA<FormatNotSupportedException>()),
      );
    });

    test('geometry corruption fails typed', () {
      for (final title in <String>[
        'bbox 9 0 5 5',
        'bbox -1 0 5 5',
        'bbox 0 0 5',
        'bbox 0 0 5 5 5',
        'bbox 0 0 5 0x10',
        'bbox 0 0 5 99999999999',
        'bbox 0 0 5 5; baseline 1',
        'bbox 0 0 5 5; baseline 1 2 3 4 5 6 7 8 9',
        'bbox 0 0 5 5; baseline 1 nan',
        'bbox 0 0 5 5; baseline 1 1e400',
        'bbox 0 0 5 5; textangle Infinity',
        'bbox 0 0 5 5; hardbreak 2',
      ]) {
        expect(
          () => parseHocrDocument(
            _bytes(
              _document(
                '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="$title">a</span></div>',
              ),
            ),
          ),
          throwsA(isA<HocrException>()),
          reason: title,
        );
      }
      for (final title in <String>['x_wconf 101', 'x_wconf -1', 'x_wconf 1 2', 'x_wconf 1e400']) {
        expect(
          () => parseHocrDocument(
            _bytes(
              _document(
                '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 5 5"><span class="ocrx_word" title="bbox 0 0 5 5; $title">a</span></span></div>',
              ),
            ),
          ),
          throwsA(isA<HocrException>()),
          reason: title,
        );
      }
      for (final title in <String>[
        'scan_res 1 2 3',
        'scan_res a',
        'ppageno -1',
        'ppageno 1 2',
        'lpageno 1 2',
        'image a b',
      ]) {
        expect(
          () => parseHocrDocument(
            _bytes(_document('<div class="ocr_page" title="bbox 0 0 9 9; $title"></div>')),
          ),
          throwsA(isA<HocrException>()),
          reason: title,
        );
      }
    });

    test('inverted nesting, loose words, nested pages, ambiguous roles fail typed', () {
      const page = 'bbox 0 0 9 9';
      for (final body in <String>[
        '<div class="ocr_page" title="$page"><div class="ocr_page" title="$page"></div></div>',
        '<div class="ocr_page" title="$page"><span class="ocrx_word" title="bbox 0 0 1 1">a</span></div>',
        // A div inside a p is normalized away by HTML parsing, so the
        // surviving inverted shapes are the span-nesting ones.
        '<div class="ocr_page" title="$page"><span class="ocr_line" title="bbox 0 0 1 1"><div class="ocr_carea" title="bbox 0 0 1 1"></div></span></div>',
        '<div class="ocr_page" title="$page"><span class="ocr_line" title="bbox 0 0 1 1"><p class="ocr_par">a</p></span></div>',
        '<div class="ocr_page" title="$page"><span class="ocr_line" title="bbox 0 0 1 1"><span class="ocr_line" title="bbox 0 0 1 1">a</span></span></div>',
        '<div class="ocr_page" title="$page"><span class="ocr_line" title="bbox 0 0 1 1"><span class="ocrx_word" title="bbox 0 0 1 1"><span class="ocrx_word">b</span></span></span></div>',
        '<div class="ocr_page" title="$page"><span class="ocr_line ocrx_word" title="bbox 0 0 1 1">a</span></div>',
        '<div class="ocr_page" title="$page"><span class="ocr_line">no box</span></div>',
        '<div class="ocr_page" title="$page"><div class="ocr_carea"></div></div>',
        '<p>no page at all</p>',
      ]) {
        expect(
          () => parseHocrDocument(_bytes(_document(body))),
          throwsA(isA<HocrException>()),
          reason: body,
        );
      }
    });

    test('duplicate metadata fails typed; absent metadata is null', () {
      expect(
        () => parseHocrDocument(
          _bytes(
            '<html><head><meta name="ocr-system" content="a"/><meta name="ocr-system" content="b"/></head>'
            '<body><div class="ocr_page" title="bbox 0 0 9 9"></div></body></html>',
          ),
        ),
        throwsA(isA<HocrException>()),
      );
      final bare = parseHocrDocument(_bytes('<div class="ocr_page" title="bbox 0 0 9 9"></div>'));
      expect(bare.system, isNull);
      expect(bare.capabilities, isEmpty);
      expect(bare.numberOfPages, isNull);
    });

    test('every refusal is an UnsealException subtype, never a raw error', () {
      for (final input in <String>[
        '',
        '<',
        '<div class="ocr_page" title="bbox',
        '\u0000\u0001',
        '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 1 1; x_wconf 1">',
      ]) {
        try {
          parseHocrDocument(_bytes(input));
        } on UnsealException {
          continue;
        }
      }
    });
  });

  group('limits before the DOM', () {
    test('input bytes above 32 MiB fail before decoding', () {
      expect(
        () => parseHocrDocument(Uint8List(32 * 1024 * 1024 + 1)),
        throwsA(isA<HocrException>()),
      );
    });

    test('nesting depth is bounded on the raw markup', () {
      final deep =
          '${'<div>' * 129}<div class="ocr_page" title="bbox 0 0 9 9"></div>${'</div>' * 129}';
      expect(() => parseHocrDocument(_bytes(deep)), throwsA(isA<HocrException>()));
      final shallow =
          '${'<div>' * 100}<div class="ocr_page" title="bbox 0 0 9 9"></div>${'</div>' * 100}';
      expect(parseHocrDocument(_bytes(shallow)).pages, hasLength(1));
    });

    test('title, class and attribute budgets hold on the raw markup', () {
      final longTitle = 'bbox 0 0 9 9; x_note "${'a' * 4100}"';
      expect(
        () => parseHocrDocument(_bytes('<div class="ocr_page" title=\'$longTitle\'></div>')),
        throwsA(isA<HocrException>()),
      );
      final longClass = '${'c ' * 600}ocr_page';
      expect(
        () => parseHocrDocument(_bytes('<div class="$longClass" title="bbox 0 0 9 9"></div>')),
        throwsA(isA<HocrException>()),
      );
      final attributes = List<String>.generate(70, (final i) => 'data-a$i="v"').join(' ');
      expect(
        () => parseHocrDocument(
          _bytes('<div class="ocr_page" title="bbox 0 0 9 9" $attributes></div>'),
        ),
        throwsA(isA<HocrException>()),
      );
    });

    test('per-page element budget and word budgets fail typed', () {
      final buffer = StringBuffer('<div class="ocr_page" title="bbox 0 0 9 9">');
      for (var i = 0; i < 65537; i++) {
        buffer.write('<i></i>');
      }
      buffer.write('</div>');
      expect(() => parseHocrDocument(_bytes(buffer.toString())), throwsA(isA<HocrException>()));

      final words = StringBuffer(
        '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 1 1">',
      );
      for (var i = 0; i < 4097; i++) {
        words.write('<span class="ocrx_word" title="bbox 0 0 1 1">w</span>');
      }
      words.write('</span></div>');
      expect(() => parseHocrDocument(_bytes(words.toString())), throwsA(isA<HocrException>()));
    });

    test('text per word is bounded', () {
      final long = 'x' * 4097;
      expect(
        () => parseHocrDocument(
          _bytes(
            '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 1 1"><span class="ocrx_word" title="bbox 0 0 1 1">$long</span></span></div>',
          ),
        ),
        throwsA(isA<HocrException>()),
      );
    });

    test('script and style content is never evaluated or counted as elements', () {
      final document = parseHocrDocument(
        _bytes(
          '<html><head><style>.x{}</style><script>var s = "<span class=\'ocrx_word\'>no</span>";</script></head>'
          '<body><div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 1 1">'
          '<span class="ocrx_word" title="bbox 0 0 1 1">yes<script>bad()</script></span></span></div></body></html>',
        ),
      );
      expect(document.pages.single.words.single.text, 'yes');
    });
  });

  group('encodings and HTML shapes', () {
    test('UTF-8 BOM, HTML5 doctype, unclosed void elements and bare attributes parse', () {
      final bytes = Uint8List.fromList(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode(
          '<!DOCTYPE html><html><head><meta charset=utf-8><meta name=ocr-system content="k 1"></head>'
          '<body><div class=ocr_page title="bbox 0 0 9 9"><span class=ocr_line title="bbox 0 0 4 4">a<br>b</span></div></body></html>',
        ),
      ]);
      final document = parseHocrDocument(bytes);
      expect(document.system, 'k 1');
      expect(document.pages.single.lines.single.text, 'ab');
    });

    test('a declared legacy charset decodes through the shared policy', () {
      final latin1 = Uint8List.fromList(<int>[
        ...utf8.encode(
          '<html><head><meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1"/></head><body>',
        ),
        ...utf8.encode(
          '<div class="ocr_page" title="bbox 0 0 9 9"><span class="ocr_line" title="bbox 0 0 4 4">',
        ),
        0xE9,
        ...utf8.encode('</span></div></body></html>'),
      ]);
      expect(parseHocrDocument(latin1).pages.single.lines.single.text, 'é');
    });
  });
}
