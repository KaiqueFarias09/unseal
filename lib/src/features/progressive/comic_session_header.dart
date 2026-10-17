import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../foundation/archive/archive_random_access.dart';
import '../../foundation/archive/async_archive_random_access.dart';
import '../../foundation/entities/entities.dart' hide ArchiveEntry;
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import '../comic/entities/entities.dart';
import '../comic/exceptions/exceptions.dart';
import '../comic/metadata/comic_info.dart';
import '../comic/natural_page_sort.dart';
import 'session_policy.dart';

/// Sniff window: enough uncompressed bytes for the image-magic readers
/// behind [sniffImageType] on any real page payload.
const _sniffBytes = 64;

/// Builds the session header of a comic archive (CBZ zip or CBR RAR):
/// a [ComicBook] whose page list is complete (paths, natural order,
/// page roles, cover reference) while every page's bytes stay empty
/// until the session loads them.
///
/// Page classification sniffs the first payload bytes of each file
/// entry, so the page set matches the full parse even for images
/// stored under unusual names. The cover inflates unless it exceeds
/// [SessionPolicy.coverMaxBytes]; its pixel dimensions are only known
/// when the cover is materialized.
Future<ComicBook> buildComicSessionHeader(
  final AsyncArchiveRandomAccess source, {
  required final BookFormat format,
  final SessionPolicy policy = const SessionPolicy(),
}) async {
  final comicInfo = await _readComicInfo(source);
  final pages = await _pageRecords(source);
  if (pages.isEmpty) throw const ComicException('No image pages found in the comic archive.');

  final images = <BinaryFile>[
    for (final page in pages)
      BinaryFile(
        content: Uint8List(0),
        name: page.name.split('/').last,
        type: page.sniffedType!.fileExtension,
        path: page.name,
      ),
  ];

  final pageInfo = comicPageInfoFor(comicInfo, images.length);
  final declaredCoverIndex = pageInfo.indexWhere(
    (final page) => page.type == ComicPageType.frontCover,
  );
  final cover = await _materializeCover(
    source,
    images[declaredCoverIndex < 0 ? 0 : declaredCoverIndex],
    policy,
  );
  final metadata = comicInfo?.metadata.copyWith(format: format) ?? BookMetadata(format: format);
  final coverType = cover.isEmpty ? null : sniffImageType(cover.content);
  final coverMetadata = coverType == null
      ? metadata
      : metadata.copyWith(
          cover: BookCover(
            bytes: cover.content,
            type: coverType,
            width: imageSize(cover.content)?.width,
            height: imageSize(cover.content)?.height,
          ),
        );

  return ComicBook(
    cover: cover,
    metadata: coverMetadata,
    pages: images,
    pageInfo: pageInfo,
    readingDirection: comicInfo?.readingDirection ?? ComicReadingDirection.unspecified,
    format: format,
  );
}

class _PageRecord {
  const _PageRecord(this.record, this.sniffedType);

  final ArchiveEntry record;
  final ImageType? sniffedType;

  String get name => record.name;
}

/// Container entries that sniff as images, in the natural page order of
/// the full parse: uniform directory depths sort by full path, mixed
/// depths sort by basename with the full path as tie-breaker.
Future<List<_PageRecord>> _pageRecords(final AsyncArchiveRandomAccess source) async {
  final candidates = <_PageRecord>[];
  for (final record in source.entries) {
    if (!record.isFile) continue;
    if (record.name.toLowerCase() == 'comicinfo.xml') continue;

    final sniffed = sniffImageType(await source.head(record, _sniffBytes));
    if (sniffed != null) candidates.add(_PageRecord(record, sniffed));
  }

  final depths = candidates.map((final page) => '/'.allMatches(page.name).length).toSet();
  if (depths.length == 1) {
    candidates.sort((final a, final b) => compareComicPageNames(a.name, b.name));

    return candidates;
  }

  candidates.sort((final a, final b) {
    final basenameOrder = compareComicPageNames(_basename(a.name), _basename(b.name));
    if (basenameOrder != 0) return basenameOrder;

    return compareComicPageNames(a.name, b.name);
  });

  return candidates;
}

/// The comic's first page in reading order, materialized when it fits
/// the policy cap; the empty file mirrors "cover not available".
Future<BinaryFile> _materializeCover(
  final AsyncArchiveRandomAccess source,
  final BinaryFile placeholder,
  final SessionPolicy policy,
) async {
  final record = source.find(placeholder.path);
  if (record == null || record.uncompressedSize > policy.coverMaxBytes) return BinaryFile.empty();

  return BinaryFile(
    content: await source.inflate(record),
    name: placeholder.name,
    type: placeholder.type,
    path: placeholder.path,
  );
}

Future<ComicInfo?> _readComicInfo(final AsyncArchiveRandomAccess source) async {
  final record = source.find('ComicInfo.xml');
  if (record == null) return null;

  // An unparsable ComicInfo degrades to default metadata, like the full parse.
  return ComicInfo.parse(convert.utf8.decode(await source.inflate(record), allowMalformed: true));
}

String _basename(final String path) {
  final separator = path.lastIndexOf('/');

  return separator == -1 ? path : path.substring(separator + 1);
}
