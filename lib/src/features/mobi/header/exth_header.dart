import 'dart:typed_data';

import '../codec/mobi_text_codec.dart';
import '../exceptions/exceptions.dart';

/// The EXTH (extended header) of a MOBI file.
class ExthHeader {
  /// Parses the EXTH block ([raw] starts at the `EXTH` magic).
  factory ExthHeader.parse(final Uint8List raw, final String codec, final String headerTitle) {
    if (raw.length < 12 || raw[0] != 0x45 || raw[1] != 0x58 || raw[2] != 0x54 || raw[3] != 0x48) {
      throw const MobiException('Invalid EXTH header.');
    }

    final view = ByteData.sublistView(raw);
    final length = view.getUint32(4);
    final itemCount = view.getUint32(8);
    final records = <int, List<Uint8List>>{};
    var pos = 12;
    var left = itemCount;
    while (left > 0 && pos + 8 <= raw.length && pos < length) {
      left--;
      final id = view.getUint32(pos);
      final size = view.getUint32(pos + 4);
      if (size < 8) break;

      final contentEnd = pos + size;
      final content = contentEnd <= raw.length
          ? Uint8List.sublistView(raw, pos + 8, contentEnd)
          : Uint8List.sublistView(raw, pos + 8);
      records.putIfAbsent(id, () => <Uint8List>[]).add(content);
      pos += size;
    }

    var title = headerTitle;
    final updatedTitle = records[ExthIds.updatedTitle];
    if (updatedTitle != null && updatedTitle.isNotEmpty) {
      final decoded = decodeBytes(updatedTitle.first, codec).trim();
      if (decoded.isNotEmpty) {
        title = decoded;
      }
    }

    return ExthHeader._(records, title);
  }

  ExthHeader._(this._records, this.title);

  final Map<int, List<Uint8List>> _records;

  /// The resolved title (EXTH 503 wins over the MOBI header title).
  final String title;

  /// Cover record offset (EXTH 201) when valid.
  int? get coverOffset {
    final offset = int32(ExthIds.coverOffset);
    if (offset == null || offset == 0xFFFFFFFF) return null;

    return offset;
  }

  /// Whether the file flags a fake cover (EXTH 203).
  bool get hasFakeCover => int32(ExthIds.hasFakeCover) != 0;

  /// KF8 header record index in joint files (EXTH 121).
  int? get kf8HeaderIndex {
    final index = int32(ExthIds.kf8Header);
    if (index == null || index == 0xFFFFFFFF) return null;

    return index;
  }

  /// Page progression direction (EXTH 527): `ltr`, `rtl` or `default`
  /// when the record carries a value, null otherwise. The raw EXTH string
  /// is returned without normalizing its value.
  String? get pageProgressionDirection => _nonEmpty(ExthIds.pageProgressionDirection);

  /// Primary writing mode (EXTH 525) when the record carries a value.
  String? get primaryWritingMode => _nonEmpty(ExthIds.primaryWritingMode);

  /// Thumbnail record offset (EXTH 202).
  int? get thumbnailOffset => int32(ExthIds.thumbnailOffset);

  /// The first payload for [id] as a big-endian u32.
  int? int32(final int id) {
    final values = _records[id];
    if (values == null || values.isEmpty || values.first.length < 4) return null;

    return ByteData.sublistView(values.first).getUint32(0);
  }

  /// All raw payloads stored for [id].
  List<Uint8List> rawValues(final int id) => _records[id] ?? const <Uint8List>[];

  /// The first payload for [id] decoded with [codec].
  String? string(final int id, [final String codec = 'utf-8']) {
    final values = _records[id];
    if (values == null || values.isEmpty) return null;

    return decodeBytes(values.first, codec);
  }

  /// All payloads for [id] decoded with [codec].
  List<String> strings(final int id, [final String codec = 'utf-8']) {
    return (_records[id] ?? const <Uint8List>[])
        .map((final value) => decodeBytes(value, codec))
        .toList();
  }

  /// The first payload for [id] decoded and trimmed; null when absent
  /// or empty.
  String? _nonEmpty(final int id) {
    final value = string(id);
    if (value == null) return null;

    final trimmed = value.trim();

    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Well-known EXTH record ids.
abstract final class ExthIds {
  /// ASIN.
  static const asin = 113;

  /// Author name (`Last, First` in Amazon files).
  static const author = 100;

  /// Book producer.
  static const bookProducer = 108;

  /// cdetype (`EBOK`, `PDOC`, `EBSP`, ...).
  static const cdeType = 501;

  /// Cover image record offset (relative to first image record).
  static const coverOffset = 201;

  /// Description / comments.
  static const description = 103;

  /// Fake cover flag.
  static const hasFakeCover = 203;

  /// ISBN.
  static const isbn = 104;

  /// KF8 header record index in joint files.
  static const kf8Header = 121;

  /// Language code string.
  static const language = 524;

  /// Page progression direction (`ltr`, `rtl` or `default`).
  static const pageProgressionDirection = 527;

  /// Primary writing mode.
  static const primaryWritingMode = 525;

  /// Publication date.
  static const publishDate = 106;

  /// Publisher.
  static const publisher = 101;

  /// Copyright / rights.
  static const rights = 109;

  /// dc:source (may carry an ISBN URI or a provider UUID).
  static const source = 112;

  /// Start reading offset.
  static const startOffset = 116;

  /// Subject / tags (`;` separated).
  static const subject = 105;

  /// Thumbnail image record offset.
  static const thumbnailOffset = 202;

  /// Long (updated) title — authoritative per Amazon.
  static const updatedTitle = 503;
}
