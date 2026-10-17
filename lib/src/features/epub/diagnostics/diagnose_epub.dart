import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';
import '../codec/epub_xml.dart';
import '../exceptions/exceptions.dart';
import '../package/parse_epub_package.dart';
import 'epub_diagnostic.dart';

const _containerFilepath = 'META-INF/container.xml';
const _packageMediaType = 'application/oebps-package+xml';
const _epubTypeNamespace = 'http://www.idpf.org/2007/ops';
const _xmlNamespace = 'http://www.w3.org/XML/1998/namespace';

/// Diagnoses EPUB [bytes] and returns a structural report.
///
/// Container-level safety limits and malformed package documents keep the
/// typed failures of the reading path (`InvalidBookException`,
/// `EpubException`); every recoverable structural condition inside the
/// documented subset becomes a finding instead of changing reading
/// behavior. The report never repairs the book and never fetches external
/// resources.
EpubDiagnosticsReport diagnoseEpub(
  final Uint8List bytes, {
  final EpubDiagnosticsOptions options = const EpubDiagnosticsOptions(),
}) => diagnoseEpubArchive(decodeBookZip(bytes), options: options);

/// Diagnoses an already decoded EPUB [archive].
EpubDiagnosticsReport diagnoseEpubArchive(
  final Archive archive, {
  final EpubDiagnosticsOptions options = const EpubDiagnosticsOptions(),
}) {
  final collector = _Collector(options);
  final entries = _EntryIndex(archive);
  _diagnoseMimetype(archive, collector);
  final context = _selectPackage(archive, entries, collector);

  if (context != null) {
    _diagnosePackage(context, collector, entries);
  }

  return EpubDiagnosticsReport(
    findings: List.unmodifiable(collector.findings),
    rootFilePath: context?.rootFilePath,
    packageVersion: context?.declaredVersion,
    truncated: collector.truncated,
  );
}

/// The OCF requires `mimetype` as the first entry with the media type
/// string; reading tolerates deviations, diagnosis reports them.
void _diagnoseMimetype(final Archive archive, final _Collector collector) {
  const mediaType = 'application/epub+zip';
  final first = archive.files.isEmpty ? null : archive.files.first;
  final valid =
      first != null &&
      first.name == 'mimetype' &&
      String.fromCharCodes(contentBytes(first)) == mediaType;
  if (valid) return;

  collector.add(
    EpubDiagnostic(
      ruleId: 'epub.container.mimetype-invalid',
      severity: EpubDiagnosticSeverity.error,
      resource: 'mimetype',
      reason: first == null
          ? 'The container is empty.'
          : first.name != 'mimetype'
          ? 'The first archive entry is "${first.name}" instead of the '
                'mimetype media-type entry.'
          : 'The mimetype entry does not carry the "$mediaType" media '
                'type string.',
    ),
  );
}

/// Package selection mirrors the reading path: `container.xml` rootfiles
/// first, then a `.opf` recovery scan. Each failure mode on the way becomes
/// a finding instead of a silent recovery.
_PackageContext? _selectPackage(
  final Archive archive,
  final _EntryIndex entries,
  final _Collector collector,
) {
  final containerEntry = entries.at(_containerFilepath);
  _Selection? selection;

  if (containerEntry == null) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.container.missing',
        severity: EpubDiagnosticSeverity.error,
        resource: _containerFilepath,
        reason: 'The META-INF/container.xml entry is absent from the container.',
      ),
    );
  } else {
    selection = _selectFromContainer(containerEntry, entries, collector);
  }

  var selected = selection?.path;
  var malformedCandidate = selection?.malformedCandidate ?? false;

  if (selected == null) {
    final recovered = _recoverPackagePath(entries);
    selected = recovered.path;
    malformedCandidate = malformedCandidate || recovered.malformedCandidate;
  }

  if (selected != null) return _contextFor(selected, entries, collector);
  if (malformedCandidate) {
    // Structural corruption of the package document keeps the typed
    // failure of the reading path instead of producing findings.
    throw EpubException('EPUB diagnostics error: no usable EPUB package document was found.');
  }

  return null;
}

