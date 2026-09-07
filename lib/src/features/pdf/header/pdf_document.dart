import 'dart:convert' as convert;
import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import '../security/pdf_object_decryptor.dart';
import '../security/pdf_security_handler.dart';
import '../utils/pdf_stream_filters.dart';
import 'pdf_object.dart';
import 'pdf_object_parser.dart';

/// One cross-reference entry: where an indirect object lives.
///
/// Type 1 entries hold a plain byte offset; type 2 entries point at
/// the object stream (`streamNumber`, `index`) that packs the object.
sealed class _XrefEntry {
  const _XrefEntry();
}

final class _OffsetEntry extends _XrefEntry {
  const _OffsetEntry(this.offset);

  final int offset;
}

final class _ObjectStreamEntry extends _XrefEntry {
  const _ObjectStreamEntry(this.streamNumber, this.index);

  final int streamNumber;
  final int index;
}

/// The decoded header of one object stream: the packed object bodies
/// plus the `num / relative-offset` pairs read from its front.
final class _ObjectStreamData {
  const _ObjectStreamData(this.data, this.first, this.numbers, this.offsets);

  final Uint8List data;
  final int first;
  final List<int?> numbers;
  final List<int?> offsets;
}

/// The parsed cross-reference and object store of one PDF document.
///
/// Reads the `startxref` chain — classic tables and PDF 1.5
/// cross-reference streams alike, including hybrid files that mix
/// both — and falls back to scanning the whole file for `num gen obj`
/// headers when the chain is unusable (the same recovery Poppler
/// performs). Objects parse lazily on first access and cache.
///
/// Encrypted documents authenticate through the standard security
/// handler (revisions R2-R6, see `PdfSecurityHandler`): [parse]
/// takes the `password`, tries the empty one first and throws
/// [PdfEncryptedException] — carrying `requiresNonEmptyPassword`
/// semantics — when nothing matches. On success every indirect
/// string and stream decrypts transparently on read; the `/Encrypt`
/// dictionary itself and cross-reference streams stay clear, and
/// the library does not enforce the `/P` permission bits.
class PdfDocument {
  PdfDocument._(this.bytes, this._entries, this.trailer, this._security);

  /// Parses the document structure out of [bytes], opening
  /// encrypted documents with [password].
  ///
  /// Only the cross-reference layer is read; page trees, content
  /// streams and metadata resolve lazily through [object].
  static PdfDocument parse(final Uint8List bytes, {final String password = ''}) {
    if (_pdfHeaderOffset(bytes) == null) {
      throw const PdfException('Not a PDF document (missing %PDF header).');
    }

    final entries = <int, _XrefEntry>{};
    final parser = PdfObjectParser(bytes);
    PdfDictionary? trailer;
    PdfDictionary? encryptDictionary;
    var encryptReference = false;
    final visited = <int>{};

    var offset = _startXrefOffset(bytes);
    while (offset != null &&
        offset > 0 &&
        offset < bytes.length &&
        !visited.contains(offset) &&
        entries.length <= _maxXrefEntries) {
      visited.add(offset);
      final trailerDictionary = _readXrefAt(parser, offset, entries);
      if (trailerDictionary != null) {
        trailer ??= trailerDictionary;
        if (trailerDictionary.containsKey('Encrypt')) encryptReference = true;
        // The hybrid-reference /XRefStm pointer: a cross-reference
        // stream holding type 2 entries the classic table cannot.
        final streamOffset = _intValue(trailerDictionary['XRefStm']);
        if (streamOffset != null &&
            streamOffset > 0 &&
            streamOffset < bytes.length &&
            !visited.contains(streamOffset)) {
          visited.add(streamOffset);
          final streamTrailer = _readXrefAt(parser, streamOffset, entries);
          if (streamTrailer != null && streamTrailer.containsKey('Encrypt')) {
            encryptReference = true;
          }
        }
      }
      offset = _intValue(trailerDictionary?['Prev']);
    }

    if (entries.isEmpty) {
      trailer ??= _scanForTrailer(parser);
      _scanObjects(parser.bytes, entries);
    }

    if (trailer == null) throw const PdfException('PDF document has no trailer dictionary.');
    if (entries.isEmpty) throw const PdfException('PDF document exposes no indirect objects.');

    // Encryption resolves only after the whole chain is merged: the
    // /Encrypt object itself can sit anywhere in the file, so its
    // offset comes from the collected entries, never a guess.
    encryptDictionary ??= _encryptDictionaryOf(trailer, entries, parser);
    final security = _authenticate(
      encryptDictionary,
      trailer,
      entries,
      parser,
      password,
      encryptReference,
    );

    return PdfDocument._(bytes, entries, trailer, security);
  }

