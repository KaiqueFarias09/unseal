import 'package:unseal/unseal.dart';

/// Builds an EPUB whose reading order holds one HTML section per entry
/// of [sections], in key order — the shared fixture of the search-index
/// suites.
Book buildIndexedBook(final Map<int, String> sections) {
  return EpubBook(
    navigation: Navigation(title: 'Contents', navPoints: const []),
    files: Files(
      images: const [],
      css: const [],
      html: [
        for (final entry in sections.entries)
          TextFile(
            name: 'section${entry.key}.html',
            type: 'xhtml',
            path: 'section${entry.key}.html',
            content: entry.value,
          ),
      ],
      fonts: const [],
      others: const [],
    ),
    cover: BinaryFile.empty(),
    package: Epub2Package(
      xmlns: null,
      uniqueIdentifier: 'uid',
      version: '2.0',
      metadata: Epub2Metadata(
        rights: const [],
        contributor: null,
        creator: 'Test Author',
        publisher: null,
        title: 'Index Fixture',
        date: '2026-01-01',
        language: 'pt',
        subject: null,
        description: null,
        identifiers: const ['index-fixture'],
        uniqueIdentifierValue: 'index-fixture',
      ),
      manifest: Manifest(
        items: [
          for (final sectionIndex in sections.keys)
            ManifestItem(
              path: 'section$sectionIndex.html',
              id: 's$sectionIndex',
              mediaType: 'application/xhtml+xml',
            ),
        ],
      ),
      spine: Spine(
        tocId: null,
        items: [for (final sectionIndex in sections.keys) 's$sectionIndex'],
      ),
      guide: null,
    ),
  );
}
