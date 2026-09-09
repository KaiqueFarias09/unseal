import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';

import '../../foundation/archive/archive_access.dart';
import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/elivre_exception.dart';
import '../azw4/parse_azw4_book.dart';
import '../comic/parse_comic_book.dart';
import '../comic7/parse_comic7_book.dart';
import '../detection/detect_format.dart';
import '../detection/entities/detected_format.dart';
import '../docx/parse_docx_book.dart';
import '../epub/exceptions/exceptions.dart';
import '../epub/parse_epub_book.dart';
import '../fb2/parse_fb2_book.dart';
import '../html/parse_html_book.dart';
import '../mobi/parse_mobi_book.dart';
import '../odt/parse_odt_book.dart';
import '../pdf/parse_pdf_book.dart';
import '../txt/archive/txtz_archive.dart';
import '../txt/parse_txt_book.dart';

/// Runs synchronous parsing on the execution adapter selected by Platform.
typedef BookParseExecutor = Future<Book> Function(Book Function() parse, Uint8List bytes);

/// Runs synchronous metadata extraction on the execution adapter selected by Platform.
typedef MetadataReadExecutor =
    Future<BookMetadata> Function(BookMetadata Function() read, Uint8List bytes);

/// Owns platform-neutral format detection and parse/read dispatch.
// This internal namespace keeps all format selection in Reading.
// ignore: avoid_classes_with_only_static_members
abstract final class BookDispatch {
  /// Parses the book from [bytes], opening encrypted PDFs with
  /// [password].
  static Future<Book> openFromBytes(
    final Uint8List bytes, {
    required final BookParseExecutor execute,
    final String password = '',
  }) {
    if (bytes.isEmpty) throw EmptyBytesException();

    final detected = detectFormat(bytes);
    if (detected == DetectedFormat.comic7 ||
        detected == DetectedFormat.epub && _isCbcBytes(bytes)) {
      return _parseBookAsync(bytes, password: password, detected: detected);
    }

    return execute(() => parseBook(bytes, password: password), bytes);
  }

  /// Synchronously parses [bytes] with the matching format adapter,
  /// opening encrypted PDFs with [password].
  static Book parseBook(final Uint8List bytes, {final String password = ''}) {
    switch (detectFormat(bytes)) {
      case DetectedFormat.epub:
        return _parseZipBook(bytes);
      case DetectedFormat.mobiFamily:
        return parseMobiBook(bytes);
      case DetectedFormat.fb2:
        return parseFb2Book(bytes);
      case DetectedFormat.comic:
        return parseComicBook(bytes);
      case DetectedFormat.pdf:
        return parsePdfBook(bytes, password: password);
      case DetectedFormat.txt:
        return parseTxtBook(bytes);
      case DetectedFormat.html:
        return parseHtmlBook(bytes);
      case DetectedFormat.azw4:
        return parseAzw4Book(bytes, password: password);
      case DetectedFormat.comic7:
        throw const FormatNotSupportedException(
          'CB7 parsing is asynchronous; use BookReader.openFromBytes or parseComic7Book.',
        );
    }
  }

  /// Reads only metadata from [bytes], opening encrypted PDFs with
  /// [password].
  static Future<BookMetadata> readMetadataFromBytes(
    final Uint8List bytes, {
    required final MetadataReadExecutor execute,
    final String password = '',
  }) {
    if (bytes.isEmpty) throw EmptyBytesException();

    final detected = detectFormat(bytes);
    if (detected == DetectedFormat.comic7 ||
        detected == DetectedFormat.epub && _isCbcBytes(bytes)) {
      return _readMetadataAsync(bytes, detected: detected);
    }

    return execute(() => readMetadataSync(bytes, password: password), bytes);
  }

