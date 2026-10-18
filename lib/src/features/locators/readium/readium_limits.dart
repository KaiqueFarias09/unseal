/// Resource bounds for Readium Locator interchange and position-list
/// generation, per `doc/readium-locators.md`.
///
/// Every bound is checked before the corresponding output is allocated.
/// Defaults are locator-sized; a host that deliberately accepts larger
/// payloads copies with larger values.
final class ReadiumLocatorLimits {
  /// Creates a limit set. All values must be positive.
  const ReadiumLocatorLimits({
    this.maxJsonCodeUnits = defaultMaxJsonCodeUnits,
    this.maxJsonDepth = defaultMaxJsonDepth,
    this.maxJsonNodes = defaultMaxJsonNodes,
    this.maxJsonStringLength = defaultMaxJsonStringLength,
    this.maxFragments = defaultMaxFragments,
    this.maxFragmentLength = defaultMaxFragmentLength,
    this.maxExtensions = defaultMaxExtensions,
    this.maxExtensionKeyLength = defaultMaxExtensionKeyLength,
    this.maxExtensionValueBytes = defaultMaxExtensionValueBytes,
    this.maxExtensionDepth = defaultMaxExtensionDepth,
    this.maxTextContextLength = defaultMaxTextContextLength,
  }) : assert(maxJsonCodeUnits > 0),
       assert(maxJsonDepth > 0),
       assert(maxJsonNodes > 0),
       assert(maxJsonStringLength > 0),
       assert(maxFragments > 0),
       assert(maxFragmentLength > 0),
       assert(maxExtensions > 0),
       assert(maxExtensionKeyLength > 0),
       assert(maxExtensionValueBytes > 0),
       assert(maxExtensionDepth > 0),
       assert(maxTextContextLength > 0);

  /// Default source-string cap for one Locator / position-list JSON
  /// document, in UTF-16 code units (bytes for ASCII input).
  static const int defaultMaxJsonCodeUnits = 1 << 20;

  /// Default maximum JSON nesting depth.
  static const int defaultMaxJsonDepth = 32;

  /// Default maximum number of JSON values in one document.
  static const int defaultMaxJsonNodes = 50000;

  /// Default maximum length of a single JSON string.
  static const int defaultMaxJsonStringLength = 1 << 20;

  /// Default maximum fragment count per locator.
  static const int defaultMaxFragments = 64;

  /// Default maximum length of one fragment.
  static const int defaultMaxFragmentLength = 4096;

  /// Default maximum unregistered extension keys per locations object.
  static const int defaultMaxExtensions = 16;

  /// Default maximum extension key length.
  static const int defaultMaxExtensionKeyLength = 256;

  /// Default maximum serialized size of one extension value.
  static const int defaultMaxExtensionValueBytes = 4096;

  /// Default maximum nesting depth of one extension value.
  static const int defaultMaxExtensionDepth = 8;

  /// Default maximum length of one `text` context field.
  static const int defaultMaxTextContextLength = 64 * 1024;

  /// Source-string cap in code units, checked before any parse.
  final int maxJsonCodeUnits;

  /// JSON nesting depth, checked before decoding.
  final int maxJsonDepth;

  /// JSON value count, checked before decoding.
  final int maxJsonNodes;

  /// Single JSON string length, checked before decoding.
  final int maxJsonStringLength;

  /// Fragment count per locator.
  final int maxFragments;

  /// Length of one fragment.
  final int maxFragmentLength;

  /// Unregistered extension keys per locations object.
  final int maxExtensions;

  /// Extension key length.
  final int maxExtensionKeyLength;

  /// Serialized size of one extension value.
  final int maxExtensionValueBytes;

  /// Nesting depth of one extension value.
  final int maxExtensionDepth;

  /// Length of one `text` context field.
  final int maxTextContextLength;
}

/// Resource bounds for position-list generation.
final class ReadiumPositionLimits {
  /// Creates a limit set; [maxPositions] must be positive.
  const ReadiumPositionLimits({
    this.maxPositions = defaultMaxPositions,
    this.maxTextCodeUnits = 64 * 1024 * 1024,
  }) : assert(maxPositions > 0),
       assert(maxTextCodeUnits > 0);

  /// Default cap on emitted positions per list.
  static const int defaultMaxPositions = 100000;

  /// Cap on emitted positions per list; crossing it fails typed instead of
  /// truncating silently.
  final int maxPositions;

  /// Cumulative canonical UTF-16 units visited per pass, including repeated occurrences.
  final int maxTextCodeUnits;
}

/// Base of the Readium feature's typed failures.
sealed class ReadiumLocatorException implements Exception {
  /// Creates a failure with its [message].
  const ReadiumLocatorException(this.message);

  /// What failed and why.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A payload is not a structurally valid Readium document.
final class ReadiumLocatorFormatException extends ReadiumLocatorException {
  /// Creates the failure.
  const ReadiumLocatorFormatException(super.message);
}

/// A payload crossed a [ReadiumLocatorLimits] or [ReadiumPositionLimits]
/// bound before the crossed output was allocated.
final class ReadiumLocatorLimitException extends ReadiumLocatorException {
  /// Creates the failure.
  const ReadiumLocatorLimitException(super.message);
}

/// Position-list generation crossed a [ReadiumPositionLimits] bound.
final class ReadiumPositionLimitException extends ReadiumLocatorException {
  /// Creates the failure.
  const ReadiumPositionLimitException(super.message);
}