_Selection _selectFromContainer(
  final ArchiveFile containerEntry,
  final _EntryIndex entries,
  final _Collector collector,
) {
  final XmlDocument document;
  try {
    document = parseEpubXml(contentBytes(containerEntry));
  } on Exception {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.container.rootfile.missing',
        severity: EpubDiagnosticSeverity.error,
        resource: _containerFilepath,
        reason: 'The container document is not a usable XML document.',
      ),
    );
    return const _Selection();
  }

  final container = document.findAllElements('container', namespaceUri: '*').firstOrNull;
  final rootFileElements =
      (container?.descendants.whereType<XmlElement>() ?? const Iterable<XmlElement>.empty())
          .where((final element) => element.name.local == 'rootfile')
          .toList();

  if (rootFileElements.isEmpty) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.container.rootfile.missing',
        severity: EpubDiagnosticSeverity.error,
        resource: _containerFilepath,
        reason: 'The container document declares no rootfile element.',
      ),
    );
    return const _Selection();
  }

  String? unusableMediaType;
  String? unresolvedPath;
  final candidates = <String>[];
  for (final rootFile in rootFileElements) {
    final fullPath = rootFile.getAttribute('full-path')?.trim();
    if (fullPath == null || fullPath.isEmpty) continue;

    final mediaType = rootFile.getAttribute('media-type')?.trim().toLowerCase();
    final normalized = normalizeZipPath(fullPath);
    final isPackageMedia = mediaType == null || mediaType == _packageMediaType;
    if (entries.at(normalized) == null) {
      unresolvedPath ??= normalized;
      continue;
    }
    if (!isPackageMedia) {
      unusableMediaType ??= mediaType;
      continue;
    }
    candidates.add(normalized);
  }

  final selection = _selectUsablePackage(candidates, entries);
  if (selection.path != null) return selection;

  if (unresolvedPath != null) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.container.rootfile.path-unresolved',
        severity: EpubDiagnosticSeverity.error,
        resource: unresolvedPath,
        reason:
            'The container rootfile "$unresolvedPath" is not present in the '
            'container.',
      ),
    );
  } else if (unusableMediaType != null) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.container.rootfile.media-type-unsupported',
        severity: EpubDiagnosticSeverity.error,
        resource: _containerFilepath,
        reason:
            'Every container rootfile declares the media-type '
            '"$unusableMediaType" instead of "$_packageMediaType".',
      ),
    );
  } else {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.container.rootfile.missing',
        severity: EpubDiagnosticSeverity.error,
        resource: _containerFilepath,
        reason: 'No container rootfile names a usable package document.',
      ),
    );
  }

  return _Selection(malformedCandidate: selection.malformedCandidate);
}

/// Picks the package document the way reading does: the first candidate
/// the strict OPF parser accepts, then the first candidate that is at
/// least a well-formed `package` XML document so a semantically broken
/// package can still be diagnosed.
_Selection _selectUsablePackage(final List<String> candidates, final _EntryIndex entries) {
  var malformed = false;
  for (final path in candidates) {
    try {
      parsePackageBytes(contentBytes(entries.at(path)!));

      return _Selection(path: path);
    } on Exception {
      // Mirrors reading: keep looking when one candidate is unusable.
      if (!_isWellFormedPackage(entries, path)) malformed = true;
    }
  }

  for (final path in candidates) {
    if (_isWellFormedPackage(entries, path)) {
      return _Selection(path: path);
    }
  }

  return _Selection(malformedCandidate: malformed);
}

bool _isWellFormedPackage(final _EntryIndex entries, final String path) {
  final entry = entries.at(path);
  if (entry == null) return false;

  try {
    return parseEpubXml(contentBytes(entry)).rootElement.name.local == 'package';
  } on Exception {
    return false;
  }
}

/// Recovery scan used by reading when the container yields no package.
_Selection _recoverPackagePath(final _EntryIndex entries) {
  final opfPaths = entries.paths
      .where((final path) => path.toLowerCase().endsWith('.opf'))
      .toList();

  return _selectUsablePackage(opfPaths, entries);
}

