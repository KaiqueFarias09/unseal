import 'dart:typed_data';

import 'bzz_decoder.dart';
import 'djvu_exception.dart';

/// Maximum component files an indirect directory may list.
// The parser's own page cap plus generous room for dictionaries/thumbnails.
const _maxIndirectComponents = 2048;

/// The parsed DIRM of a DjVu document directory.
final class DjvuDirectory {
  /// Creates a parsed directory.
  const DjvuDirectory({required this.bundled, required this.entries, required this.encodedNames});

  /// Whether the document embeds its components (true) or references
  /// external files (false).
  final bool bundled;

  /// Components in directory (reading) order.
  final List<DjvuComponentEntry> entries;

  /// The BZZ-compressed name table carried after the directory header, kept
  /// verbatim so an assembled document preserves component ids for INCL.
  final Uint8List encodedNames;
}

/// One DIRM component entry.
final class DjvuComponentEntry {
  /// Creates a parsed component entry.
  const DjvuComponentEntry({
    required this.id,
    required this.name,
    required this.isPage,
    required this.declaredSize,
  });

  /// The component's DIRM id string.
  final String id;

  /// The component's file name: its `name` string when the entry carries
  /// one, otherwise the id (the spec's practice for indirect documents).
  final String name;

  /// Whether the component represents a page.
  final bool isPage;

  /// The component size the directory declares; zero means unspecified.
  final int declaredSize;
}

/// Parses the DIRM chunk of a DjVu document (DjVu 3 spec, §8.3.2).
///
/// The unencoded header (flags/version byte, 16-bit component count, and the
/// bundled document's offsets) is followed by a BZZ name table: three-byte
/// component sizes, per-component flag bytes, and one to three
/// NUL-terminated strings per component.
DjvuDirectory readDjvuDirectory(final Uint8List bytes) {
  if (bytes.length < 16 || String.fromCharCodes(bytes, 0, 4) != 'AT&T') {
    throw const DjvuException('Missing DjVu AT&T header.');
  }
  final view = ByteData.sublistView(bytes);
  final rootLength = view.getUint32(8);
  if (view.getUint32(4) != 0x464F524D || rootLength < 4 || 12 + rootLength > bytes.length) {
    throw const DjvuException('Invalid DjVu root FORM.');
  }
  final rootEnd = 12 + rootLength;
  final kind = String.fromCharCodes(bytes, 12, 16);
  if (kind != 'DJVM') {
    throw const DjvuException('Single-page DjVu documents have no component directory.');
  }
  var offset = 16;
  while (offset + 8 <= rootEnd) {
    final id = String.fromCharCodes(bytes, offset, offset + 4);
    final length = view.getUint32(offset + 4);
    final dataStart = offset + 8;
    final dataEnd = dataStart + length;
    if (length > rootEnd - dataStart) {
      throw const DjvuException('DjVu chunk exceeds its parent.');
    }
    if (id == 'DIRM') {
      return _parseDirm(Uint8List.sublistView(bytes, dataStart, dataEnd));
    }

    final next = dataEnd == rootEnd ? dataEnd : dataEnd + (length & 1);
    offset = next;
  }
  throw const DjvuException('DjVu multipage document is missing DIRM.');
}

DjvuDirectory _parseDirm(final Uint8List payload) {
  if (payload.length < 3) {
    throw const DjvuException('Truncated DjVu DIRM header.');
  }
  if (payload[0] & 0x7F != 1) {
    throw const DjvuException('Unsupported DjVu DIRM version.');
  }
  final bundled = payload[0] & 0x80 != 0;
  final view = ByteData.sublistView(payload);
  final count = view.getUint16(1);
  if (count > _maxIndirectComponents) {
    throw const DjvuException('DjVu DIRM exceeds the component count limit.');
  }
  if (bundled && payload.length < 3 + count * 4) {
    throw const DjvuException('Invalid DjVu component count or DIRM offsets.');
  }
  final encodedNames = Uint8List.sublistView(payload, 3 + (bundled ? count * 4 : 0));
  final names = decodeDjvuBzz(encodedNames, truncatedMessage: 'Truncated DjVu DIRM names.');

  // The name table groups three-byte component sizes, then all flag bytes,
  // then one to three NUL-terminated strings per component.
  final table = _NameTable(names);
  table.skip(count * 3);
  final flags = <int>[];
  for (var index = 0; index < count; index++) {
    flags.add(table.byte());
  }
  final entries = <DjvuComponentEntry>[];
  for (var index = 0; index < count; index++) {
    final id = table.zstr();
    var name = id;
    if (flags[index] & 0x80 != 0) name = table.zstr();
    if (flags[index] & 0x40 != 0) table.zstr();
    entries.add(
      DjvuComponentEntry(
        id: id,
        name: name,
        isPage: flags[index] & 0x0F == 1,
        declaredSize: table.declaredSize(index),
      ),
    );
  }
  return DjvuDirectory(bundled: bundled, entries: entries, encodedNames: encodedNames);
}

/// Bounded cursor over the BZZ-decompressed DIRM name table.
final class _NameTable {
  _NameTable(this.names);

  final Uint8List names;
  var _position = 0;

  void skip(final int bytes) {
    if (bytes > names.length - _position) {
      throw const DjvuException('Truncated DjVu DIRM names.');
    }
    _position += bytes;
  }

