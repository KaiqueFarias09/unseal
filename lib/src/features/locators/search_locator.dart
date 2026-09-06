/// Bridges full-text search hits and the locator API: a search match
/// is already a range in one section's document-text space, so it
/// becomes a [TextLocator] directly.
library;

import 'package:e_livre/src/features/locators/book_locator.dart';
import 'package:e_livre/src/features/search/book_search.dart';

/// Locator conversions for [SearchMatch].
extension SearchMatchLocators on SearchMatch {
  /// The match as a [TextLocator]: the same section and offsets, end
  /// exclusive, without a quote — search hits carry no relocation
  /// context.
  TextLocator toTextLocator() => TextLocator(sectionIndex: sectionIndex, start: start, end: end);
}