/// Outcome of package selection: the selected path, when any, and whether a
/// package document existed but was not even well-formed XML.
final class _Selection {
  const _Selection({this.path, this.malformedCandidate = false});

  final String? path;
  final bool malformedCandidate;
}

_PackageContext? _contextFor(
  final String path,
  final _EntryIndex entries,
  final _Collector collector,
) {
  final entry = entries.at(path);
  if (entry == null) return null;

  final XmlDocument document;
  try {
    document = parseEpubXml(contentBytes(entry));
  } on Exception {
    // A malformed package document keeps the typed failure of the reading
    // path; it cannot produce honest structural findings.
    throw EpubException(
      'EPUB diagnostics error: the package document $path is not well-formed '
      'XML.',
    );
  }

  final root = document.rootElement;
  if (root.name.local != 'package') return null;

  return _PackageContext(
    rootFilePath: path,
    root: root,
    namespaceUri: root.namespaceUri?.toString(),
    declaredVersion: root.getAttribute('version')?.trim(),
  );
}

void _diagnosePackage(
  final _PackageContext context,
  final _Collector collector,
  final _EntryIndex entries,
) {
  final major = context.declaredVersion == null
      ? null
      : int.tryParse(context.declaredVersion!.split('.').first);
  final isEpub2 = major == null || major < 3;

  if (context.declaredVersion == null ||
      context.declaredVersion!.isEmpty ||
      major == null ||
      major < 2 ||
      major >= 4) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.package.version-unsupported',
        severity: EpubDiagnosticSeverity.error,
        resource: context.rootFilePath,
        reason:
            'The package declares the EPUB version '
            '"${context.declaredVersion ?? ''}", which is not supported.',
      ),
    );
  }

  final manifestElement = context.root
      .findElements('manifest', namespaceUri: context.namespaceUri)
      .firstOrNull;
  final spineElement = context.root
      .findElements('spine', namespaceUri: context.namespaceUri)
      .firstOrNull;
  if (manifestElement == null || spineElement == null) return;

  final manifest = _collectManifest(context, manifestElement, collector, entries, isEpub2);
  final spine = _collectSpine(context, spineElement, manifest, collector);
  _diagnoseNavigation(context, manifest, spine, collector, entries, isEpub2);
  _diagnoseGuide(context, manifest, collector, entries, isEpub2);
}