  /// Pulls the `/Encrypt` dictionary out of a trailer, following an
  /// indirect reference through [entries] — the encryption object is
  /// a plain body object, never encrypted, and its offset is known
  /// once the whole cross-reference chain has merged.
  static PdfDictionary? _encryptDictionaryOf(
    final PdfDictionary trailer,
    final Map<int, _XrefEntry> entries,
    final PdfObjectParser parser,
  ) {
    final value = trailer['Encrypt'];
    if (value is PdfDictionary) return value;
    if (value is PdfIndirectRef) {
      final header = _headerFor(entries, parser, value.objectNumber);

      return header == null
          ? null
          : _parseBody(parser, header) is PdfDictionary
          ? _parseBody(parser, header) as PdfDictionary
          : null;
    }

    return null;
  }

  /// The `num gen obj` header for [number] from [entries], falling
  /// back to a whole-file scan when the cross-reference omits it
  /// (broken writers drop the encryption object from the table).
  static (int, int, int)? _headerFor(
    final Map<int, _XrefEntry> entries,
    final PdfObjectParser parser,
    final int number,
  ) {
    final entry = entries[number];
    if (entry is _OffsetEntry) {
      final header = parser.objectHeaderAt(entry.offset);
      if (header != null && header.$1 == number) return header;
    }

    return _scanHeader(parser.bytes, number);
  }

  /// Parses an object body from an already-read [header].
  static PdfObject _parseBody(final PdfObjectParser parser, final (int, int, int) header) =>
      parser.parseAt(header.$3);

  /// Scans the whole file for [number]'s object header — the bounded
  /// tail walk cannot serve here: encryption objects sit anywhere in
  /// the body, not near the trailer.
  static (int, int, int)? _scanHeader(final Uint8List bytes, final int number) {
    final needle = convert.ascii.encode('$number ');
    for (var pos = 0; pos + needle.length < bytes.length; pos++) {
      var matched = true;
      for (var i = 0; i < needle.length; i++) {
        if (bytes[pos + i] != needle[i]) {
          matched = false;
          break;
        }
      }
      if (!matched) continue;
      final parser = PdfObjectParser(bytes);
      final header = parser.objectHeaderAt(pos);
      if (header != null && header.$1 == number) return header;
    }

    return null;
  }

  /// Finds `%PDF` after only the bounded preamble accepted by the format
  /// detector: an optional UTF-8 BOM at byte zero and ASCII whitespace.
  /// The original [bytes] remain intact so every xref/object offset stays
  /// absolute, including when a preamble is present.
  static int? _pdfHeaderOffset(final Uint8List bytes) {
    final lastOffset = bytes.length - _pdfMagic.length;
    if (lastOffset < 0) return null;

    final boundedLastOffset = lastOffset < _maxPdfPreambleBytes ? lastOffset : _maxPdfPreambleBytes;
    for (var offset = 0; offset <= boundedLastOffset; offset++) {
      if (!_startsAt(bytes, offset, _pdfMagic)) continue;

      var preambleEnd = 0;
      if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        preambleEnd = 3;
      }
      while (preambleEnd < offset && _isPdfWhitespace(bytes[preambleEnd])) {
        preambleEnd++;
      }
      if (preambleEnd == offset) return offset;
    }

