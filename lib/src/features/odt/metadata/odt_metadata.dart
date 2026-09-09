import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../../foundation/entities/entities.dart';
import '../container/odt_package.dart';

/// Reads metadata from an ODT package without rendering the document body.
BookMetadata readOdtMetadata(final Uint8List bytes) =>
    readOdtPackageMetadata(OdtPackage.fromBytes(bytes));

/// Reads metadata from an already decoded ODT [archive].
BookMetadata readOdtMetadataFromArchive(final Archive archive) =>
    readOdtPackageMetadata(OdtPackage.fromArchive(archive));

/// Maps the metadata document of a validated [package] to the common model.
BookMetadata readOdtPackageMetadata(final OdtPackage package) {
  final document = package.meta;
  if (document == null) return const BookMetadata(format: BookFormat.odt);

  final root = document.rootElement;
  final title = _firstText(root, const {'title'});
  final creator = _firstText(root, const {'initial-creator', 'creator'});
  final subject = _firstText(root, const {'subject'});
  final description = _firstText(root, const {'description'});
  final language = _firstText(root, const {'language'});
  final publisher = _firstText(root, const {'publisher'});
  final rights = _firstText(root, const {'rights'});
  final identifier = _firstText(root, const {'identifier'});
  final date = _firstText(root, const {'creation-date', 'date', 'created'});
  final producer = _firstText(root, const {'generator', 'producer'});
  final keywords = _allText(root, 'keyword');
  final userDefined = _userDefined(root);
  final subjects = <String>[if (subject != null) ..._splitValues(subject), ...keywords];

  return BookMetadata(
    format: BookFormat.odt,
    title: title,
    authors: creator == null ? const <String>[] : _splitAuthors(creator),
    bookProducer: producer,
    languages: language == null ? const <String>[] : _splitValues(language),
    publisher: publisher,
    description: description,
    subjects: subjects,
    publishedAt: DateTime.tryParse(date ?? ''),
    rights: rights,
    series: userDefined['series'],
    seriesIndex: double.tryParse(userDefined['series_index'] ?? ''),
    identifiers: identifier == null
        ? const <String, String>{}
        : <String, String>{'identifier': identifier},
  );
}

String? _firstText(final XmlElement root, final Set<String> names) {
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (!names.contains(element.name.local.toLowerCase())) continue;
    final value = element.innerText.trim();
    if (value.isNotEmpty) return value;
  }

  return null;
}

List<String> _allText(final XmlElement root, final String name) => <String>[
  for (final element in root.descendants.whereType<XmlElement>())
    if (element.name.local.toLowerCase() == name && element.innerText.trim().isNotEmpty)
      element.innerText.trim(),
];

Map<String, String> _userDefined(final XmlElement root) {
  final result = <String, String>{};
  for (final element in root.descendants.whereType<XmlElement>()) {
    if (element.name.local.toLowerCase() != 'user-defined') continue;
    final name = odtAttribute(element, 'name')?.trim().toLowerCase();
    final value = element.innerText.trim();
    if (name != null && name.isNotEmpty && value.isNotEmpty) result[name] = value;
  }

  return result;
}

List<String> _splitAuthors(final String value) =>
    _splitList(value, RegExp(r'\s*(?:;|&|\band\b)\s*'));

List<String> _splitValues(final String value) => _splitList(value, RegExp(r'\s*(?:;|,)\s*'));

List<String> _splitList(final String value, final Pattern separator) => value
    .split(separator)
    .map((final item) => item.trim())
    .where((final item) => item.isNotEmpty)
    .toList(growable: false);