_Manifest _collectManifest(
  final _PackageContext context,
  final XmlElement manifestElement,
  final _Collector collector,
  final _EntryIndex entries,
  final bool isEpub2,
) {
  final items = <_ManifestItem>[];
  final idPositions = <String, int>{};
  final declaredPaths = <String, int>{};
  var index = 0;
  for (final element in manifestElement.findElements('item', namespaceUri: context.namespaceUri)) {
    if (index >= collector.options.maxManifestItems) {
      collector.truncated = true;
      break;
    }
    index++;

    final id = element.getAttribute('id')?.trim();
    final href = element.getAttribute('href')?.trim();
    final mediaType = element.getAttribute('media-type')?.trim();
    if (id == null ||
        id.isEmpty ||
        href == null ||
        href.isEmpty ||
        mediaType == null ||
        mediaType.isEmpty) {
      collector.add(
        EpubDiagnostic(
          ruleId: 'epub.manifest.item.incomplete',
          severity: EpubDiagnosticSeverity.error,
          resource: context.rootFilePath,
          location: 'manifest item[$index]',
          reason:
              'The manifest item is missing a required id, href, or '
              'media-type attribute.',
        ),
      );
    }

    final properties = (element.getAttribute('properties') ?? '')
        .split(RegExp(r'\s+'))
        .where((final property) => property.isNotEmpty)
        .toSet();

    if (id != null && id.isNotEmpty) {
      final previous = idPositions[id];
      if (previous != null) {
        collector.add(
          EpubDiagnostic(
            ruleId: 'epub.manifest.id-duplicate',
            severity: EpubDiagnosticSeverity.error,
            resource: context.rootFilePath,
            location: 'manifest item "$id"',
            reason:
                'The manifest id "$id" is declared by more than one item '
                '(first at position $previous).',
          ),
        );
      } else {
        idPositions[id] = index;
      }
    }

    if (href == null || href.isEmpty) continue;

    if (_isExternalUrl(href)) {
      final declared = properties.contains('remote-resources') && !isEpub2;
      if (!declared) {
        collector.add(
          EpubDiagnostic(
            ruleId: 'epub.manifest.remote-resource-undeclared',
            severity: EpubDiagnosticSeverity.error,
            location: 'manifest item "${id ?? ''}"'.trim(),
            reason:
                'The manifest href "$href" is an external URL without the '
                'remote-resources declaration.',
          ),
        );
      }
      items.add(
        _ManifestItem(id: id, mediaType: mediaType, properties: properties, resolvedPath: null),
      );
      continue;
    }

    if (href.contains('#')) {
      collector.add(
        EpubDiagnostic(
          ruleId: 'epub.manifest.href-fragment',
          severity: EpubDiagnosticSeverity.error,
          location: 'manifest item "${id ?? ''}"'.trim(),
          reason:
              'The manifest href "$href" carries a fragment identifier, '
              'which manifest hrefs must not use.',
        ),
      );
    }

    final resolved = _resolveAgainst(context.rootFilePath, href);
    if (resolved != null) {
      final previous = declaredPaths[resolved];
      if (previous != null) {
        collector.add(
          EpubDiagnostic(
            ruleId: 'epub.manifest.href-duplicate',
            severity: EpubDiagnosticSeverity.error,
            resource: resolved,
            location: 'manifest item "${id ?? ''}"'.trim(),
            reason:
                'The resource "$resolved" is declared by more than one '
                'manifest item (first at position $previous).',
          ),
        );
      } else {
        declaredPaths[resolved] = index;
      }

      if (entries.at(resolved) == null) {
        collector.add(
          EpubDiagnostic(
            ruleId: 'epub.manifest.resource-missing',
            severity: EpubDiagnosticSeverity.error,
            resource: resolved,
            location: 'manifest item "${id ?? ''}"'.trim(),
            reason:
                'The manifest resource "$resolved" could not be found in '
                'the container.',
          ),
        );
      }
    }

    items.add(
      _ManifestItem(id: id, mediaType: mediaType, properties: properties, resolvedPath: resolved),
    );
  }

  return _Manifest(items: items, ids: idPositions, declaredPaths: declaredPaths);
}

_Spine _collectSpine(
  final _PackageContext context,
  final XmlElement spineElement,
  final _Manifest manifest,
  final _Collector collector,
) {
  final idrefs = <String?>[];
  final seenPositions = <String, int>{};
  var index = 0;
  for (final element in spineElement.findElements('itemref', namespaceUri: context.namespaceUri)) {
    index++;
    final idref = element.getAttribute('idref')?.trim();
    idrefs.add(idref);
    if (idref == null || idref.isEmpty) continue;

    if (!manifest.ids.containsKey(idref)) {
      collector.add(
        EpubDiagnostic(
          ruleId: 'epub.spine.reference-invalid',
          severity: EpubDiagnosticSeverity.error,
          resource: context.rootFilePath,
          location: 'spine[$index]',
          reason:
              'The spine idref "$idref" does not resolve to any manifest '
              'item.',
        ),
      );
      continue;
    }

    final previous = seenPositions[idref];
    if (previous != null) {
      collector.add(
        EpubDiagnostic(
          ruleId: 'epub.spine.reference-duplicate',
          severity: EpubDiagnosticSeverity.error,
          resource: context.rootFilePath,
          location: 'spine[$index]',
          reason:
              'The spine references the same manifest item as a previous '
              'itemref (idref "$idref", first at position $previous).',
        ),
      );
    } else {
      seenPositions[idref] = index;
    }
  }

  if (idrefs.isEmpty) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.spine.empty',
        severity: EpubDiagnosticSeverity.error,
        reason: 'The spine contains no itemref element.',
      ),
    );
  }

  return _Spine(idrefs: idrefs, tocAttribute: spineElement.getAttribute('toc')?.trim());
}

