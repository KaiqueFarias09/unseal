/// Resource bounds for OPDS 2.0 parsing.
///
/// Every bound is checked before the corresponding output is allocated.
/// Input bytes are capped before decoding, node count and depth before
/// mapping, and per-collection counts while the model is built. Defaults
/// are chosen for catalog-sized documents; a host that deliberately
/// accepts larger feeds copies with larger values.
final class Opds2Limits {
  /// Creates a limit set. All values must be positive.
  const Opds2Limits({
    this.maxBytes = defaultMaxBytes,
    this.maxDepth = defaultMaxDepth,
    this.maxNodes = defaultMaxNodes,
    this.maxStringLength = defaultMaxStringLength,
    this.maxPublications = defaultMaxPublications,
    this.maxGroups = defaultMaxGroups,
    this.maxFacets = defaultMaxFacets,
    this.maxSubcollections = defaultMaxSubcollections,
    this.maxLinks = defaultMaxLinks,
  }) : assert(maxBytes > 0),
       assert(maxDepth > 0),
       assert(maxNodes > 0),
       assert(maxStringLength > 0),
       assert(maxPublications > 0),
       assert(maxGroups > 0),
       assert(maxFacets > 0),
       assert(maxSubcollections > 0),
       assert(maxLinks > 0);

  /// Default byte cap for one OPDS 2.0 document.
  static const int defaultMaxBytes = 16 << 20;

  /// Default maximum JSON nesting depth.
  static const int defaultMaxDepth = 64;

  /// Default maximum number of JSON values (objects, arrays, and scalars
  /// counted together) in one document.
  static const int defaultMaxNodes = 250000;

  /// Default maximum length of a single JSON string.
  static const int defaultMaxStringLength = 1 << 20;

  /// Default maximum publications in the feed or in one group.
  static const int defaultMaxPublications = 5000;

  /// Default maximum groups per feed.
  static const int defaultMaxGroups = 1000;

  /// Default maximum facets per feed.
  static const int defaultMaxFacets = 1000;

  /// Default maximum subcollection members per feed or subcollection.
  static const int defaultMaxSubcollections = 1000;

  /// Default maximum links in one container (feed, group, facet, or
  /// publication).
  static const int defaultMaxLinks = 10000;

  /// Maximum document size in bytes, checked before decoding.
  final int maxBytes;

  /// Maximum JSON nesting depth, checked before mapping.
  final int maxDepth;

  /// Maximum number of JSON values, checked before mapping.
  final int maxNodes;

  /// Maximum length of a single JSON string.
  final int maxStringLength;

  /// Maximum publications in the feed or inside one group.
  final int maxPublications;

  /// Maximum groups per feed.
  final int maxGroups;

  /// Maximum facets per feed.
  final int maxFacets;

  /// Maximum subcollection members per feed or nested subcollection.
  final int maxSubcollections;

  /// Maximum links in one container.
  final int maxLinks;

  @override
  String toString() => 'Opds2Limits(maxBytes: $maxBytes, maxDepth: $maxDepth, maxNodes: $maxNodes)';
}
