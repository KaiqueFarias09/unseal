import '../entities/pdf_page.dart';
import '../header/pdf_document.dart';
import '../header/pdf_object.dart';

/// Reads the document's page tree into reading order.
///
/// Page-tree nodes inherit `/MediaBox`, `/CropBox`, `/Resources` and
/// `/Rotate` from their ancestors (PDF 32000-1:2008 §7.7.3.4); the
/// walk carries the inherited values down and lets a node's own
/// entries override them. Cycles and runaway depths degrade by
/// cutting the branch, not by failing the document.
class PdfPageTree {
  const PdfPageTree._();

  /// Parses [document]'s pages; empty when the catalog carries no
  /// readable page tree.
  static List<PdfPage> parse(final PdfDocument document) {
    final catalog = document.catalog;
    if (catalog == null) return const <PdfPage>[];

    final rootRef = catalog['Pages'];
    final root = document.resolve(rootRef);
    if (root is! PdfDictionary) return const <PdfPage>[];

    final pages = <PdfPage>[];
    _walk(document, rootRef, root, const _Inherited(), pages, <int>{}, 0);

    return pages;
  }

  static void _walk(
    final PdfDocument document,
    final PdfObject? nodeRef,
    final PdfDictionary node,
    final _Inherited inherited,
    final List<PdfPage> pages,
    final Set<int> visited,
    final int depth,
  ) {
    if (depth > 64 || pages.length > 100000) return;
    final objectNumber = nodeRef is PdfIndirectRef ? nodeRef.objectNumber : 0;
    if (objectNumber != 0 && !visited.add(objectNumber)) return;

    final type = document.resolve(node['Type']);
    final mediaBox = _boxOf(document, node['MediaBox']) ?? inherited.mediaBox;
    final cropBox = _boxOf(document, node['CropBox']) ?? inherited.cropBox;
    final resources = node.containsKey('Resources') ? node['Resources'] : inherited.resources;
    final rotate = _rotateOf(document.resolve(node['Rotate'])) ?? inherited.rotate;

    if (type is PdfName && type.value == 'Page') {
      pages.add(
        PdfPage(
          objectNumber: objectNumber,
          mediaBox: mediaBox ?? const <double>[0, 0, 612, 792],
          cropBox: cropBox,
          rotate: rotate,
          resources: resources,
        ),
      );

      return;
    }

    final kids = document.resolve(node['Kids']);
    if (kids is! PdfArray) return;

    final next = _Inherited(
      mediaBox: mediaBox,
      cropBox: cropBox,
      resources: resources,
      rotate: rotate,
    );
    for (final kid in kids.items) {
      final kidDict = document.resolve(kid);
      if (kidDict is PdfDictionary) {
        _walk(document, kid, kidDict, next, pages, visited, depth + 1);
      }
    }
  }

  static List<double>? _boxOf(final PdfDocument document, final PdfObject? entry) {
    final box = document.resolve(entry);
    if (box is! PdfArray || box.items.length != 4) return null;
    final values = <double>[];
    for (final item in box.items) {
      if (item is! PdfNumber) return null;
      values.add(item.value);
    }

    return values;
  }

  static int? _rotateOf(final PdfObject? rotate) {
    if (rotate is PdfNumber) return rotate.intValue;

    return null;
  }
}

/// Attribute values inherited from a page-tree ancestor.
final class _Inherited {
  const _Inherited({this.mediaBox, this.cropBox, this.resources, this.rotate = 0});

  final List<double>? mediaBox;
  final List<double>? cropBox;
  final PdfObject? resources;
  final int rotate;
}
