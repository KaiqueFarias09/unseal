import 'package:e_livre/src/foundation/entities/entities.dart';

/// Merges [overlay] metadata over [base], Calibre `smart_update`
/// style: every overlay field that carries a value replaces the base
/// one; base values survive only when the overlay has nothing.
///
/// Identifiers are merged per key (overlay keys win). The [overlay]
/// format and cover win only when present; otherwise the base ones
/// are kept.
BookMetadata mergeBookMetadata(final BookMetadata base, final BookMetadata overlay) {
  return BookMetadata(
    format: overlay.cover != null || overlay.title != null ? overlay.format : base.format,
    title: _pick(overlay.title, base.title),
    titleSort: _pick(overlay.titleSort, base.titleSort),
    authorSort: _pick(overlay.authorSort, base.authorSort),
    bookProducer: _pick(overlay.bookProducer, base.bookProducer),
    authors: _pickList(overlay.authors, base.authors),
    languages: _pickList(overlay.languages, base.languages),
    publisher: _pick(overlay.publisher, base.publisher),
    description: _pick(overlay.description, base.description),
    isbn: _pick(overlay.isbn, base.isbn),
    subjects: _pickList(overlay.subjects, base.subjects),
    publishedAt: overlay.publishedAt ?? base.publishedAt,
    rights: _pick(overlay.rights, base.rights),
    series: _pick(overlay.series, base.series),
    seriesIndex: overlay.seriesIndex ?? base.seriesIndex,
    identifiers: {...base.identifiers, ...overlay.identifiers},
    cover: overlay.cover ?? base.cover,
  );
}

/// Fills missing title/authors of [metadata] from the file name.
///
/// Mirrors Calibre's fallback pattern: `Title - Author.ext` where the
/// title part may contain dashes but the author may not. Files that
/// do not match are returned unchanged.
BookMetadata applyFilenameFallback(final BookMetadata metadata, final String filePath) {
  final hasTitle = metadata.title != null && metadata.title!.isNotEmpty;
  final hasAuthors = metadata.authors.isNotEmpty;
  if (hasTitle && hasAuthors) return metadata;

  final fileName = _basenameWithoutExtension(filePath);
  final match = RegExp(r'^(.+)\s+-\s+([^-]+)$').firstMatch(fileName.trim());
  if (match == null) return metadata;

  final title = match.group(1)!.trim();
  final author = match.group(2)!.trim();
  if (title.isEmpty || author.isEmpty) return metadata;

  return mergeBookMetadata(
    metadata,
    BookMetadata(
      format: metadata.format,
      title: hasTitle ? null : title,
      authors: hasAuthors ? const <String>[] : [author],
    ),
  );
}

/// Parses a series index such as `2`, `2.5` or `0,5`.
double? parseSeriesIndex(final String? raw) {
  return raw == null ? null : double.tryParse(raw.trim().replaceAll(',', '.'));
}

String _basenameWithoutExtension(final String filePath) {
  final slash = filePath.lastIndexOf('/');
  final base = slash == -1 ? filePath : filePath.substring(slash + 1);
  final dot = base.lastIndexOf('.');

  return dot <= 0 ? base : base.substring(0, dot);
}

String? _pick(final String? overlay, final String? base) {
  if (overlay != null && overlay.isNotEmpty) return overlay;

  return base != null && base.isNotEmpty ? base : null;
}

List<String> _pickList(final List<String> overlay, final List<String> base) {
  return overlay.isNotEmpty ? overlay : base;
}
