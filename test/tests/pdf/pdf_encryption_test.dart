import 'dart:io';
import 'dart:typed_data';

import 'package:e_livre/e_livre.dart';
import 'package:e_livre/src/features/pdf/header/pdf_document.dart';
import 'package:e_livre/src/features/pdf/header/pdf_object.dart';
import 'package:test/test.dart';

import 'pdf_fixture_builder.dart';

/// The standard security handler across every supported revision,
/// proven the way pypdf's `tests/test_encryption.py` proves it: each
/// encrypted fixture must extract the exact same page text as the
/// unencrypted original it was generated from
/// (`test/resources/pdf/dickens-sample.pdf`).
///
/// Fixtures live in `test/resources/pdf/encrypted/` with their
/// generating commands and passwords in that folder's `MANIFEST.md`.
void main() {
  const encryptedDir = 'test/resources/pdf/encrypted';
  const userPassword = 'user123';
  const ownerPassword = 'owner456';

  /// The clear source's only-page text — the ground truth every
  /// revision must reproduce byte for byte.
  final originalText = parsePdfBook(
    File('test/resources/pdf/dickens-sample.pdf').readAsBytesSync(),
  ).pageTexts.single.text;

  Uint8List fixture(final String name) => File('$encryptedDir/$name').readAsBytesSync();

  /// Asserts [bytes] opens with [password] and extracts exactly the
  /// original's text.
  void expectOpensWithText(final Uint8List bytes, final String password) {
    final book = parsePdfBook(bytes, password: password);

    expect(book.pageCount, 1);
    expect(book.hasTextLayer, isTrue);
    expect(book.pageTexts.single.text, originalText);
  }

  group('PDF encryption (authentication)', () {
    test('an unencrypted document parses without a password argument', () {
      expect(
        parsePdfBook(
          File('test/resources/pdf/dickens-sample.pdf').readAsBytesSync(),
        ).pageTexts.single.text,
        originalText,
      );
    });

    test('an empty password opens owner-password-only documents', () {
      expectOpensWithText(fixture('owner-only.pdf'), '');
    });

    test('an empty password is rejected when a user password is set', () {
      PdfEncryptedException? caught;
      try {
        parsePdfBook(fixture('r6.pdf'));
      } on PdfEncryptedException catch (error) {
        caught = error;
      }

      expect(caught, isNotNull);
      expect(caught!.requiresNonEmptyPassword, isTrue);
    });

    test('the correct user password opens every revision', () {
      for (final name in [
        'r3-rc4-128.pdf',
        'r4-rc4-128.pdf',
        'r4-aes128.pdf',
        'r5.pdf',
        'r6.pdf',
      ]) {
        expectOpensWithText(fixture(name), userPassword);
      }
    });

    test('the correct owner password opens user-password documents', () {
      for (final name in ['r3-rc4-128.pdf', 'r4-aes128.pdf', 'r6.pdf']) {
        final document = PdfDocument.parse(fixture(name), password: ownerPassword);

        expect(document.security, isNotNull);
        expect(document.security!.isOwnerAuthenticated, isTrue);
      }
    });

    test('a wrong password throws an enriched PdfEncryptedException', () {
      for (final name in [
        'r3-rc4-128.pdf',
        'r4-rc4-128.pdf',
        'r4-aes128.pdf',
        'r5.pdf',
        'r6.pdf',
      ]) {
        PdfEncryptedException? caught;
        try {
          parsePdfBook(fixture(name), password: 'not-the-password');
        } on PdfEncryptedException catch (error) {
          caught = error;
        }

        expect(caught, isNotNull, reason: '$name should reject a wrong password');
        expect(caught!.requiresNonEmptyPassword, isFalse, reason: name);
      }
    });

    test('a non-standard encryption filter throws a clear PdfException', () {
      final fixture = twoPageFixture(withOutline: false)
        ..addObject(10, '<< /Filter /Adobe.PPKLite /V 2 >>')
        ..trailerExtra = ' /Encrypt 10 0 R';

      expect(
        () => parsePdfBook(fixture.build()),
        throwsA(
          isA<PdfException>().having(
            (final error) => error.message,
            'message',
            contains('Unsupported encryption filter'),
          ),
        ),
      );
    });

    test('a trailer /Encrypt with no matching object throws PdfEncryptedException', () {
      final fixture = twoPageFixture(withOutline: false)..trailerExtra = ' /Encrypt 99 0 R';

      expect(() => parsePdfBook(fixture.build()), throwsA(isA<PdfEncryptedException>()));
    });

    test('password threads through BookReader', () {
      final bytes = fixture('r6.pdf');

      final book = BookReader.parseBook(bytes, password: userPassword);
      expect(book, isA<PdfBook>());
      expect((book as PdfBook).pageCount, 1);
      expect(() => BookReader.parseBook(bytes), throwsA(isA<PdfEncryptedException>()));
    });
  });

  group('PDF encryption (text equality per revision)', () {
    final revisions = <(String, String)>[
      ('r3-rc4-128.pdf', 'R3 RC4-128 (/V 2)'),
      ('r4-rc4-128.pdf', 'R4 RC4-128 (/V 4 /V2)'),
      ('r4-aes128.pdf', 'R4 AES-128 (/V 4 /AESV2)'),
      ('r5.pdf', 'R5 AES-256 (deprecated)'),
      ('r6.pdf', 'R6 AES-256 (ISO 32000-2)'),
    ];

    for (final (name, label) in revisions) {
      test('$label extracts the same text as the clear original', () {
        expectOpensWithText(fixture(name), userPassword);
      });
    }

    test('R6 AES-256 owner-only file extracts the same text with no password', () {
      expectOpensWithText(fixture('owner-only.pdf'), '');
    });
  });

  group('PDF encryption (real-world fixture)', () {
    test('pdf.js pr6531_1.pdf opens with its documented password', () {
      final document = PdfDocument.parse(fixture('pr6531_1.pdf'), password: 'asdfasdf');
      final book = parsePdfBook(fixture('pr6531_1.pdf'), password: 'asdfasdf');

      expect(book.pageCount, 1);
      // The page is a scanned image: its decrypted content stream is
      // exactly the clear original's (verified against qpdf --decrypt).
      final pages = document.resolve(document.catalog!['Pages']!) as PdfDictionary;
      final kids = document.resolve(pages['Kids']!) as PdfArray;
      final page = document.resolve(kids.items.first) as PdfDictionary;
      final stream = document.resolve(page['Contents']!) as PdfStream;

      expect(stream.bytes, 'q\n576 0 0 390 0 0 cm\n/Im0 Do\nQ\n'.codeUnits);
    });

    test('pdf.js pr6531_1.pdf rejects the wrong password', () {
      expect(
        () => parsePdfBook(fixture('pr6531_1.pdf'), password: 'qwerty'),
        throwsA(isA<PdfEncryptedException>()),
      );
    });
  });
}
