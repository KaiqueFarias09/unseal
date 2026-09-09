/// One entry of a book's reading order.
class ReadingOrderItem {
  /// Creates an item for a file in the book's reading order.
  const ReadingOrderItem({required this.name, this.isHtml = true});

  /// The file name or path represented by this reading-order item.
  final String name;

  /// Whether the entry is HTML content (`files.html`) — comic pages are images instead.
  final bool isHtml;

  @override
  String toString() => 'ReadingOrderItem($name)';
}
