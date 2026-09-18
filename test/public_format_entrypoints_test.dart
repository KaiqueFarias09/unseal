import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/azw4.dart' as azw4;
import 'package:e_livre/comic.dart' as comic;
import 'package:e_livre/comic7.dart' as comic7;
import 'package:e_livre/docx.dart' as docx;
import 'package:e_livre/epub.dart' as epub;
import 'package:e_livre/fb2.dart' as fb2;
import 'package:e_livre/html.dart' as html;
import 'package:e_livre/mobi.dart' as mobi;
import 'package:e_livre/odt.dart' as odt;
import 'package:e_livre/pdf.dart' as pdf;
import 'package:e_livre/txt.dart' as txt;
import 'package:test/test.dart';

void main() {
  test('format entrypoints expose complete standalone operation contracts', () {
    final azw4.Azw4PdfPayload Function(Uint8List) extractAzw4Payload = azw4.extractAzw4PdfPayload;
    final Uint8List Function(Uint8List) extractAzw4 = azw4.extractAzw4Pdf;
    final azw4.PdfBook Function(Uint8List, {String password}) parseAzw4 = azw4.parseAzw4Book;
    final azw4.BookMetadata Function(Uint8List, {String password}) readAzw4Metadata =
        azw4.readAzw4Metadata;

    final comic.ComicBook Function(Uint8List) parseComic = comic.parseComicBook;
    final comic.BookMetadata Function(Uint8List) readComicMetadata = comic.readComicMetadata;

    final Future<comic7.ComicBook> Function(Uint8List) parseComic7 = comic7.parseComic7Book;
    final Future<comic7.BookMetadata> Function(Uint8List) readComic7Metadata =
        comic7.readComic7Metadata;
    final Future<comic7.ComicBook> Function(Uint8List) parseCbc = comic7.parseCbcBook;
    final Future<comic7.BookMetadata> Function(Uint8List) readCbcMetadata = comic7.readCbcMetadata;

    final docx.DocumentBook Function(Uint8List) parseDocx = docx.parseDocxBook;
    final docx.DocumentBook Function(Archive) parseDocxArchive = docx.parseDocxArchive;
    final docx.BookMetadata Function(Uint8List) readDocxMetadata = docx.readDocxMetadata;
    final docx.BookMetadata Function(Archive) readDocxArchiveMetadata =
        docx.readDocxMetadataFromArchive;

    final epub.EpubBook Function(Uint8List) parseEpub = epub.parseEpubBook;
    final epub.EpubBook Function(Archive, {String? rootFilePath}) parseEpubArchive =
        epub.parseEpubArchive;
    final epub.BookMetadata Function(Archive, {String? rootFilePath}) readEpubMetadata =
        epub.readEpubMetadata;
    final String? Function(Archive) getEpubRoot = epub.getEpubRootFilePath;
    final String? Function(Archive) findEpubRoot = epub.findEpubRootFilePath;
    final epub.MediaOverlayDocument Function(String, {required String smilPath}) parseMediaOverlay =
        epub.parseMediaOverlay;
    final Duration? Function(String?) parseSmilClock = epub.parseSmilClock;
    final Uint8List Function(Uint8List, epub.EpubMetadataUpdate) updateEpubMetadata =
        epub.updateEpubMetadata;
    final Future<epub.EpubBook> Function(List<int>) epubFromBytes = epub.EpubBook.fromBytes;

    final fb2.Fb2Book Function(Uint8List) parseFb2 = fb2.parseFb2Book;
    final fb2.Fb2Book Function(ArchiveFile) parseFb2Archive = fb2.parseFb2Archive;
    final fb2.BookMetadata Function(Uint8List) readFb2Metadata = fb2.readFb2Metadata;

    final html.DocumentBook Function(List<int>, {String fileName}) parseHtml = html.parseHtmlBook;
    final html.BookMetadata Function(List<int>) readHtmlMetadata = html.readHtmlMetadata;
    final html.DocumentBook Function(List<int>) parseHtmlz = html.parseHtmlzBook;
    final html.DocumentBook Function(Archive) parseHtmlzArchive = html.parseHtmlzArchive;
    final html.BookMetadata Function(List<int>) readHtmlzMetadata = html.readHtmlzMetadata;
    final html.BookMetadata Function(Archive) readHtmlzArchiveMetadata =
        html.readHtmlzMetadataFromArchive;

    final mobi.MobiBook Function(Uint8List) parseMobi = mobi.parseMobiBook;
    final mobi.BookMetadata Function(Uint8List) readMobiMetadata = mobi.readMobiMetadata;

    final odt.DocumentBook Function(Uint8List) parseOdt = odt.parseOdtBook;
    final odt.DocumentBook Function(Archive) parseOdtArchive = odt.parseOdtArchive;
    final odt.BookMetadata Function(Uint8List) readOdtMetadata = odt.readOdtMetadata;
    final odt.BookMetadata Function(Archive) readOdtArchiveMetadata =
        odt.readOdtMetadataFromArchive;

    final pdf.PdfBook Function(Uint8List, {String password}) parsePdf = pdf.parsePdfBook;
    final pdf.BookMetadata Function(Uint8List, {String password}) readPdfMetadata =
        pdf.readPdfMetadata;

    final txt.DocumentBook Function(Uint8List, {String? sourceName}) parseTxt = txt.parseTxtBook;
    final txt.BookMetadata Function(Uint8List, {String? sourceName}) readTxtMetadata =
        txt.readTxtMetadata;
    final txt.DocumentBook Function(Uint8List, {String? sourceName}) parseTxtz = txt.parseTxtzBook;
    final txt.BookMetadata Function(Uint8List, {String? sourceName}) readTxtzMetadata =
        txt.readTxtzMetadata;

    expect(<Object>[
      extractAzw4Payload,
      extractAzw4,
      parseAzw4,
      readAzw4Metadata,
      parseComic,
      readComicMetadata,
      parseComic7,
      readComic7Metadata,
      parseCbc,
      readCbcMetadata,
      parseDocx,
      parseDocxArchive,
      readDocxMetadata,
      readDocxArchiveMetadata,
      parseEpub,
      parseEpubArchive,
      readEpubMetadata,
      getEpubRoot,
      findEpubRoot,
      parseMediaOverlay,
      parseSmilClock,
      updateEpubMetadata,
      epubFromBytes,
      parseFb2,
      parseFb2Archive,
      readFb2Metadata,
      parseHtml,
      readHtmlMetadata,
      parseHtmlz,
      parseHtmlzArchive,
      readHtmlzMetadata,
      readHtmlzArchiveMetadata,
      parseMobi,
      readMobiMetadata,
      parseOdt,
      parseOdtArchive,
      readOdtMetadata,
      readOdtArchiveMetadata,
      parsePdf,
      readPdfMetadata,
      parseTxt,
      readTxtMetadata,
      parseTxtz,
      readTxtzMetadata,
    ], hasLength(44));
  });
}
