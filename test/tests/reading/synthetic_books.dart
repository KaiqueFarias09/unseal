import 'package:unseal/src/foundation/entities/entities.dart';

/// A minimal in-memory [Book] for reading-feature tests: arbitrary
/// HTML files, navigation and reading order without a container
/// archive.
final class SyntheticBook extends Book {
  /// Creates a [SyntheticBook]; [order] overrides the reading order
  /// (defaulting to the HTML extraction order like real books do).
  SyntheticBook({
    required this.files,
    required this.navigation,
    List<ReadingOrderItem> order = const <ReadingOrderItem>[],
    this.isHtml = true,
  }) : _order = order,
       super(format: BookFormat.epub);

  @override
  final Files files;

  @override
  final Navigation navigation;

  /// Value used for every reading-order entry when the `order`
  /// argument is empty (flip to `false` for comic-like books).
  final bool isHtml;

  final List<ReadingOrderItem> _order;

  @override
  BookMetadata get metadata => const BookMetadata(format: BookFormat.epub);

  @override
  List<ReadingOrderItem> get readingOrder {
    return _order.isEmpty
        ? <ReadingOrderItem>[
            for (final file in files.html) ReadingOrderItem(name: file.path, isHtml: isHtml),
          ]
        : _order;
  }
}

/// Convenience builder: one HTML [TextFile] per [contents] entry,
/// named by index.
Files htmlFiles(final List<String> contents) {
  return Files(
    images: const <BinaryFile>[],
    css: const <TextFile>[],
    html: <TextFile>[
      for (var i = 0; i < contents.length; i++)
        TextFile(
          name: 'section$i.html',
          type: 'html',
          path: 'section$i.html',
          content: contents[i],
        ),
    ],
    fonts: const <BinaryFile>[],
    others: const <BinaryFile>[],
  );
}

/// A navigation with [points] at the top level.
Navigation navigationOf(final List<NavPoint> points) {
  return Navigation(title: 'test', navPoints: points);
}

/// A [NavPoint] with only the fields the reading tests need.
NavPoint navPoint(final String content, {final List<NavPoint> children = const <NavPoint>[]}) {
  return NavPoint(
    classAttribute: '',
    id: content,
    playOrder: '0',
    label: content,
    content: content,
    subNavPoints: children,
  );
}
