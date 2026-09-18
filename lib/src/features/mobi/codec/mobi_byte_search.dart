import 'dart:typed_data';

/// Whether [data] contains the ASCII [expected] value at [offset].
bool hasAsciiAt(final Uint8List data, final String expected, [final int offset = 0]) {
  if (offset < 0 || offset + expected.length > data.length) return false;

  for (var i = 0; i < expected.length; i++) {
    if (data[offset + i] != expected.codeUnitAt(i)) return false;
  }

  return true;
}

/// Finds [byte] in [data], starting at [from].
int indexOfByte(final Uint8List data, final int byte, final int from) {
  for (var i = from < 0 ? 0 : from; i < data.length; i++) {
    if (data[i] == byte) return i;
  }

  return -1;
}

/// Finds the last [byte] in the half-open range `[from, to)`.
int lastIndexOfByte(final Uint8List data, final int byte, final int from, final int to) {
  final start = from < 0 ? 0 : from;
  final end = to > data.length ? data.length : to;
  for (var i = end - 1; i >= start; i--) {
    if (data[i] == byte) return i;
  }

  return -1;
}

/// Whether [text] contains [needle], ignoring ASCII letter case.
bool containsAsciiIgnoreCase(final String text, final String needle) {
  final units = text.codeUnits;
  final needleUnits = needle.codeUnits;
  final lastStart = units.length - needleUnits.length;
  for (var i = 0; i <= lastStart; i++) {
    var isMatched = true;
    for (var j = 0; j < needleUnits.length; j++) {
      if (asciiLowerCase(units[i + j]) != asciiLowerCase(needleUnits[j])) {
        isMatched = false;
        break;
      }
    }

    if (isMatched) return true;
  }

  return false;
}

/// Converts an ASCII uppercase code unit to lowercase.
int asciiLowerCase(final int codeUnit) {
  return codeUnit >= 0x41 && codeUnit <= 0x5A ? codeUnit + 0x20 : codeUnit;
}
