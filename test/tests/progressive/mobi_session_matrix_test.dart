import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import '../mobi/mobi_fixture_builder.dart';

Uint8List _bookFixture(final String name) =>
    File('test/resources/books/mobi/$name').readAsBytesSync();
Uint8List _mobiFixture(final String name) => File('test/resources/mobi/$name').readAsBytesSync();

/// The whole-book text the eager parse produces, the parity target.
String _eagerText(final Uint8List bytes) {
  final eager = Unseal.parse(bytes) as MobiBook;

  return eager.files.html.map(documentTextOf).join();
}

Future<String> _sessionText(final Uint8List bytes) async {
  final session = await BookSession.open(bytes);
  try {
    final buffer = StringBuffer();
    for (final item in session.book.readingOrder) {
      buffer.write(await session.loadDocumentText(item.name));
    }

    return buffer.toString();
  } finally {
    session.dispose();
  }
}

void main() {
  group('compression matrix', () {
    // Declared-origin generated fixtures: the licensed real corpus
    // carries PalmDOC only, so HUFF/CDIC and stored compression ride
    // repository-authored books built with the same generators the
    // eager tests use.
    test('HUFF/CDIC MOBI 6 session equals eager text', () async {
      final html =
          '<html><head><title>T</title></head><body>'
          '<p>Primeiro parágrafo com acentuação.</p>'
          '<a filepos="0000000096">next</a>'
          '<p>Segundo parágrafo após o link.</p>'
          '</body></html>';
      final book = buildPdb('SyntheticHuffSession', [
        buildMobiRecord0(
          compressionType: 0x4448,
          textRecordCount: 1,
          huffOffset: 2,
          huffRecordCount: 2,
          title: 'HUFF Session',
        ),
        Uint8List.fromList(convert.utf8.encode(html)),
        buildHuffHeader(),
        buildCdic(),
      ]);

      expect(await _sessionText(book), _eagerText(book));
    });

    test('stored MOBI 6 session equals eager text across records', () async {
      String chapter(final String title, final int fill) =>
          '<html><body><h1>$title</h1>'
          '<p>${List.filled(fill, 'palavra').join(' ')}</p>'
          '</body></html>';
      final records = <Uint8List>[
        buildMobiRecord0(
          compressionType: 1,
          textRecordCount: 3,
          firstImageIndex: 4,
          title: 'Stored Session',
        ),
        ...[
          chapter('Capítulo 1', 300),
          chapter('Capítulo 2', 300),
          chapter('Capítulo 3', 300),
        ].map((final text) => Uint8List.fromList(convert.utf8.encode(text))),
        tinyPng,
      ];
      final book = buildPdb('SyntheticStoredSession', records);

      expect(await _sessionText(book), _eagerText(book));
    });

    test('PalmDOC MOBI 6 with TOC anchors splits into sections', () async {
      final bytes = _bookFixture('alice-old-pg.mobi');
      final session = await BookSession.open(bytes);
      try {
        expect(session.book.readingOrder, hasLength(greaterThan(1)));
      } finally {
        session.dispose();
      }
    });
  });

  group('real fixture matrix', () {
    final fixtures = <(String, Uint8List, BookFormat)>[
      ('books/mobi/alice-old-pg.mobi', _bookFixture('alice-old-pg.mobi'), BookFormat.mobi),
      ('books/mobi/alice-kf8-pg.azw3', _bookFixture('alice-kf8-pg.azw3'), BookFormat.azw3),
      ('mobi/alice-joint.mobi', _mobiFixture('alice-joint.mobi'), BookFormat.azw3),
      ('mobi/alice-old.mobi', _mobiFixture('alice-old.mobi'), BookFormat.mobi),
      ('mobi/alice-kf8.azw3', _mobiFixture('alice-kf8.azw3'), BookFormat.azw3),
    ];

    for (final (name, bytes, format) in fixtures) {
      test('$name: session text equals eager text', () async {
        final session = await BookSession.open(bytes);
        try {
          expect((session.book as MobiBook).format, format);

          expect(await _sessionText(bytes), _eagerText(bytes));
        } finally {
          session.dispose();
        }
      });
    }
  });

  group('out-of-subset Palm databases', () {
    test('PalmDOC PDB refuses as a session format', () async {
      // A TEXt/REAd database the eager parse reads as PalmDOC.
      final records = <Uint8List>[
        Uint8List(26)..buffer.asByteData().setUint16(0, 2),
        Uint8List.fromList(convert.utf8.encode('PalmDOC text payload')),
      ];
      final book = buildPdb('PlainPalmdoc', records, ident: 'TEXTREAD');

      await expectLater(BookSession.open(book), throwsA(isA<SessionUnsupportedFormatException>()));
    });
  });

  group('AZW4', () {
    test('refuses as a session format with the wrapper message', () async {
      final bytes = _bookFixture('synthetic.azw4');

      await expectLater(
        BookSession.open(bytes),
        throwsA(
          isA<SessionUnsupportedFormatException>().having(
            (final error) => error.message,
            'message',
            contains('AZW4'),
          ),
        ),
      );
    });
  });
}
