import '../../../foundation/entities/entities.dart';
import '../entities/pdf_page.dart';
import '../header/pdf_document.dart';
import '../header/pdf_object.dart';

/// Reads the PDF bookmark outline into [Navigation].
///
/// Each bookmark carries `/Dest` (an explicit destination array) or a `/A` GoTo action. Both
/// resolve to a page whose 1-based index becomes the `page_N` anchor emitted by the reflowed HTML
/// (`href="index.html#page_N"`). Bookmarks without a resolvable page are dropped; named
/// destinations (string `/Dest`) resolve through the catalog `/Names` tree when present.
class PdfOutlineReader {
  const PdfOutlineReader._();

  /// Reads [document]'s outline; an empty navigation when the
  /// document carries none.
  static Navigation read(final PdfDocument document, final List<PdfPage> pages) {
    final catalog = document.catalog;
    if (catalog == null) return Navigation(title: '', navPoints: const <NavPoint>[]);

    final outlines = document.resolve(catalog['Outlines']);
    if (outlines is! PdfDictionary) return Navigation(title: '', navPoints: const <NavPoint>[]);

    final pageIndexByObject = <int, int>{
      for (var i = 0; i < pages.length; i++) pages[i].objectNumber: i,
    };
    final navPoints = <NavPoint>[];
    final counter = _OrderCounter();
    var node = document.resolve(outlines['First']);
    var guard = 0;
    while (node is PdfDictionary && guard++ < 2000) {
      final point = _navPoint(document, node, pageIndexByObject, counter);
      if (point != null) navPoints.add(point);
      node = document.resolve(node['Next']);
    }

    return Navigation(title: '', navPoints: navPoints);
  }

  static NavPoint? _navPoint(
    final PdfDocument document,
    final PdfDictionary node,
    final Map<int, int> pageIndexByObject,
    final _OrderCounter counter,
  ) {
    final label = _titleOf(document, node);
    final pageIndex = _destinationPage(document, node, pageIndexByObject);
    if (label == null || pageIndex == null) return null;

    final children = <NavPoint>[];
    var child = document.resolve(node['First']);
    var guard = 0;
    while (child is PdfDictionary && guard++ < 2000) {
      final point = _navPoint(document, child, pageIndexByObject, counter);
      if (point != null) children.add(point);
      child = document.resolve(child['Next']);
    }

    return NavPoint(
      classAttribute: 'pdf-outline',
      id: 'pdf-outline-${counter.next}',
      playOrder: '${counter.current}',
      label: label,
      // The reflowed page HTML anchors its first block with
      // id="page_N" (1-based), matching the `page_N` anchors emitted by the reflowed HTML;
      // the section path plus that fragment is what navTargetOf
      // resolves.
      content: 'page_${pageIndex + 1}.html#page_${pageIndex + 1}',
      subNavPoints: children,
    );
  }

  static String? _titleOf(final PdfDocument document, final PdfDictionary node) {
    final title = document.resolve(node['Title']);
    if (title is! PdfString || title.bytes.isEmpty) return null;

    return _decode(title);
  }

  static int? _destinationPage(
    final PdfDocument document,
    final PdfDictionary node,
    final Map<int, int> pageIndexByObject,
  ) {
    var destination = document.resolve(node['Dest']);
    if (destination == null || destination is PdfNull) {
      final action = document.resolve(node['A']);
      if (action is PdfDictionary) {
        final kind = document.resolve(action['S']);
        if (kind is PdfName && kind.value == 'GoTo') {
          destination = document.resolve(action['D']);
        }
      }
    }
    if (destination is PdfString) {
      destination = _namedDestination(document, _decode(destination));
    }
    if (destination is PdfArray && destination.items.isNotEmpty) {
      final page = destination.items.first;
      if (page is PdfIndirectRef) return pageIndexByObject[page.objectNumber];
    }

    return null;
  }

  /// Resolves a named destination through the catalog's `/Dests`
  /// dictionary (PDF 1.1) or `/Names /Dests` name tree.
  static PdfObject? _namedDestination(final PdfDocument document, final String name) {
    final catalog = document.catalog;
    if (catalog == null) return null;

    final dests = document.resolve(catalog['Dests']);
    if (dests is PdfDictionary) return document.resolve(dests[name]);

    final names = document.resolve(catalog['Names']);
    if (names is PdfDictionary) {
      final destsTree = document.resolve(names['Dests']);
      if (destsTree is PdfDictionary) return _findInNameTree(document, destsTree, name);
    }

    return null;
  }

  static PdfObject? _findInNameTree(
    final PdfDocument document,
    final PdfDictionary node,
    final String name, {
    int depth = 0,
  }) {
    if (depth > 32) return null;

    final kids = document.resolve(node['Kids']);
    if (kids is PdfArray) {
      for (final kid in kids.items) {
        final kidDict = document.resolve(kid);
        if (kidDict is! PdfDictionary) continue;

        final limits = document.resolve(kidDict['Limits']);
        if (limits is PdfArray && limits.items.length == 2) {
          final lower = _nameOf(limits.items[0]);
          final upper = _nameOf(limits.items[1]);
          if (lower != null &&
              upper != null &&
              (name.compareTo(lower) < 0 || name.compareTo(upper) > 0)) {
            continue;
          }
        }

        final found = _findInNameTree(document, kidDict, name, depth: depth + 1);
        if (found != null) return found;
      }

      return null;
    }

    final namesArray = document.resolve(node['Names']);
    if (namesArray is! PdfArray) return null;

    for (var i = 0; i + 1 < namesArray.items.length; i += 2) {
      if (_nameOf(namesArray.items[i]) == name) return document.resolve(namesArray.items[i + 1]);
    }

    return null;
  }

  static String? _nameOf(final PdfObject? object) {
    if (object is PdfString && object.bytes.isNotEmpty) return _decode(object);
    if (object is PdfName) return object.value;

    return null;
  }

  static String _decode(final PdfString string) {
    final bytes = string.bytes;
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return String.fromCharCodes([
        for (var i = 2; i + 1 < bytes.length; i += 2) bytes[i] * 256 + bytes[i + 1],
      ]);
    }

    return String.fromCharCodes(bytes);
  }
}

/// Play-order counter shared across the whole outline walk.
final class _OrderCounter {
  int _value = 0;

  int get next => ++_value;

  int get current => _value;
}
