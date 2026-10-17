/// A rectangle in the canonical top-left page space: the `x` and `y`
/// fields place the upper-left corner, sizes grow right and down.
///
/// This is the shared spatial contract between format features that carry
/// positioned text (DjVu hidden-text zones, imported ALTO). Coordinates
/// are doubles because ALTO stores them as floats; integer sources keep
/// their exact values because doubles represent them exactly.
final class SpatialRect {
  /// Creates a rectangle; [ArgumentError] reports a negative size.
  SpatialRect({required this.x, required this.y, required this.width, required this.height}) {
    if (width < 0) {
      throw ArgumentError.value(width, 'width', 'Must be non-negative');
    }
    if (height < 0) {
      throw ArgumentError.value(height, 'height', 'Must be non-negative');
    }
  }

  /// The left edge.
  final double x;

  /// The top edge.
  final double y;

  /// The horizontal extent, in the owning page's unit.
  final double width;

  /// The vertical extent, in the owning page's unit.
  final double height;

  /// The right edge (`x + width`).
  double get right => x + width;

  /// The bottom edge (`y + height`).
  double get bottom => y + height;

  /// Whether the point lies inside or on the rectangle's edges.
  bool containsPoint(final num px, final num py) =>
      px >= x && px <= right && py >= y && py <= bottom;

  /// Whether [other] lies entirely inside this rectangle.
  bool contains(final SpatialRect other) =>
      other.x >= x && other.y >= y && other.right <= right && other.bottom <= bottom;

  /// Whether the two rectangles share any interior point.
  bool intersects(final SpatialRect other) =>
      x < other.right && other.x < right && y < other.bottom && other.y < bottom;

  @override
  bool operator ==(final Object other) =>
      other is SpatialRect &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(x, y, width, height);

  @override
  String toString() => 'SpatialRect($x, $y, $width×$height)';
}
