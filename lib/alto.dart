/// ALTO OCR document import: parsing, verified scaling, and binding onto
/// canonical text snapshots.
///
/// ALTO is a sidecar format for OCR results over scanned pages. Unseal
/// parses the supported subset (namespaces v2, v3, v4; pixel, `mm10` and
/// `inch1200` units; pages, text and non-text blocks, lines, strings with
/// confidence) into an ALTO document, and `bindAltoToSnapshot` maps its
/// positioned words onto the UTF-16 ranges of a host-provided canonical
/// text snapshot, preserving OCR origin and confidence. Coordinate
/// conversion only happens through a verified scale; physical units
/// without verifiable evidence refuse to convert.
library;

export 'src/features/alto/alto_document.dart';
export 'src/features/alto/alto_exception.dart';
export 'src/features/alto/alto_scale.dart';
export 'src/features/alto/bind_alto_snapshot.dart';
export 'src/features/alto/parse_alto_document.dart';
export 'src/foundation/spatial/spatial_rect.dart';
export 'src/foundation/spatial/spatial_text_page.dart';
export 'src/foundation/spatial/spatial_text_zone.dart';
export 'src/foundation/spatial/spatial_unit.dart';
export 'src/foundation/spatial/spatial_zone_lookup.dart';
