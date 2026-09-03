import 'dart:convert' as convert;

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';

import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/features/epub/utils/archive_utils.dart';

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
  final tocId = package.spine.tocId ?? _navDocumentId(package);
  if (tocId == null) throw EpubException('EPUB parsing error: TOC ID is empty.');

  final tocManifestItem = package.manifest.items.firstWhere(
    (final element) => element.id == tocId,
    orElse: () =>
        throw EpubException('EPUB parsing error: TOC item $tocId not found in EPUB manifest.'),
  );
  final tocFileEntryPath = resolveItemPath(rootFilePath, tocManifestItem.path);
  final tocFileEntry = findArchiveFile(archive, tocFileEntryPath);
  if (tocFileEntry == null) {
    throw EpubException('EPUB parsing error: TOC file $tocFileEntryPath not found in archive.');
  }

  final document = XmlDocument.parse(convert.utf8.decode(tocFileEntry.content as List<int>));
  final isNcx = document.rootElement.name.local == 'ncx';

  return isNcx ? _navigationFromNcx(document) : _navigationFromNavDoc(document);
}

Navigation _navigationFromNcx(final XmlDocument document) {
  final title =
      document
          .findAllElements('docTitle')
          .firstOrNull
          ?.findElements('text')
          .firstOrNull
          ?.value
          ?.trim() ??
      '';
  final navMap = document.findAllElements('navMap').firstOrNull;
  final rootPoints = navMap == null
      ? <NavPoint>[]
      : navMap.findElements('navPoint').map(_navPointFromNcx).toList();

  return Navigation(title: title, navPoints: rootPoints);
}

NavPoint _navPointFromNcx(final XmlElement element) {
  final label =
      element
          .findElements('navLabel')
          .firstOrNull
          ?.findElements('text')
          .firstOrNull
          ?.value
          ?.trim() ??
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

Navigation _navigationFromNavDoc(final XmlDocument document) {
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
  if (navElement == null) return Navigation(title: title, navPoints: <NavPoint>[]);

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
