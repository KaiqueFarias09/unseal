/// OPDS catalog parsing: Atom 1.x feeds and OPDS 2.0 JSON catalogs.
///
/// Unseal interprets catalog documents only. Fetching, authentication,
/// purchases, loans, and DRM belong to the host application.
library;

export 'src/features/opds/opds2_exception.dart';
export 'src/features/opds/opds2_limits.dart';
export 'src/features/opds/opds2_model.dart';
export 'src/features/opds/opds2_parser.dart';
export 'src/features/opds/opds2_uri.dart';
export 'src/features/opds/opds_feed.dart';
