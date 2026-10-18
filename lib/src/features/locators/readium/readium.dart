/// Readium Locator interchange and deterministic position lists.
///
/// The feature converts between the Readium Locator model and Unseal's
/// BookLocator union (exact, approximate, ambiguous, and unsupported
/// outcomes), decodes and encodes Readium Locator and position-list JSON
/// under declared limits, and generates position lists under the
/// versioned `unseal.readium.positions/1` profile — over eager books and
/// over live BookSessions with observable coverage and cancellation.
/// `doc/readium-locators.md` is the normative contract; the executed
/// `@readium/shared` 2.8.0 toolkit is the interchange oracle.
library;

export 'readium_codec.dart';
export 'readium_conversion.dart';
export 'readium_limits.dart';
export 'readium_locator.dart';
export 'readium_media_type.dart';
export 'readium_position_builder.dart';
export 'readium_position_list.dart';
export 'readium_position_profile.dart';
export 'readium_session_conversion.dart';