  /// Synchronously reads metadata from [bytes], opening encrypted
  /// PDFs with [password].
  static BookMetadata readMetadataSync(final Uint8List bytes, {final String password = ''}) {
    switch (detectFormat(bytes)) {
      case DetectedFormat.epub:
        final archive = ZipDecoder().decodeBytes(bytes);
        if (_isEpubArchive(archive)) return readEpubMetadata(archive);
        if (_hasFb2Entry(archive)) return readFb2Metadata(bytes);
        if (_isCbcArchive(archive)) {
          throw const FormatNotSupportedException(
            'CBC metadata is asynchronous; use BookReader.readMetadataFromBytes.',
          );
        }
        if (_isDocxArchive(archive)) return readDocxMetadataFromArchive(archive);
        if (_isOdtArchive(archive)) return readOdtMetadataFromArchive(archive);
        if (_isHtmlzArchive(archive)) return readHtmlzMetadataFromArchive(archive);
        if (_isTxtzArchive(archive)) return readTxtzMetadata(bytes);

        return readComicMetadata(bytes);
      case DetectedFormat.mobiFamily:
        return readMobiMetadata(bytes);
      case DetectedFormat.fb2:
        return readFb2Metadata(bytes);
      case DetectedFormat.comic:
        return readComicMetadata(bytes);
      case DetectedFormat.pdf:
        return readPdfMetadata(bytes, password: password);
      case DetectedFormat.txt:
        return readTxtMetadata(bytes);
      case DetectedFormat.html:
        return readHtmlMetadata(bytes);
      case DetectedFormat.azw4:
        return readAzw4Metadata(bytes, password: password);
      case DetectedFormat.comic7:
        throw const FormatNotSupportedException(
          'CB7 metadata is asynchronous; use BookReader.readMetadataFromBytes.',
        );
    }
  }

  static Future<Book> _parseBookAsync(
    final Uint8List bytes, {
    required final DetectedFormat detected,
    required final String password,
  }) async {
    if (detected == DetectedFormat.comic7) return parseComic7Book(bytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isCbcArchive(archive)) return parseCbcBook(bytes);

    return parseBook(bytes, password: password);
  }

  static Future<BookMetadata> _readMetadataAsync(
    final Uint8List bytes, {
    required final DetectedFormat detected,
  }) async {
    if (detected == DetectedFormat.comic7) return readComic7Metadata(bytes);
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isCbcArchive(archive)) return readCbcMetadata(bytes);

    return readMetadataSync(bytes);
  }

  static ArchiveFile? _fb2Entry(final Archive archive) => archive.files.firstWhereOrNull(
    (final file) => file.isFile && file.name.toLowerCase().endsWith('.fb2'),
  );

  static bool _hasFb2Entry(final Archive archive) => _fb2Entry(archive) != null;

  static bool _isEpubArchive(final Archive archive) =>
      archive.files.any((final file) => file.isFile && file.name == 'META-INF/container.xml') ||
      findEpubRootFilePath(archive) != null;

  static bool _isCbcBytes(final Uint8List bytes) {
    try {
      return _isCbcArchive(ZipDecoder().decodeBytes(bytes));
    } on Object {
      return false;
    }
  }

  static bool _isCbcArchive(final Archive archive) => archive.files.any(
    (final file) => file.isFile && normalizeZipPath(file.name).toLowerCase() == 'comics.txt',
  );

  static bool _isDocxArchive(final Archive archive) =>
      findArchiveFile(archive, 'word/document.xml') != null;

  static bool _isOdtArchive(final Archive archive) =>
      findArchiveFile(archive, 'content.xml') != null;

  static bool _isHtmlzArchive(final Archive archive) => archive.files.any(
    (final file) =>
        file.isFile && !normalizeZipPath(file.name).contains('/') && _isHtmlName(file.name),
  );

  static bool _isTxtzArchive(final Archive archive) =>
      archive.files.any((final file) => file.isFile && isTxtzTextExtension(_extension(file.name)));

  static bool _isImageName(final String name) {
    final lower = name.toLowerCase();

    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  static bool _looksLikeComic(final Archive archive) =>
      archive.files.any((final file) => file.isFile && _isImageName(file.name));

  static bool _isHtmlName(final String path) {
    final extension = _extension(path);

    return extension == 'html' || extension == 'htm' || extension == 'xhtml';
  }

  static String _extension(final String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';

    return name.substring(dot + 1).toLowerCase();
  }

  static Book _parseZipBook(final Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    if (_isEpubArchive(archive)) return parseEpubArchive(archive);

    if (_isCbcArchive(archive)) {
      throw const FormatNotSupportedException(
        'CBC parsing is asynchronous; use BookReader.openFromBytes.',
      );
    }

    final fb2Entry = _fb2Entry(archive);
    if (fb2Entry != null) return parseFb2Archive(fb2Entry);
    if (_isDocxArchive(archive)) return parseDocxArchive(archive);
    if (_isOdtArchive(archive)) return parseOdtArchive(archive);
    if (_isHtmlzArchive(archive)) return parseHtmlzArchive(archive);
    if (_isTxtzArchive(archive)) return parseTxtzArchive(readTxtzArchive(archive));
    if (_looksLikeComic(archive)) return parseComicBook(bytes);

    throw const FormatNotSupportedException(
      'Zip container holds neither an EPUB package, an FB2 document '
      'nor a supported document or comic.',
    );
  }
}
