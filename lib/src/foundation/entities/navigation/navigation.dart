import 'nav_point.dart';

/// The navigation (table of contents) of a book.
///
/// Format-agnostic: every format module builds this structure from
/// its native navigation source (EPUB NCX / nav document, Kindle NCX
/// index, FB2 section titles, ...).
class Navigation {
  /// Creates a new [Navigation].
  Navigation({required this.title, required this.navPoints});

  /// The title of the navigation document.
  final String title;

  /// The top level navigation points, in reading order.
  final List<NavPoint> navPoints;

  @override
  String toString() => 'Navigation(title: $title, navPoints: $navPoints)';
}
