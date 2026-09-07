import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';

import 'package:e_livre/src/features/epub/utils/archive_utils.dart';
import 'package:e_livre/src/features/epub/utils/xml_utils.dart';
import 'package:e_livre/src/foundation/entities/navigation/nav_point.dart';
import 'package:e_livre/src/foundation/entities/navigation/navigation.dart';

import 'package:xml/xml.dart';

/// Retrieves the navigation (table of contents) of an EPUB.
///
/// Tries the NCX document referenced by the spine `toc` attribute
/// first (EPUB 2 and most EPUB 3 books ship one), then the EPUB 3
/// `nav` document (a manifest item with `properties="nav"`).
Navigation getEpubNavigation(
  final EpubPackage package,
  final Archive archive,
  final String? rootFilePath,
) {
  final candidateIds = <String>[
    if (package.spine.tocId != null) package.spine.tocId!,
    if (_navDocumentId(package) != null) _navDocumentId(package)!,
    ...package.manifest.items
        .where(
          (final item) => item.properties.any((final property) => property.toLowerCase() == 'nav'),
        )
        .map((final item) => item.id),
    ...package.manifest.items
        .where((final item) => _mediaType(item.mediaType) == 'application/x-dtbncx+xml')
        .map((final item) => item.id),
  ];

  final triedIds = <String>{};
  for (final tocId in candidateIds) {
    if (!triedIds.add(tocId)) continue;

    final tocManifestItem = package.manifest.items.firstWhereOrNull(
      (final element) => element.id == tocId,
    );
    if (tocManifestItem == null) continue;

    final tocFileEntryPath = resolveItemPath(rootFilePath, tocManifestItem.path);
    final tocFileEntry = findArchiveFile(archive, tocFileEntryPath);
    if (tocFileEntry == null) continue;

    try {
      final document = parseEpubXml(tocFileEntry.content as List<int>);
      final navigation = _navigationFromDocument(document);
      if (navigation != null) return navigation;
    } on Exception {
      // A stale or malformed navigation resource must not hide another
      // usable EPUB 3 nav document.
    }
  }

  // Navigation is optional for reading the spine. Keep an empty, stable
  // value instead of turning a readable EPUB into a parse failure.
  return Navigation(title: '', navPoints: <NavPoint>[]);
}

Navigation? _navigationFromDocument(final XmlDocument document) {
  if (document.rootElement.name.local == 'ncx') return _navigationFromNcx(document);
  if (document.findAllElements('nav').isEmpty) return null;

  return _navigationFromNavDoc(document);
}

Navigation? _navigationFromNcx(final XmlDocument document) {
  final title =
      document
          .findAllElements('docTitle')
          .firstOrNull
          ?.findElements('text')
          .firstOrNull
          // `innerText`, not `value`: XmlElement.value is always null
          // in package:xml.
          ?.innerText
          .trim() ??
      '';
  final navMap = document.findAllElements('navMap').firstOrNull;
  if (navMap == null) return null;
  final rootPoints = navMap.findElements('navPoint').map(_navPointFromNcx).toList();

  return Navigation(title: title, navPoints: rootPoints);
}

NavPoint _navPointFromNcx(final XmlElement element) {
  final label =
      element
          .findElements('navLabel')
          .firstOrNull
          ?.findElements('text')
          .firstOrNull
          ?.innerText
          .trim() ??
      '';
  final content = element.findElements('content').firstOrNull?.getAttribute('src') ?? '';

  return NavPoint(
    classAttribute: element.getAttribute('class') ?? '',
    id: element.getAttribute('id') ?? '',
    playOrder: element.getAttribute('playOrder') ?? '',
    label: label,
    content: content,
    subNavPoints: element.findElements('navPoint').map(_navPointFromNcx).toList(),
  );
}

Navigation? _navigationFromNavDoc(final XmlDocument document) {
  var title = '';
  for (final element in document.findAllElements('title')) {
    title = element.innerText.trim();
    break;
  }

  // Prefer the nav element typed as `toc`; fall back to the first nav.
  XmlElement? navElement;
  for (final candidate in document.findAllElements('nav')) {
    final type = candidate.getAttribute('epub:type') ?? candidate.getAttribute('type');
    if (type == 'toc') {
      navElement = candidate;
      break;
    }

    navElement ??= candidate;
  }
  if (navElement == null) return null;

  final list = navElement.findElements('ol').firstOrNull;
  final navPoints = list == null ? <NavPoint>[] : _navPointsFromNavList(list, 0);

  return Navigation(title: title, navPoints: navPoints);
}

List<NavPoint> _navPointsFromNavList(final XmlElement list, final int order) {
  final points = <NavPoint>[];
  var playOrder = order;
  for (final listItem in list.findElements('li')) {
    final anchor = listItem.findElements('a').firstOrNull;
    final nestedList = listItem.findElements('ol').firstOrNull;
    if (anchor == null && nestedList == null) continue;

    playOrder++;
    points.add(
      NavPoint(
        classAttribute: 'toc-${anchor?.getAttribute('class') ?? ''}'.trim(),
        id: anchor?.getAttribute('id') ?? '',
        playOrder: '$playOrder',
        label: anchor?.innerText.trim() ?? '',
        content: anchor?.getAttribute('href') ?? '',
        subNavPoints: nestedList == null
            ? <NavPoint>[]
            : _navPointsFromNavList(nestedList, playOrder),
      ),
    );
  }

  return points;
}

String? _navDocumentId(final EpubPackage package) {
  return package is Epub3Package ? package.tocId : null;
}

String _mediaType(final String value) => value.split(';').first.trim().toLowerCase();
