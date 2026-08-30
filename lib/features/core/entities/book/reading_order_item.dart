/// One entry of a book's reading order.
class ReadingOrderItem {
  const ReadingOrderItem({required this.name, this.isHtml = true});

  /// The file name/path, matching the entries of `Files`.
  final String name;

  /// Whether the entry is HTML content (`files.html`) — comic pages
  /// are images instead.
  final bool isHtml;

  @override
  String toString() => 'ReadingOrderItem($name)';
}
