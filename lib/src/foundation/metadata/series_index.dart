/// Parses a series index such as `2`, `2.5` or `0,5`.
double? parseSeriesIndex(final String? raw) {
  return raw == null ? null : double.tryParse(raw.trim().replaceAll(',', '.'));
}
