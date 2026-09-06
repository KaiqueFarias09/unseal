import 'dart:typed_data';

/// The PDF object model: the node types a document body parses into.
///
/// Mirrors the object grammar of PDF 32000-1:2008 §7.3 — null,
/// boolean, number, name, string, array, dictionary, stream and the
/// indirect reference `num gen R`. Indirect references stay
/// unresolved here; `PdfDocument.resolve` follows them on demand.
sealed class PdfObject {
  const PdfObject();
}

/// The `null` object.
final class PdfNull extends PdfObject {
  /// Creates the null object.
  const PdfNull();
}

/// The `true` / `false` object.
final class PdfBool extends PdfObject {
  /// Creates a boolean with the given [value].
  const PdfBool(this.value);

  /// The boolean value.
  final bool value;
}

/// An integer or real number literal.
final class PdfNumber extends PdfObject {
  /// Creates a number with the given [value].
  const PdfNumber(this.value);

  /// The numeric value; integer literals arrive with a zero fraction.
  final double value;

  /// The value rounded to an [int], as offsets, counts and
  /// measurements consume it.
  int get intValue => value.round();

  /// Whether the literal was written in integer syntax (`12`, not `12.5`).
  bool get isInteger => value == value.truncateToDouble();
}

/// A `/Name`, stored without the leading slash and with `#`-escapes
/// already decoded.
final class PdfName extends PdfObject {
  /// Creates a name from the decoded [value].
  const PdfName(this.value);

  /// The decoded name text (e.g. `Type`, `FlateDecode`).
  final String value;

  @override
  String toString() => '/$value';
}

/// A `(literal)` or `<hex>` string, kept as raw bytes: how it decodes
/// to text depends on context (a font's encoding, a `PDFDoc` string,
/// a UTF-16BE BOM header).
final class PdfString extends PdfObject {
  /// Creates a string holding the raw [bytes].
  const PdfString(this.bytes);

  /// The raw string bytes.
  final Uint8List bytes;
}

/// An array object.
final class PdfArray extends PdfObject {
  /// Creates an array over [items].
  const PdfArray(this.items);

  /// The element objects, possibly indirect references.
  final List<PdfObject> items;
}

/// A dictionary object.
final class PdfDictionary extends PdfObject {
  /// Creates a dictionary over [entries].
  const PdfDictionary(this.entries);

  /// The entries keyed by name text (no leading slash).
  final Map<String, PdfObject> entries;

  /// Looks the [name] entry up.
  PdfObject? operator [](final String name) => entries[name];

  /// Whether the [name] entry exists.
  bool containsKey(final String name) => entries.containsKey(name);
}

/// A stream object: a dictionary plus the raw bytes between the
/// `stream` and `endstream` keywords (filters not yet applied).
final class PdfStream extends PdfObject {
  /// Creates a stream from its [dictionary] and raw payload [bytes].
  const PdfStream(this.dictionary, this.bytes);

  /// The stream dictionary (carries `/Filter`, `/DecodeParms`,
  /// `/Length`, ...).
  final PdfDictionary dictionary;

  /// The undecoded stream payload.
  final Uint8List bytes;
}

/// An unresolved `num gen R` reference to an indirect object.
final class PdfIndirectRef extends PdfObject {
  /// Creates a reference to [objectNumber]:[generation].
  const PdfIndirectRef(this.objectNumber, this.generation);

  /// The referenced object number.
  final int objectNumber;

  /// The referenced generation number (practically always 0).
  final int generation;

  @override
  String toString() => '$objectNumber $generation R';
}
