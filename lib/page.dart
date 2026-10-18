/// PAGE XML OCR document import: parsing, reading order, and binding
/// onto canonical text snapshots.
///
/// PAGE is a sidecar format for OCR results over scanned pages,
/// published by PRImA. Unseal parses the supported subset — the
/// 2019-07-15 namespace: metadata, page identity and dimensions, all
/// fifteen region kinds, text lines and words, native polygons and
/// baselines, the reading order, and TextEquiv alternatives with
/// confidence and language — into a `PageXmlDocument`, and
/// `bindPageToSnapshot` maps its text onto the UTF-16 ranges of a
/// host-provided canonical text snapshot, preserving OCR origin and
/// confidence. Native polygons stay on the document; bounding boxes
/// are the explicitly derived projection. Unseal does not run OCR.
library;

export 'src/features/page/bind_page_snapshot.dart';
export 'src/features/page/page_document.dart';
export 'src/features/page/page_exception.dart';
export 'src/features/page/parse_page_document.dart';
export 'src/foundation/spatial/spatial_rect.dart';
export 'src/foundation/spatial/spatial_text_page.dart';
export 'src/foundation/spatial/spatial_text_zone.dart';
export 'src/foundation/spatial/spatial_unit.dart';
export 'src/foundation/spatial/spatial_zone_lookup.dart';
