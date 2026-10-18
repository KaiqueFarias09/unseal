import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/azw4.dart' as azw4;
import 'package:unseal/comic.dart' as comic;
import 'package:unseal/comic7.dart' as comic7;
import 'package:unseal/docx.dart' as docx;
import 'package:unseal/epub.dart' as epub;
import 'package:unseal/fb2.dart' as fb2;
import 'package:unseal/hocr.dart' as hocr;
import 'package:unseal/html.dart' as html;
import 'package:unseal/mobi.dart' as mobi;
import 'package:unseal/odt.dart' as odt;
import 'package:unseal/page.dart' as page;
import 'package:unseal/pdf.dart' as pdf;
import 'package:unseal/txt.dart' as txt;
import 'package:unseal/unseal.dart' as unseal;

void main() {
  test('main entrypoint exposes OCR parsing and snapshot binding', () {
    final unseal.AltoDocument Function(Uint8List) parseAlto = unseal.parseAltoDocument;
    expect(parseAlto, isNotNull);
    expect(unseal.bindAltoToSnapshot, isNotNull);
    expect(() => parseAlto(Uint8List(0)), throwsA(isA<unseal.AltoException>()));
  });

  test('main entrypoint exposes PAGE XML parsing and snapshot binding', () {
    final unseal.PageXmlDocument Function(Uint8List) parsePage = unseal.parsePageXmlDocument;
    expect(parsePage, isNotNull);
    expect(unseal.bindPageToSnapshot, isNotNull);
    expect(unseal.PageXmlBindLimits.new, isNotNull);
    expect(() => parsePage(Uint8List(0)), throwsA(isA<unseal.PageXmlException>()));
    expect(() => parsePage(Uint8List(0)), throwsA(isA<unseal.InvalidBookException>()));
  });

  test('main entrypoint exposes hOCR parsing and snapshot binding', () {
    final unseal.HocrDocument Function(Uint8List) parseHocr = unseal.parseHocrDocument;
    expect(parseHocr, isNotNull);
    expect(unseal.bindHocrToSnapshot, isNotNull);
    expect(unseal.HocrBindLimits.new, isNotNull);
    expect(() => parseHocr(Uint8List(0)), throwsA(isA<unseal.HocrException>()));
    expect(() => parseHocr(Uint8List(0)), throwsA(isA<unseal.InvalidBookException>()));
  });

  test('the hOCR narrow entry point exposes its full signature surface', () {
    final hocr.HocrDocument Function(Uint8List) parseDocument = hocr.parseHocrDocument;
    final hocr.HocrSnapshotBinding Function({
      required hocr.HocrDocument document,
      required hocr.CanonicalTextSnapshot target,
      hocr.HocrBindLimits limits,
    })
    bindDocument = hocr.bindHocrToSnapshot;
    final List<hocr.HocrTitleProperty> Function(
      String, {
      required int maxProperties,
      required int maxTokens,
    })
    parseTitle = hocr.parseHocrTitle;

    // Every type the public signatures mention is exported here.
    final hocr.HocrDocument? document = null;
    final hocr.HocrPage? hocrPage = null;
    final hocr.HocrContainer? container = null;
    final hocr.HocrBlock? block = null;
    final hocr.HocrParagraph? paragraph = null;
    final hocr.HocrLine? line = null;
    final hocr.HocrWord? word = null;
    final hocr.HocrBox? box = null;
    final hocr.HocrBaseline? baseline = null;
    final hocr.HocrConfidence? confidence = null;
    final hocr.HocrFrameSource? frameSource = null;
    final hocr.HocrSnapshotBinding? binding = null;
    final hocr.HocrBoundSpatialText? boundText = null;
    final hocr.HocrAmbiguousUnit? ambiguousUnit = null;
    final hocr.HocrUnitPlace? place = null;
    final hocr.HocrBindLimits? limits = null;
    final hocr.HocrTitleProperty? titleProperty = null;
    final hocr.HocrException? exception = null;
    final hocr.HocrUnsupportedFeatureException? unsupported = null;
    final hocr.SpatialRect? rect = null;
    final hocr.SpatialUnit? unit = null;
    final hocr.SpatialTextZone? zone = null;
    final hocr.SpatialZoneKind? zoneKind = null;
    final hocr.SpatialTextPage? spatialPage = null;
    final hocr.SpatialTextProvenance? provenance = null;
    final hocr.SpatialTextOrigin? origin = null;
    final hocr.SpatialZoneLookup? lookup = null;

    final snapshot = hocr.CanonicalTextSnapshot(
      identity: hocr.PublicationRevision(publicationId: 'test:hocr-public'),
      occurrence: hocr.SectionOccurrence(
        sectionIndex: 0,
        resourcePath: 'page-1',
        readingOrderRevision: null,
      ),
      profile: hocr.TextProfile.of(
        algorithm: 'test.hocr',
        options: const {},
        planRevision: 'sha256:${'0' * 64}',
      ),
      text: 'word',
    );
    expect(snapshot.identity.sourceEvidence, hocr.SourceEvidence.unverified);
    expect(<Object?>[
      parseDocument,
      bindDocument,
      parseTitle,
      document,
      hocrPage,
      container,
      block,
      paragraph,
      line,
      word,
      box,
      baseline,
      confidence,
      frameSource,
      binding,
      boundText,
      ambiguousUnit,
      place,
      limits,
      titleProperty,
      exception,
      unsupported,
      rect,
      unit,
      zone,
      zoneKind,
      spatialPage,
      provenance,
      origin,
      lookup,
    ], isNotNull);
  });

  test('the PAGE narrow entry point exposes its full signature surface', () {
    final page.PageXmlDocument Function(Uint8List) parsePage = page.parsePageXmlDocument;
    final page.PageXmlSnapshotBinding Function({
      required page.PageXmlDocument document,
      required unseal.CanonicalTextSnapshot target,
      page.PageXmlBindLimits limits,
    })
    bindPage = page.bindPageToSnapshot;

    // Every type the public signatures mention is exported here.
    final page.PageXmlDocument? document = null;
    final page.PageXmlPage? pagePage = null;
    final page.PageXmlRegion? region = null;
    final page.PageXmlRegionKind? regionKind = null;
    final page.PageXmlTextLine? line = null;
    final page.PageXmlWord? word = null;
    final page.PageXmlPolygon? polygon = null;
    final page.PageXmlBaseline? baseline = null;
    final page.PageXmlTextContent? text = null;
    final page.PageXmlTextEquiv? textEquiv = null;
    final page.PageXmlReadingOrder? readingOrder = null;
    final page.PageXmlGroup? group = null;
    final page.PageXmlRegionRef? regionRef = null;
    final page.PageXmlSnapshotBinding? binding = null;
    final page.PageXmlBoundSpatialText? boundText = null;
    final page.PageXmlAmbiguousWord? ambiguousWord = null;
    final page.PageXmlWordPlace? wordPlace = null;
    final page.PageXmlBindLimits? limits = null;
    final page.PageXmlException? exception = null;
    final page.PageXmlUnsupportedFeatureException? unsupported = null;
    final page.SpatialRect? rect = null;
    final page.SpatialUnit? unit = null;
    final page.SpatialTextZone? zone = null;
    final page.SpatialZoneKind? zoneKind = null;
    final page.SpatialTextPage? spatialPage = null;
    final page.SpatialTextProvenance? provenance = null;
    final page.SpatialTextOrigin? origin = null;
    final page.SpatialZoneLookup? lookup = null;

    expect(<Object?>[
      parsePage,
      bindPage,
      document,
      pagePage,
      region,
      regionKind,
      line,
      word,
      polygon,
      baseline,
      text,
      textEquiv,
      readingOrder,
      group,
      regionRef,
      binding,
      boundText,
      ambiguousWord,
      wordPlace,
      limits,
      exception,
      unsupported,
      rect,
      unit,
      zone,
      zoneKind,
      spatialPage,
      provenance,
      origin,
      lookup,
    ], hasLength(30));
    expect(() => parsePage(Uint8List(0)), throwsA(isA<page.PageXmlException>()));
  });

  test('public reading facade uses the package identity as its namespace', () {
    final Future<unseal.Book> Function(Uint8List, {String password}) read = unseal.Unseal.read;
    final Future<unseal.Book> Function(String, {String password}) readFile = unseal.Unseal.readFile;
    final unseal.Book Function(Uint8List, {String password}) parse = unseal.Unseal.parse;
    final Future<unseal.BookMetadata> Function(Uint8List, {String password}) readMetadata =
        unseal.Unseal.readMetadata;
    final Future<unseal.BookMetadata> Function(String, {String password}) readMetadataFile =
        unseal.Unseal.readMetadataFile;
    final unseal.BookMetadata Function(Uint8List, {String password}) readMetadataSync =
        unseal.Unseal.readMetadataSync;
    final void Function(Uri) configureWorker = unseal.UnsealWorker.configure;

    expect(<Object?>[
      read,
      readFile,
      parse,
      readMetadata,
      readMetadataFile,
      readMetadataSync,
      configureWorker,
    ], hasLength(7));
  });

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
