import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';
import '../../../foundation/entities/navigation/nav_point.dart';
import '../../../foundation/entities/navigation/navigation.dart';
import '../codec/epub_xml.dart';
import '../entities/entities.dart';

/// Retrieves the table of contents of an EPUB.
///
/// EPUB 3 navigation takes precedence over a legacy NCX. EPUB 2 uses its NCX
/// first. See [getEpubNavigationSections] for the EPUB 3 page list and landmarks.
Navigation getEpubNavigation(
  final EpubPackage package,
  final Archive archive,
  final String? rootFilePath,
) => getEpubNavigationSections(package, archive, rootFilePath).toc;

/// Reads the table of contents and optional EPUB 3 navigation sections.
({Navigation toc, Navigation? pageList, List<EpubLandmark> landmarks}) getEpubNavigationSections(
  final EpubPackage package,
  final Archive archive,
  final String? rootFilePath,
) {
  final navIds = package.manifest.items
      .where(
        (final item) => item.properties.any((final property) => property.toLowerCase() == 'nav'),
      )
      .map((final item) => item.id);
  final ncxIds = package.manifest.items
      .where((final item) => _mediaType(item.mediaType) == 'application/x-dtbncx+xml')
      .map((final item) => item.id);
  final candidateIds = <String>[
    if (package is Epub3Package) ...[
      if (package.tocId != null) package.tocId!,
      ...navIds,
      if (package.spine.tocId != null) package.spine.tocId!,
      ...ncxIds,
    ] else ...[
      if (package.spine.tocId != null) package.spine.tocId!,
      ...ncxIds,
      ...navIds,
    ],
  ];
  final triedIds = <String>{};
  Navigation? toc;
  Navigation? pageList;
  var landmarks = <EpubLandmark>[];
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
      if (document.rootElement.name.local == 'ncx') {
        toc ??= _navigationFromNcx(document);
      } else {
        final sections = _navigationFromNavDoc(document);
        toc ??= sections.toc;
        pageList ??= sections.pageList;
        if (landmarks.isEmpty) landmarks = sections.landmarks;
      }
    } on Exception {
      // A stale or malformed navigation resource must not hide another
      // usable EPUB 3 nav document.
    }
  }

  // Navigation is optional for reading the spine. Keep an empty, stable
  // value instead of turning a readable EPUB into a parse failure.
  return (
    toc: toc ?? Navigation(title: '', navPoints: <NavPoint>[]),
    pageList: pageList,
    landmarks: landmarks,
  );
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

({Navigation? toc, Navigation? pageList, List<EpubLandmark> landmarks}) _navigationFromNavDoc(
  final XmlDocument document,
) {
  var title = '';
  for (final element in document.findAllElements('title')) {
    title = element.innerText.trim();
    break;
  }

  Navigation? toc;
  Navigation? pageList;
  var landmarks = <EpubLandmark>[];
  XmlElement? untypedNav;
  for (final candidate in document.findAllElements('nav')) {
    final types = _navTypes(candidate);
    if (types.contains('toc')) toc ??= _navigationFromNavElement(candidate, title);
    if (types.contains('page-list')) pageList ??= _navigationFromNavElement(candidate, title);
    if (types.contains('landmarks') && landmarks.isEmpty) {
      landmarks = _landmarksFromNavElement(candidate);
    }
    if (types.isEmpty) untypedNav ??= candidate;
  }

  // Preserve legacy untyped nav documents, but do not mistake a page list or
  // landmarks section for the table of contents.
  if (toc == null && untypedNav != null) toc = _navigationFromNavElement(untypedNav, title);
  return (toc: toc, pageList: pageList, landmarks: landmarks);
}

List<EpubLandmark> _landmarksFromNavElement(final XmlElement navElement) {
  final list = navElement.findElements('ol').firstOrNull;
  if (list == null) return <EpubLandmark>[];
  return <EpubLandmark>[
    for (final item in list.findElements('li'))
      if (item.findElements('a').firstOrNull case final XmlElement anchor)
        EpubLandmark(
          label: anchor.innerText.trim(),
          href: anchor.getAttribute('href') ?? '',
          types: _navTypes(anchor).toList(),
        ),
  ];
}

Set<String> _navTypes(final XmlElement element) {
  const epubNamespace = 'http://www.idpf.org/2007/ops';
  final value =
      element.getAttribute('type', namespaceUri: epubNamespace) ??
      element.getAttribute('epub:type') ??
      element.getAttribute('type') ??
      '';
  final trimmed = value.trim();
  return trimmed.isEmpty ? <String>{} : trimmed.split(RegExp(r'\s+')).toSet();
}

Navigation _navigationFromNavElement(final XmlElement navElement, final String documentTitle) {
  final list = navElement.findElements('ol').firstOrNull;
  final navPoints = list == null ? <NavPoint>[] : _navPointsFromNavList(list, 0);
  final heading = navElement.children.whereType<XmlElement>().firstWhereOrNull(
    (final element) => RegExp(r'^h[1-6]$').hasMatch(element.name.local),
  );
  return Navigation(title: heading?.innerText.trim() ?? documentTitle, navPoints: navPoints);
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

String _mediaType(final String value) => value.split(';').first.trim().toLowerCase();
