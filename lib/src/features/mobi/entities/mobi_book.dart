import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/utils/mobi_metadata_mapper.dart';
import 'package:e_livre/src/features/reading/book.dart';
import 'package:e_livre/src/foundation/entities/entities.dart';

/// A parsed MOBI 6 / KF8 (AZW3) book.
class MobiBook extends Book {
  /// Creates a [MobiBook] from already parsed parts.
  MobiBook({
    required this.navigation,
    required this.files,
    required this.cover,
    required this.header,
    required super.format,
  });

  /// The navigation (table of contents) of the book.
  @override
  final Navigation navigation;

  /// The extracted files of the book.
  @override
  final Files files;

  /// The cover image, or an empty file when none was found.
  final BinaryFile cover;

  /// The MOBI header the book was parsed from.
  final MobiHeader header;

  /// The book chapters.
  ///
  /// MOBI 6 stores the whole book as one HTML stream; this splits it
  /// at the table of contents anchors (plus a leading front-matter
  /// part when present), giving chapter-by-chapter access comparable
  /// to the per-file output of the other formats. KF8 books already
  /// expose one file per chapter through [files] and return an empty
  /// list here. Computed once on first access.
  late final List<MobiChapter> chapters = _splitChapters();

  /// The book author names.
  List<String> get creators => metadata.authors;

  /// The book language code.
  String get language => metadata.languages.isEmpty ? '' : metadata.languages.first;

  /// The format-agnostic metadata of this book.
  @override
  BookMetadata get metadata => mobiBookMetadata(header, coverFile: cover);

  /// The book publisher.
  String? get publisher => metadata.publisher;

  /// The book title.
  String get title => header.exth?.title ?? header.title;

  /// The MOBI version (6 or 8).
  int get version => header.mobiVersion;

  MobiChapter _chapter(final int index, final String title, final String html) {
    final name = 'chapter${index.toString().padLeft(5, '0')}.html';
    return MobiChapter(
      title: title,
      file: TextFile(name: name, type: 'html', path: name, content: html),
    );
  }

  List<MobiChapter> _splitChapters() {
    if (files.html.isEmpty) return const <MobiChapter>[];
    final html = files.html.first.content;

    // Collect the anchor position of every TOC entry.
    final anchors = <(int, String)>[];
    for (final point in navigation.navPoints) {
      final number = _fileposLinkPattern.firstMatch(point.content);
      if (number == null) {
        continue;
      }
      final position = html.indexOf('id="filepos${number.group(1)}"');
      if (position >= 0) {
        anchors.add((position, point.label));
      }
    }
    if (anchors.isEmpty) return const <MobiChapter>[];
    anchors.sort((final a, final b) => a.$1.compareTo(b.$1));

    // Deduplicate anchors pointing at the same position.
    final boundaries = <(int, String)>[];
    for (final anchor in anchors) {
      if (boundaries.isEmpty || boundaries.last.$1 != anchor.$1) {
        boundaries.add(anchor);
      }
    }

    final chapters = <MobiChapter>[];
    var index = 0;
    // Leading front matter (cover, title page) before the first
    // anchor becomes its own chapter when it has visible content.
    if (boundaries.first.$1 > 0) {
      final leading = html.substring(0, boundaries.first.$1);
      if (leading.replaceAll(_anyTagPattern, '').trim().isNotEmpty) {
        chapters.add(_chapter(index++, title, leading));
      }
    }

    // Each anchor marks the start of its chapter's content.
    for (var i = 0; i < boundaries.length; i++) {
      final start = boundaries[i].$1;
      final end = i + 1 < boundaries.length ? boundaries[i + 1].$1 : html.length;
      chapters.add(_chapter(index++, boundaries[i].$2, html.substring(start, end)));
    }

    return chapters;
  }
}

/// A chapter of a MOBI 6 book, split from its single HTML stream at
/// the table of contents anchors.
final class MobiChapter {
  const MobiChapter({required this.title, required this.file});

  /// Chapter title from the table of contents.
  final String title;

  /// The chapter HTML slice.
  final TextFile file;

  @override
  String toString() => 'MobiChapter(title: $title, file: ${file.name})';
}

final RegExp _fileposLinkPattern = RegExp(r'#filepos(\d+)$');

final RegExp _anyTagPattern = RegExp('<[^>]*>');
