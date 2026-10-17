/// The unit every coordinate of one spatial document is expressed in.
///
/// The values are the ALTO `MeasurementUnit` enumeration — the only unit
/// vocabulary the shared contract carries. DjVu hidden text is always
/// [pixel].
enum SpatialUnit {
  /// One image pixel. Self-verifying: no external scale is needed.
  pixel,

  /// One tenth of a millimetre (`mm10` in ALTO).
  millimeter10,

  /// One 1200th of an inch (`inch1200` in ALTO).
  inch1200;

  /// The multiplier that converts this unit's lengths into pixels, or
  /// null when the conversion cannot be verified.
  ///
  /// [pixel] needs no external evidence and always converts by 1.
  /// The physical units need a positive [dpi] (dots per inch) declared by
  /// a verified source; without one the conversion is indeterminate and
  /// this returns null instead of guessing a scale.
  double? pixelScale({final double? dpi}) {
    switch (this) {
      case SpatialUnit.pixel:
        return 1.0;
      case SpatialUnit.millimeter10:
        final value = dpi;
        if (value == null || value <= 0) return null;

        return value / 254.0;
      case SpatialUnit.inch1200:
        final value = dpi;
        if (value == null || value <= 0) return null;

        return value / 1200.0;
    }
  }
}
