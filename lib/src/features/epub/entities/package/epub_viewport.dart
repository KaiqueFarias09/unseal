/// Page dimensions declared for an EPUB content document.
///
/// Fixed-layout XHTML declares them through a `<meta name="viewport">`
/// element; standalone SVG content documents declare them through the
/// root `<svg>` element's `width`/`height` attributes or `viewBox`.
final class EpubViewport {
  /// Creates page dimensions in CSS pixels.
  const EpubViewport({required this.width, required this.height});

  /// Declared page width in CSS pixels.
  final int width;

  /// Declared page height in CSS pixels.
  final int height;

  @override
  bool operator ==(final Object other) =>
      other is EpubViewport && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'EpubViewport(width: $width, height: $height)';
}