void _diagnoseNavigation(
  final _PackageContext context,
  final _Manifest manifest,
  final _Spine spine,
  final _Collector collector,
  final _EntryIndex entries,
  final bool isEpub2,
) {
  if (isEpub2) {
    _diagnoseEpub2Navigation(context, manifest, spine, collector, entries);
    return;
  }

  final navItems = manifest.items
      .where(
        (final item) => item.properties.any((final property) => property.toLowerCase() == 'nav'),
      )
      .toList();

  if (navItems.isEmpty) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.navigation.nav-missing',
        severity: EpubDiagnosticSeverity.error,
        reason:
            'The EPUB 3 package declares no manifest item with the nav '
            'property.',
      ),
    );
    return;
  }
  if (navItems.length > 1) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.navigation.nav-duplicate',
        severity: EpubDiagnosticSeverity.error,
        resource: context.rootFilePath,
        reason:
            'More than one manifest item declares the nav property '
            '(${navItems.length} items).',
      ),
    );
  }

  var sawTocNav = false;
  for (final item in navItems) {
    final document = _parseResource(entries, item.resolvedPath);
    if (document == null) continue;

    if (_hasTocNav(document)) sawTocNav = true;
    _diagnoseDocumentLinks(document, item.resolvedPath, 'nav link', collector, entries);
  }
  if (!sawTocNav) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.navigation.toc-missing',
        severity: EpubDiagnosticSeverity.error,
        reason:
            'No navigation document contains a nav element typed as the '
            'table of contents.',
      ),
    );
  }
}

void _diagnoseEpub2Navigation(
  final _PackageContext context,
  final _Manifest manifest,
  final _Spine spine,
  final _Collector collector,
  final _EntryIndex entries,
) {
  final tocAttribute = spine.tocAttribute;
  if (tocAttribute == null || tocAttribute.isEmpty) {
    collector.add(
      const EpubDiagnostic(
        ruleId: 'epub.navigation.toc-reference-missing',
        severity: EpubDiagnosticSeverity.error,
        reason:
            'The EPUB 2 spine is missing the required toc attribute '
            'selecting the NCX.',
      ),
    );
    return;
  }

  final ncxItem = manifest.items.firstWhereOrNull((final item) => item.id == tocAttribute);
  if (ncxItem == null) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.navigation.toc-missing',
        severity: EpubDiagnosticSeverity.error,
        resource: context.rootFilePath,
        location: 'spine@toc',
        reason:
            'The spine toc attribute "$tocAttribute" does not resolve to '
            'any manifest item.',
      ),
    );
    return;
  }

  final ncxDocument = _parseResource(entries, ncxItem.resolvedPath);
  if (ncxDocument == null) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.navigation.toc-missing',
        severity: EpubDiagnosticSeverity.error,
        resource: ncxItem.resolvedPath,
        reason:
            'The NCX table of contents "${ncxItem.resolvedPath}" could not '
            'be found in the container.',
      ),
    );
    return;
  }

  _diagnoseDocumentLinks(ncxDocument, ncxItem.resolvedPath, 'NCX content', collector, entries);
}

bool _hasTocNav(final XmlDocument document) {
  for (final nav in document.findAllElements('nav')) {
    final value =
        nav.getAttribute('type', namespaceUri: _epubTypeNamespace) ??
        nav.getAttribute('epub:type') ??
        nav.getAttribute('type') ??
        '';
    if (value.trim().split(RegExp(r'\s+')).contains('toc')) return true;
  }

  return false;
}

void _diagnoseDocumentLinks(
  final XmlDocument document,
  final String? documentPath,
  final String kind,
  final _Collector collector,
  final _EntryIndex entries,
) {
  for (final element in document.descendants.whereType<XmlElement>()) {
    final href = element.getAttribute('href') ?? element.getAttribute('src');
    if (element.name.local != 'a' && element.name.local != 'content') continue;
    if (href == null) continue;

    final trimmed = href.trim();
    if (trimmed.isEmpty || _isExternalUrl(trimmed)) continue;

    _diagnoseLink(
      href: trimmed,
      basePath: documentPath,
      location: '$kind "$trimmed"',
      collector: collector,
      entries: entries,
    );
  }
}

