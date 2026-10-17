import '../../foundation/spatial/spatial_rect.dart';
import '../../foundation/spatial/spatial_unit.dart';
import 'alto_exception.dart';

/// A verified conversion from one ALTO document's coordinates into pixel
/// space.
///
/// The factor must come from evidence the host can check: a declared dpi
/// for physical units, or agreement between the document's declared page
/// dimensions and the real page's pixel dimensions. A physical unit
/// without verifiable evidence has no scale at all — `mm10` coordinates
/// with no dpi simply do not determine pixel sizes — and the conversion
/// refuses with [AltoUnitConversionException] instead of guessing.
final class AltoScale {
  const AltoScale._(this.factor);

  /// The identity scale for pixel-unit documents.
  const AltoScale.identity() : factor = 1.0;

  /// Builds the scale a [unit]-denominated document needs from a
  /// declared [dpi]; [ArgumentError] reports a non-positive value.
  /// Returns null when the unit is physical and no verifiable dpi
  /// exists.
  static AltoScale? fromUnit(final SpatialUnit unit, {required final double? dpi}) {
    final pixelsPerUnit = unit.pixelScale(dpi: dpi);
    if (pixelsPerUnit == null) return null;

    return AltoScale._(pixelsPerUnit);
  }

  /// Builds the scale from page-dimension agreement: the document's
  /// declared page size against the target page's pixel size. Both
  /// aspect ratios must agree within 1%, so a mismatched pair refuses
  /// instead of inventing an axis-dependent stretch.
  factory AltoScale.fromPageDimensions({
    required final double documentWidth,
    required final double documentHeight,
    required final double targetWidth,
    required final double targetHeight,
  }) {
    if (documentWidth <= 0 || documentHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) {
      throw ArgumentError('Page dimensions must be positive');
    }
    final documentAspect = documentWidth / documentHeight;
    final targetAspect = targetWidth / targetHeight;
    if ((documentAspect - targetAspect).abs() / documentAspect > 0.01) {
      throw const AltoUnitConversionException(
        'The document page aspect disagrees with the target page; the scale '
        'is not verifiable.',
      );
    }

    return AltoScale._(targetWidth / documentWidth);
  }

  /// The multiplier that turns one document-unit length into pixels.
  final double factor;

  /// Converts [rect] from the document's unit into pixels.
  SpatialRect convertRect(final SpatialRect rect) {
    return SpatialRect(
      x: rect.x * factor,
      y: rect.y * factor,
      width: rect.width * factor,
      height: rect.height * factor,
    );
  }
}