    return null;
  }

  static bool _startsAt(final Uint8List bytes, final int offset, final List<int> magic) {
    if (offset < 0 || offset + magic.length > bytes.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }

    return true;
  }

  static bool _isPdfWhitespace(final int byte) =>
      byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20;

  /// Builds the security handler for an encrypted document and
  /// authenticates [password]: the empty string first (owner-only
  /// files), then, when non-empty, the given password as user and
  /// owner. Throws [PdfEncryptedException] enriched with
  /// `requiresNonEmptyPassword` semantics on failure.
  static PdfSecurityHandler? _authenticate(
    final PdfDictionary? encryptDictionary,
    final PdfDictionary trailer,
    final Map<int, _XrefEntry> entries,
    final PdfObjectParser parser,
    final String password,
    final bool encryptReference,
  ) {
    if (!encryptReference && encryptDictionary == null) return null;
    if (encryptDictionary == null) {
      // The trailer references encryption the body does not carry
      // (a broken incremental update); treat it as unusable rather
      // than silently decrypting nothing.
      throw const PdfEncryptedException();
    }

    final idObject = _trailerIdOf(trailer, entries, parser);
    final filter = encryptDictionary['Filter'];
    final isStandard = filter is PdfName && filter.value == 'Standard';
    final PdfSecurityHandler handler;
    try {
      handler = PdfSecurityHandler.of(encryptDictionary, idObject, (final object) => object);
    } on PdfException {
      if (!isStandard) rethrow;
      // A /Standard dictionary too broken to build (missing /R or /O
      // or /U) still means the document needs a password to open.
      throw const PdfEncryptedException();
    }
    if (handler.authenticate(password)) return handler;

    throw PdfEncryptedException(
      requiresNonEmptyPassword: password.isEmpty,
      permissions: handler.permissions,
    );
  }

  /// The trailer `/ID` array (indirect in some writers), resolved
  /// through the collected entries.
  static PdfObject? _trailerIdOf(
    final PdfDictionary trailer,
    final Map<int, _XrefEntry> entries,
    final PdfObjectParser parser,
  ) {
    final value = trailer['ID'];
    if (value is PdfIndirectRef) {
      final header = _headerFor(entries, parser, value.objectNumber);

      return header == null ? null : _parseBody(parser, header);
    }

    return value;
  }

  /// The document bytes.
  final Uint8List bytes;

  /// The newest trailer dictionary of the cross-reference chain.
  final PdfDictionary trailer;

  final Map<int, _XrefEntry> _entries;

  /// The authenticated security handler, null for unencrypted
  /// documents; decrypts every object read through [object].
  final PdfSecurityHandler? _security;

  /// The security handler behind this document — null when the
  /// document is unencrypted; exposes `isOwnerAuthenticated` and the
  /// `/P` permission bits for callers that want them.
  PdfSecurityHandler? get security => _security;

  /// The lazy per-object decryptor, built on first encrypted read.
  PdfObjectDecryptor? _decryptor;

  final Map<int, PdfObject?> _cache = <int, PdfObject?>{};

  final Map<PdfStream, _ObjectStreamData> _objectStreams = <PdfStream, _ObjectStreamData>{};

  late final PdfObjectParser _parser = PdfObjectParser(bytes, streamLengthOf: _resolveStreamLength);

  /// Reads the object with the given [number], or null when the
  /// cross-reference does not carry it or its entry is stale.
  PdfObject? object(final int number) {
    if (_cache.containsKey(number)) return _cache[number];
    final entry = _entries[number];
    PdfObject? result;
    if (entry is _OffsetEntry) {
      final header = _parser.objectHeaderAt(entry.offset);
      if (header != null && header.$1 == number) {
        result = _decryptIfEncrypted(_parser.parseAt(header.$3), number, header.$2);
      }
    } else if (entry is _ObjectStreamEntry) {
      result = _objectFromStream(entry);
    }
    _cache[number] = result;

    return result;
  }

  /// Applies the security handler's per-object decryption to a
  /// freshly parsed object; [generation] comes from the object
  /// header. Unencrypted documents pass through untouched.
  PdfObject? _decryptIfEncrypted(final PdfObject? parsed, final int number, final int generation) {
    final handler = _security;
    if (handler == null || parsed == null) return parsed;
    final trailerEncrypt = trailer['Encrypt'];
    final referenceNumber = trailerEncrypt is PdfIndirectRef ? trailerEncrypt.objectNumber : -1;
    if (number == referenceNumber) {
      // The /Encrypt dictionary's own strings are never encrypted
      // (PDF 32000 §7.6.1); it is also already parsed and stored on
      // the handler, so its cached form stays raw.
      return parsed;
    }
    _decryptor ??= PdfObjectDecryptor.of(handler);

    return _decryptor!.decryptObject(parsed, number, generation);
  }

  /// Follows [value] through indirect references until a real object
  /// (or an unresolvable null) comes back.
  PdfObject? resolve(final PdfObject? value) {
    var current = value;
    for (var depth = 0; depth < 32 && current is PdfIndirectRef; depth++) {
      current = object(current.objectNumber);
    }

    return current;
  }

  /// The document catalog (`/Root`), or null when unreadable.
  PdfDictionary? get catalog {
    final root = resolve(trailer['Root']);

    return root is PdfDictionary ? root : null;
  }

  /// Decodes [stream]'s bytes through its filter chain, resolving
  /// indirect filter entries through this document.
  Uint8List decodeStream(final PdfStream stream) => decodePdfStream(stream, resolve);

  PdfObject? _objectFromStream(final _ObjectStreamEntry entry) {
    final container = object(entry.streamNumber);
    if (container is! PdfStream) return null;
    final decoded = _decodeObjectStream(container);
    if (decoded == null || entry.index >= decoded.numbers.length) return null;
    final relative = decoded.offsets[entry.index];
    if (relative == null) return null;
    final bodyOffset = decoded.first + relative;
    if (bodyOffset < 0 || bodyOffset >= decoded.data.length) return null;

    return PdfObjectParser(decoded.data).parseAt(bodyOffset);
  }

  _ObjectStreamData? _decodeObjectStream(final PdfStream container) {
    final cached = _objectStreams[container];
    if (cached != null) return cached;

    final count = _intValue(container.dictionary['N']) ?? 0;
    final first = _intValue(container.dictionary['First']) ?? -1;
    if (count <= 0 || first < 0) return null;

    Uint8List data;
    try {
      data = decodeStream(container);
    } on PdfException {
      return null;
    }
    if (first > data.length) return null;

    final numbers = List<int?>.filled(count, null);
    final offsets = List<int?>.filled(count, null);
    var cursor = _skipWhitespace(data, 0);
    for (var i = 0; i < count; i++) {
      final number = _readIntAt(data, cursor);
      if (number == null) break;
      cursor = _skipWhitespace(data, _intEnd(data, cursor));
      final offset = _readIntAt(data, cursor);
      if (offset == null) break;
      numbers[i] = number;
      offsets[i] = offset;
      cursor = _skipWhitespace(data, _intEnd(data, cursor));
    }

    final decoded = _ObjectStreamData(data, first, numbers, offsets);
    _objectStreams[container] = decoded;

    return decoded;
  }

  int? _resolveStreamLength(final PdfDictionary dictionary) {
    return _intValue(resolve(dictionary['Length']));
  }

  /// Reads the cross-reference table or stream at [offset], merging
  /// entries into [entries] (existing entries win — they come from a
  /// newer revision). Returns the trailer dictionary when one was
  /// found, null when [offset] holds neither form.
  static PdfDictionary? _readXrefAt(
    final PdfObjectParser parser,
    final int offset,
    final Map<int, _XrefEntry> entries,
  ) {
    if (_keywordAt(parser.bytes, offset, 'xref')) {
      return _readClassicXref(parser, offset, entries);
    }

    final header = parser.objectHeaderAt(offset);
    if (header == null) return null;
    final object = parser.parseAt(header.$3);
    if (object is! PdfStream) return null;

    return _readXrefStream(object, entries);
  }

  static PdfDictionary? _readClassicXref(
    final PdfObjectParser parser,
    final int offset,
    final Map<int, _XrefEntry> entries,
  ) {
    final bytes = parser.bytes;
    var pos = offset + 4; // past 'xref'
    PdfDictionary? trailer;

    while (pos < bytes.length) {
      pos = _skipWhitespace(bytes, pos);
      if (pos >= bytes.length) break;
      if (_keywordAt(bytes, pos, 'trailer')) {
        final trailerObject = parser.parseAt(_skipWhitespace(bytes, pos + 7));
        if (trailerObject is PdfDictionary) trailer = trailerObject;

        return trailer;
      }

      final first = _readIntAt(bytes, pos);
      if (first == null) break;
      pos = _skipWhitespace(bytes, _intEnd(bytes, pos));
      final count = _readIntAt(bytes, pos);
      if (count == null || count < 0) break;
      pos = _skipWhitespace(bytes, _intEnd(bytes, pos));

      for (var i = 0; i < count; i++) {
        final entryOffset = _readIntAt(bytes, pos);
        if (entryOffset == null) break;
        final afterOffset = _skipWhitespace(bytes, _intEnd(bytes, pos));
        final generation = _readIntAt(bytes, afterOffset);
        if (generation == null) break;
        final afterGeneration = _skipWhitespace(bytes, _intEnd(bytes, afterOffset));
        if (afterGeneration >= bytes.length) break;
        final type = bytes[afterGeneration];
        pos = _skipWhitespace(bytes, afterGeneration + 1);

        final number = first + i;
        if (type == 0x6E && !entries.containsKey(number)) {
          entries[number] = _OffsetEntry(entryOffset);
        }
      }
    }

    return trailer;
  }

  static PdfDictionary? _readXrefStream(
    final PdfStream stream,
    final Map<int, _XrefEntry> entries,
  ) {
    final dictionary = stream.dictionary;
    final widths = _intList(dictionary['W']);
    if (widths == null || widths.length != 3) return dictionary;

    Uint8List data;
    try {
      // Filter entries must be direct per the spec; resolve nothing.
      data = decodePdfStream(stream, (final object) => object);
    } on PdfException {
      return dictionary;
    }

    final size = _intValue(dictionary['Size']) ?? 0;
    var index = <int>[0, size];
    final indexObject = dictionary['Index'];
    if (indexObject is PdfArray && indexObject.items.isNotEmpty) {
      final parsed = _intList(indexObject);
      if (parsed != null) index = parsed;
    }

    final rowLength = widths[0] + widths[1] + widths[2];
    if (rowLength == 0) return dictionary;

    var pos = 0;
    for (var pair = 0; pair + 1 < index.length; pair += 2) {
      final first = index[pair];
      final count = index[pair + 1];
      for (var i = 0; i < count; i++) {
        if (pos + rowLength > data.length) break;
        var cursor = pos;
        final type = widths[0] == 0 ? 1 : _readBE(data, cursor, widths[0]);
        cursor += widths[0];
        final field2 = _readBE(data, cursor, widths[1]);
        cursor += widths[1];
        final field3 = _readBE(data, cursor, widths[2]);
        final number = first + i;
        if (!entries.containsKey(number)) {
          if (type == 1 && widths[1] > 0) {
            entries[number] = _OffsetEntry(field2);
          } else if (type == 2) {
            entries[number] = _ObjectStreamEntry(field2, field3);
          }
        }
        pos += rowLength;
      }
    }

    return dictionary;
  }

  static int? _startXrefOffset(final Uint8List bytes) {
    // Search from the tail; %%EOF may repeat in incremental updates.
    final tail = bytes.length < 2048 ? bytes : Uint8List.sublistView(bytes, bytes.length - 2048);
    for (var i = tail.length - 9; i >= 0; i--) {
      if (!_keywordAt(tail, i, 'startxref')) continue;
      final pos = _skipWhitespace(tail, i + 9);

      return _readIntAt(tail, pos);
    }

    return null;
  }

  /// Last-resort recovery for documents whose cross-reference chain
  /// is broken: collects every `num gen obj` header (the last
  /// occurrence of a number wins — incremental updates append newer
  /// revisions). Stream payloads can hold look-alike byte runs; the
  /// entries stay unvalidated until [object] parses them.
  static void _scanObjects(final Uint8List bytes, final Map<int, _XrefEntry> entries) {
    var pos = 0;
    while (pos < bytes.length) {
      final number = _readIntAt(bytes, pos);
      if (number == null) {
        pos++;
        continue;
      }
      final cursor0 = _skipWhitespace(bytes, _intEnd(bytes, pos));
      final generation = _readIntAt(bytes, cursor0);
      if (generation == null) {
        pos++;
        continue;
      }
      final cursor = _skipWhitespace(bytes, _intEnd(bytes, cursor0));
      if (_keywordAt(bytes, cursor, 'obj') && _atDelimiter(bytes, cursor + 3)) {
        entries[number] = _OffsetEntry(pos);
        pos = cursor + 3;
      } else {
        pos++;
      }
    }
  }

  /// Finds the first `trailer` dictionary carrying `/Root`; broken
  /// files may emit several.
  static PdfDictionary? _scanForTrailer(final PdfObjectParser parser) {
    final bytes = parser.bytes;
    var searchFrom = 0;
    PdfDictionary? found;
    while (found == null) {
      final at = _findKeyword(bytes, 'trailer', searchFrom);
      if (at < 0) break;
      final candidate = parser.parseAt(_skipWhitespace(bytes, at + 7));
      if (candidate is PdfDictionary && candidate.containsKey('Root')) found = candidate;
      searchFrom = at + 7;
    }

    return found;
  }

  static bool _atDelimiter(final Uint8List bytes, final int pos) {
    if (pos >= bytes.length) return true;
    final byte = bytes[pos];
    if (byte == 0 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20) {
      return true;
    }

    return byte == 0x3C || byte == 0x28 || byte == 0x2F || byte == 0x5B;
  }

  static int _findKeyword(final Uint8List bytes, final String keyword, final int from) {
    for (var pos = from; pos + keyword.length <= bytes.length; pos++) {
      if (_keywordAt(bytes, pos, keyword)) return pos;
    }

    return -1;
  }

  static bool _keywordAt(final Uint8List bytes, final int offset, final String keyword) {
    if (offset < 0 || offset + keyword.length > bytes.length) return false;
    for (var i = 0; i < keyword.length; i++) {
      if (bytes[offset + i] != keyword.codeUnitAt(i)) return false;
    }

    return true;
  }

  static int _skipWhitespace(final Uint8List bytes, int pos) {
    while (pos < bytes.length) {
      final byte = bytes[pos];
      if (byte == 0 ||
          byte == 0x09 ||
          byte == 0x0A ||
          byte == 0x0C ||
          byte == 0x0D ||
          byte == 0x20) {
        pos++;
      } else {
        break;
      }
    }

    return pos;
  }

  static int? _readIntAt(final Uint8List bytes, final int pos) {
    var end = pos;
    while (end < bytes.length && bytes[end] >= 0x30 && bytes[end] <= 0x39) {
      end++;
    }
    if (end == pos) return null;

    return int.tryParse(String.fromCharCodes(bytes, pos, end));
  }

  static int _intEnd(final Uint8List bytes, final int pos) {
    var end = pos;
    while (end < bytes.length && bytes[end] >= 0x30 && bytes[end] <= 0x39) {
      end++;
    }

    return end;
  }

  static int _readBE(final Uint8List data, final int offset, final int width) {
    var value = 0;
    for (var i = 0; i < width; i++) {
      value = value * 256 + data[offset + i];
    }

    return value;
  }

  static int? _intValue(final PdfObject? object) {
    if (object is PdfNumber) return object.intValue;

    return null;
  }

  static List<int>? _intList(final PdfObject? object) {
    if (object is! PdfArray) return null;
    final out = <int>[];
    for (final item in object.items) {
      if (item is! PdfNumber) return null;
      out.add(item.intValue);
    }

    return out;
  }

  static const int _maxXrefEntries = 4000000;
  static const List<int> _pdfMagic = <int>[0x25, 0x50, 0x44, 0x46];
  static const int _maxPdfPreambleBytes = 1024;
}