  int byte() {
    if (_position >= names.length) {
      throw const DjvuException('Truncated DjVu DIRM names.');
    }
    return names[_position++];
  }

  String zstr() {
    final start = _position;
    while (_position < names.length && names[_position] != 0) {
      _position++;
    }
    if (_position >= names.length) {
      throw const DjvuException('Truncated DjVu DIRM names.');
    }
    _position++;
    return String.fromCharCodes(names, start, _position - 1);
  }

  /// The declared component size recorded before the flags.
  int declaredSize(final int index) {
    final base = index * 3;
    if (base + 3 > names.length) {
      throw const DjvuException('Truncated DjVu DIRM names.');
    }
    return (names[base] << 16) | (names[base + 1] << 8) | names[base + 2];
  }
}

/// Builds a bundled in-memory DjVu document from an indirect index and its
/// sibling component files.
///
/// The assembled image carries a fresh bundled DIRM (offsets recomputed) and
/// the component FORM bytes verbatim, so the regular bundled parse can treat
/// it like any embedded document. Component names must be plain file names:
/// path separators and parent references are rejected, and declared sizes
/// must match when the directory records them.
Uint8List assembleIndirectDjvu(
  final Uint8List indexBytes,
  final Uint8List Function(String name) loadComponent,
) {
  final directory = readDjvuDirectory(indexBytes);
  if (directory.bundled) {
    throw const DjvuException('DjVu document is already bundled.');
  }
  if (directory.entries.isEmpty) {
    throw const DjvuException('DjVu indirect directory lists no components.');
  }

  final components = <Uint8List>[];
  var total = 0;
  for (final entry in directory.entries) {
    _checkComponentName(entry.name);
    // Component files written by common tools start with the AT&T magic;
    // strip it so the assembled document carries bare FORM chunks.
    var component = loadComponent(entry.name);
    if (component.length >= 4 && String.fromCharCodes(component, 0, 4) == 'AT&T') {
      component = Uint8List.sublistView(component, 4);
    }
    final validForm =
        component.length >= 12 &&
        String.fromCharCodes(component, 0, 4) == 'FORM' &&
        ByteData.sublistView(component).getUint32(4) == component.length - 8;
    if (!validForm) {
      throw DjvuException('DjVu component "${entry.name}" is not a valid FORM chunk.');
    }
    if (entry.declaredSize != 0 && entry.declaredSize != component.length) {
      throw DjvuException(
        'DjVu component "${entry.name}" does not match its declared directory size.',
      );
    }
    total += component.length;
    if (total > 128 * 1024 * 1024) {
      throw const DjvuException('DjVu indirect components exceed the 128 MiB input limit.');
    }
    components.add(component);
  }

  // Layout: AT&T magic, FORM:DJVM header with sub-id, DIRM chunk, then each
  // component FORM verbatim. Offsets point at the component starts. The
  // source name table is carried verbatim so INCL references keep resolving.
  // IFF pads odd chunks to even boundaries, so every component but the last
  // carries a pad byte after an odd length.
  final encodedNames = directory.encodedNames;
  final dirmDataLength = 3 + components.length * 4 + encodedNames.length;
  final directoryChunkLength = 8 + dirmDataLength + (dirmDataLength & 1);
  final offsets = <int>[];
  var componentsLength = 0;
  var cursor = 4 + 8 + 4 + directoryChunkLength;
  for (var i = 0; i < components.length; i++) {
    offsets.add(cursor);
    cursor += components[i].length;
    componentsLength += components[i].length;
    if (components[i].length.isOdd && i != components.length - 1) {
      cursor++;
      componentsLength++;
    }
  }

  final dirm = BytesBuilder();
  dirm.addByte(0x81); // Bundled, version 1.
  final countBytes = ByteData(2)..setUint16(0, components.length);
  dirm.add(countBytes.buffer.asUint8List());
  for (final offset in offsets) {
    final word = ByteData(4)..setUint32(0, offset);
    dirm.add(word.buffer.asUint8List());
  }
  dirm.add(encodedNames);
  final dirmBytes = dirm.toBytes();

  final output = BytesBuilder();
  output.add(const <int>[0x41, 0x54, 0x26, 0x54]); // AT&T
  final formLength = 4 + directoryChunkLength + componentsLength;
  final formHeader = ByteData(8)
    ..setUint32(0, 0x464F524D) // FORM
    ..setUint32(4, formLength);
  output.add(formHeader.buffer.asUint8List());
  output.add(const <int>[0x44, 0x4A, 0x56, 0x4D]); // DJVM
  final dirmHeader = ByteData(8)
    ..setUint32(0, 0x4449524D) // DIRM
    ..setUint32(4, dirmBytes.length);
  output.add(dirmHeader.buffer.asUint8List());
  output.add(dirmBytes);
  if (dirmBytes.length.isOdd) output.addByte(0);
  for (var i = 0; i < components.length; i++) {
    output.add(components[i]);
    if (components[i].length.isOdd && i != components.length - 1) {
      output.addByte(0);
    }
  }
  return output.toBytes();
}

void _checkComponentName(final String name) {
  if (name.isEmpty ||
      name.contains('/') ||
      name.contains(r'\') ||
      name.contains('..') ||
      name.startsWith('.')) {
    throw DjvuException('DjVu indirect component name "$name" is not a plain file name.');
  }
}
