/// hOCR OCR document import: parsing, native geometry, and binding onto
/// canonical text snapshots.
///
/// hOCR is HTML with a class vocabulary for OCR results over scanned
/// pages (Tesseract's default rich output). Unseal parses the reading
/// subset — producer metadata, pages, content areas, paragraphs, lines and
/// words in the nesting the producer declared, integer pixel boxes, the
/// native baseline polynomial, text angle, scan resolution and the 0..100
/// word confidence — into an `HocrDocument`, and `bindHocrToSnapshot` maps
/// its text onto the UTF-16 ranges of a host-provided canonical text
/// snapshot, preserving OCR origin, confidence and ambiguity. Baselines and
/// angles stay native with named projections; coordinates are never
/// rotated. Unseal does not run OCR.
library;

export 'src/features/hocr/bind_hocr_snapshot.dart';
export 'src/features/hocr/hocr_document.dart';
export 'src/features/hocr/hocr_exception.dart';
export 'src/features/hocr/hocr_title.dart';
export 'src/features/hocr/parse_hocr_document.dart';
export 'src/foundation/spatial/spatial_rect.dart';
export 'src/foundation/spatial/spatial_text_page.dart';
export 'src/foundation/spatial/spatial_text_zone.dart';
export 'src/foundation/spatial/spatial_unit.dart';
export 'src/foundation/spatial/spatial_zone_lookup.dart';
export 'src/foundation/text/canonical_text_snapshot.dart';
export 'src/foundation/text/publication_revision.dart';
export 'src/foundation/text/section_occurrence.dart';
export 'src/foundation/text/text_profile.dart';