void _diagnoseLink({
  required final String href,
  required final String? basePath,
  required final String location,
  required final _Collector collector,
  required final _EntryIndex entries,
}) {
  if (!collector.spendLink()) return;

  final fragmentIndex = href.indexOf('#');
  final fragment = fragmentIndex < 0 ? null : href.substring(fragmentIndex + 1);
  final target = fragmentIndex == 0
      ? basePath
      : _resolveAgainst(
          basePath,
          href.substring(0, fragmentIndex < 0 ? href.length : fragmentIndex),
        );

  if (target == null || entries.at(target) == null) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.navigation.link-unresolved',
        severity: EpubDiagnosticSeverity.error,
        resource: target,
        location: location,
        reason:
            'The navigation target "$href" could not be resolved to a '
            'container resource.',
      ),
    );
    return;
  }

  if (fragment == null || fragment.isEmpty) return;
  final ids = _resourceIds(entries, target, collector.options.maxFragmentResourceBytes);
  if (ids == null) {
    collector.truncated = true;
    return;
  }
  if (!ids.contains(fragment)) {
    collector.add(
      EpubDiagnostic(
        ruleId: 'epub.navigation.fragment-unresolved',
        severity: EpubDiagnosticSeverity.error,
        resource: target,
        location: location,
        reason: 'The fragment "$fragment" is not defined in "$target".',
      ),
    );
  }
}

void _diagnoseGuide(
  final _PackageContext context,
  final _Manifest manifest,
  final _Collector collector,
  final _EntryIndex entries,
  final bool isEpub2,
) {
  if (!isEpub2) return;

  final guide = context.root.findElements('guide', namespaceUri: context.namespaceUri).firstOrNull;
  if (guide == null) return;

  var index = 0;
  for (final reference in guide.findElements('reference', namespaceUri: context.namespaceUri)) {
    index++;
    final href = reference.getAttribute('href')?.trim();
    if (href == null || href.isEmpty || _isExternalUrl(href)) continue;

    if (!collector.spendLink()) return;

    final resolved = _resolveAgainst(context.rootFilePath, href);
    final declared = resolved != null && manifest.declaredPaths.containsKey(resolved);
    if (resolved == null || entries.at(resolved) == null || !declared) {
      collector.add(
        EpubDiagnostic(
          ruleId: 'epub.guide.reference-unresolved',
          severity: EpubDiagnosticSeverity.error,
          resource: resolved,
          location: 'guide reference[$index] "$href"',
          reason:
              'The guide reference "$href" is absent from the container or '
              'not declared in the manifest.',
        ),
      );
    }
  }
}

/// Archive-relative, percent-decoded resolution of an href against the
/// directory of [rootFilePath], matching the href policy used by the
/// encryption and navigation readers.
String? _resolveAgainst(final String? rootFilePath, final String href) {
  final withoutFragment = href.split('#').first;
  if (withoutFragment.isEmpty) return null;

  final decoded = _decodePercentEscapes(withoutFragment);
  final index = rootFilePath?.lastIndexOf('/') ?? -1;
  final directory = index < 0 || rootFilePath == null ? null : rootFilePath.substring(0, index);
  final joined = directory == null ? decoded : '$directory/$decoded';

  return normalizeZipPath(joined);
}

String _decodePercentEscapes(final String value) {
  if (!value.contains('%')) return value;

  final bytes = <int>[];
  var plainStart = 0;
  var index = 0;
  while (index < value.length) {
    final high = value.codeUnitAt(index) == 0x25 && index + 2 < value.length
        ? _hexValue(value, index + 1)
        : -1;
    final low = high < 0 ? -1 : _hexValue(value, index + 2);
    if (high >= 0 && low >= 0) {
      bytes.addAll(value.codeUnits.sublist(plainStart, index));
      bytes.add(high * 16 + low);
      index += 3;
      plainStart = index;
      continue;
    }
    index++;
  }
  if (bytes.isEmpty) return value;

  bytes.addAll(value.codeUnits.sublist(plainStart));

  return utf8.decode(bytes, allowMalformed: true);
}

