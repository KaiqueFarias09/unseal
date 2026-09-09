import 'package:e_livre/src/foundation/entities/entities.dart';
import 'package:xml/xml.dart';

/// Maps DOCX core properties to format-agnostic book metadata.
BookMetadata readDocxCoreMetadata(final XmlDocument? document) {
  if (document == null) return const BookMetadata(format: BookFormat.docx);

  final root = document.rootElement;
  final title = _firstText(root, 'title');
  final creator = _firstText(root, 'creator');
  final subject = _firstText(root, 'subject');
  final description = _firstText(root, 'description');
  final language = _firstText(root, 'language');
  final identifier = _firstText(root, 'identifier');
  final created = _firstText(root, 'created');
  final modified = _firstText(root, 'modified');
  final rights = _firstText(root, 'rights');

  return BookMetadata(
    format: BookFormat.docx,
    title: title,
    authors: _splitAuthors(creator),
    subjects: _splitValues(subject),
    description: description,
    languages: language == null ? const <String>[] : <String>[language],
    publishedAt: DateTime.tryParse(created ?? '') ?? DateTime.tryParse(modified ?? ''),
    identifiers: identifier == null
        ? const <String, String>{}
        : <String, String>{'identifier': identifier},
    rights: rights,
  );
}

List<String> _splitAuthors(final String? value) {
  if (value == null || value.trim().isEmpty) return const <String>[];

  return value
      .split(RegExp(r'\s*(?:;|&|\band\b)\s*', caseSensitive: false))
      .map((final author) => author.trim())
      .where((final author) => author.isNotEmpty)
      .toList(growable: false);
}

List<String> _splitValues(final String? value) {
  if (value == null || value.trim().isEmpty) return const <String>[];

  return value
      .split(RegExp(r'\s*(?:;|,)\s*'))
      .map((final item) => item.trim())
      .where((final item) => item.isNotEmpty)
      .toList(growable: false);
}

String? _firstText(final XmlElement root, final String localName) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local != localName) continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}
