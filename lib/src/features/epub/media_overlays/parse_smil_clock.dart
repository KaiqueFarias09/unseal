/// Parses clock values from EPUB 3 SMIL media overlays.
library;

/// Parses a SMIL clock value into a [Duration]. Supported forms per
/// the SMIL/EPUB spec: full clock (`hh:mm:ss.fraction`), partial
/// clock (`mm:ss.fraction`), timecount with unit (`12.5s`, `450ms`,
/// `2min`, `1h`) and bare numbers (seconds). Returns null for empty
/// or unparseable values.
Duration? parseSmilClock(final String? value) {
  if (value == null) return null;

  final raw = value.trim();
  if (raw.isEmpty) return null;

  final fullClock = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)$').firstMatch(raw);
  if (fullClock != null) {
    return Duration(
      hours: int.parse(fullClock.group(1)!),
      minutes: int.parse(fullClock.group(2)!),
      milliseconds: (_fractional(fullClock.group(3)!) * 1000).round(),
    );
  }

  final partialClock = RegExp(r'^(\d{1,2}):(\d{1,2}(?:\.\d+)?)$').firstMatch(raw);
  if (partialClock != null) {
    return Duration(
      minutes: int.parse(partialClock.group(1)!),
      milliseconds: (_fractional(partialClock.group(2)!) * 1000).round(),
    );
  }

  final timecount = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|min|h)?$').firstMatch(raw);
  if (timecount == null) return null;

  final amount = double.parse(timecount.group(1)!);

  return switch (timecount.group(2)) {
    'ms' => Duration(milliseconds: amount.round()),
    'min' => Duration(milliseconds: (amount * 60000).round()),
    'h' => Duration(milliseconds: (amount * 3600000).round()),
    _ => Duration(milliseconds: (amount * 1000).round()),
  };
}

double _fractional(final String seconds) => double.parse(seconds);