int _hexValue(final String value, final int index) {
  final code = value.codeUnitAt(index);
  if (code >= 0x30 && code <= 0x39) return code - 0x30;
  if (code >= 0x61 && code <= 0x66) return code - 0x57;
  if (code >= 0x41 && code <= 0x46) return code - 0x37;

  return -1;
}

bool _isExternalUrl(final String href) {
  if (href.startsWith('//')) return true;
  final scheme = Uri.tryParse(href)?.scheme ?? '';

  return scheme.length > 1;
}

XmlDocument? _parseResource(final _EntryIndex entries, final String? path) {
  final entry = path == null ? null : entries.at(path);
  if (entry == null) return null;

  try {
    return parseEpubXml(contentBytes(entry));
  } on Exception {
    // A malformed navigation resource stays out of the structural subset;
    // absence of a usable toc is reported by the toc rules instead.
    return null;
  }
}

/// `id` and `xml:id` values of a target document, or `null` when the
/// document exceeds [maxBytes] and the fragment check must be skipped.
Set<String>? _resourceIds(final _EntryIndex entries, final String path, final int maxBytes) {
  final entry = entries.at(path);
  if (entry == null) return const <String>{};
  if (entry.size > maxBytes) return null;

  final XmlDocument document;
  try {
    document = parseEpubXml(contentBytes(entry));
  } on Exception {
    return const <String>{};
  }

  final ids = <String>{};
  for (final element in document.descendants.whereType<XmlElement>()) {
    final id = element.getAttribute('id');
    if (id != null) ids.add(id);
    final xmlId = element.getAttribute('id', namespaceUri: _xmlNamespace);
    if (xmlId != null) ids.add(xmlId);
  }

  return ids;
}

final class _Collector {
  _Collector(this.options);

  final EpubDiagnosticsOptions options;
  final findings = <EpubDiagnostic>[];
  bool truncated = false;
  int _links = 0;

  bool get full => findings.length >= options.maxFindings;

  void add(final EpubDiagnostic diagnostic) {
    if (full) {
      truncated = true;
      return;
    }
    findings.add(diagnostic);
  }

  bool spendLink() {
    if (_links >= options.maxNavigationLinks) {
      truncated = true;
      return false;
    }
    _links++;
    return true;
  }
}

/// Container entries indexed once by normalized, lower-cased path; the
/// first entry wins, mirroring [findArchiveFile]. [paths] keeps the
/// original normalized spelling of each first entry.
final class _EntryIndex {
  _EntryIndex(final Archive archive) {
    for (final file in archive.files) {
      if (!file.isFile) continue;

      final normalized = normalizeZipPath(file.name);
      _byPath.putIfAbsent(normalized.toLowerCase(), () => file);
      _display.putIfAbsent(normalized.toLowerCase(), () => normalized);
    }
  }

  final Map<String, ArchiveFile> _byPath = {};
  final Map<String, String> _display = {};
  late final List<String> paths = _display.values.toList(growable: false);

  ArchiveFile? at(final String path) {
    final normalized = normalizeZipPath(path);
    if (normalized.isEmpty) return null;

    return _byPath[normalized.toLowerCase()];
  }
}

final class _PackageContext {
  const _PackageContext({
    required this.rootFilePath,
    required this.root,
    required this.namespaceUri,
    required this.declaredVersion,
  });

  final String rootFilePath;
  final XmlElement root;
  final String? namespaceUri;
  final String? declaredVersion;
}

final class _Manifest {
  const _Manifest({required this.items, required this.ids, required this.declaredPaths});

  final List<_ManifestItem> items;
  final Map<String, int> ids;
  final Map<String, int> declaredPaths;
}

final class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.mediaType,
    required this.properties,
    required this.resolvedPath,
  });

  final String? id;
  final String? mediaType;
  final Set<String> properties;
  final String? resolvedPath;
}

final class _Spine {
  const _Spine({required this.idrefs, required this.tocAttribute});

  final List<String?> idrefs;
  final String? tocAttribute;
}
