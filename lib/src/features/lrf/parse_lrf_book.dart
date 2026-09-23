import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/files/book_file_factory.dart';
import '../../foundation/images/cover_helpers.dart';
import '../../foundation/text/html_escape.dart';
import '../../foundation/text/xml_encoding.dart';

const _maxInputBytes = 128 * 1024 * 1024;
const _maxObjects = 20000;
const _maxStreamBytes = 32 * 1024 * 1024;
const _maxTotalOutputBytes = 64 * 1024 * 1024;
const _maxInfoBytes = 1024 * 1024;
const _maxPages = 10000;

/// Opens an unencrypted Sony BBeB/LRF book as ordered, reflowable page content.
///
/// The original device-specific typography and absolute positioning are not
/// reproduced. LRX (the encrypted sibling format) is not supported.
DocumentBook parseLrfBook(final Uint8List bytes) => _LrfReader(bytes).read();

/// Reads the embedded LRF metadata without expanding page or image streams.
BookMetadata readLrfMetadata(final Uint8List bytes) => _LrfReader(bytes).metadata;

final class _LrfObject {
  _LrfObject(this.id, this.type, this.offset, this.size);

  final int id;
  final int type;
  final int offset;
  final int size;
  final Map<int, Uint8List> fields = <int, Uint8List>{};
  Uint8List? stream;
  int streamFlags = 0;
}

final class _LrfReader {
  _LrfReader(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length < 0x58 || bytes.length > _maxInputBytes) {
      throw const InvalidBookException('LRF header or file size is invalid.');
    }
    if (bytes[0] != 0x4c ||
        bytes[1] != 0 ||
        bytes[2] != 0x52 ||
        bytes[3] != 0 ||
        bytes[4] != 0x46 ||
        bytes[5] != 0) {
      throw const InvalidBookException('LRF signature is invalid.');
    }
    version = _u16(8);
    if (version <= 800) {
      throw const FormatNotSupportedException('LRF versions 800 and earlier are not supported.');
    }
    rootId = _u32(0x0c);
    objectCount = _safe64(0x10);
    indexOffset = _safe64(0x18);
    xorKey = _u16(0x0a);
    tocId = _u32(0x44);
    if (objectCount < 1 ||
        objectCount > _maxObjects ||
        indexOffset < 0x58 ||
        indexOffset + objectCount * 16 > bytes.length) {
      throw const InvalidBookException('LRF object index is invalid.');
    }
  }

  final Uint8List bytes;
  final ByteData data;
  late final int version;
  late final int rootId;
  late final int objectCount;
  late final int indexOffset;
  late final int xorKey;
  late final int tocId;
  final Map<int, _LrfObject> objects = <int, _LrfObject>{};
  var decodedBytes = 0;

  int _u16(final int offset) {
    _require(offset, 2);
    return data.getUint16(offset, Endian.little);
  }

  int _u32(final int offset) {
    _require(offset, 4);
    return data.getUint32(offset, Endian.little);
  }

  int _safe64(final int offset) {
    _require(offset, 8);
    final low = data.getUint32(offset, Endian.little);
    final high = data.getUint32(offset + 4, Endian.little);
    if (high != 0) {
      throw const InvalidBookException('LRF offset exceeds the safe range.');
    }
    return low;
  }

  void _require(final int offset, final int length) {
    if (offset < 0 || length < 0 || offset > bytes.length - length) {
      throw const InvalidBookException('LRF data is truncated.');
    }
  }

  Uint8List _slice(final int offset, final int length) {
    _require(offset, length);
    return Uint8List.sublistView(bytes, offset, offset + length);
  }

  BookMetadata get metadata {
    final infoStart = version > 800 ? 0x58 : 0x53;
    final compressedSize = _u16(0x4c);
    if (compressedSize < 4 ||
        compressedSize > _maxInfoBytes ||
        infoStart + compressedSize - 4 > bytes.length) {
      throw const InvalidBookException('LRF metadata stream is invalid.');
    }
    final expected = _u32(0x54);
    if (expected > _maxInfoBytes) {
      throw const InvalidBookException('LRF metadata exceeds the size limit.');
    }
    final info = _inflate(_slice(infoStart, compressedSize - 4), expected, _maxInfoBytes);
    XmlDocument document;
    try {
      final source = decodeXmlText(info);
      if (RegExp(r'<!\s*(?:DOCTYPE|ENTITY)', caseSensitive: false).hasMatch(source)) {
        throw const InvalidBookException('LRF metadata declarations are not supported.');
      }
      document = XmlDocument.parse(source);
    } on InvalidBookException {
      rethrow;
    } on Object {
      throw const InvalidBookException('LRF metadata XML is invalid.');
    }
    String? field(final String name) {
      final values = document.findAllElements(name);
      if (values.isEmpty) return null;
      final value = values.first.innerText.trim();
      return value.isEmpty ? null : value;
    }

    BookCover? thumbnail;
    if (version > 800) {
      final size = _u32(0x50);
      if (size > _maxInfoBytes) {
        throw const InvalidBookException('LRF thumbnail exceeds the size limit.');
      }
      if (size > 0) {
        final thumb = binaryFile('lrf/thumbnail', _slice(infoStart + compressedSize - 4, size));
        thumbnail = coverFromBinary(thumb);
      }
    }
    final author = field('Author');
    final language = field('Language');
    return BookMetadata(
      format: BookFormat.lrf,
      title: field('Title'),
      authors: author == null ? const <String>[] : <String>[author],
      languages: language == null ? const <String>[] : <String>[language],
      publisher: field('Publisher'),
      bookProducer: field('Producer'),
      description: field('FreeText'),
      cover: thumbnail,
    );
  }

  DocumentBook read() {
    final bookMetadata = metadata;
    _readIndex();
    final root = objects[rootId];
    if (root == null || root.type != 0x1c) {
      throw const InvalidBookException('LRF root book object is missing.');
    }
    final rootTree = _fieldUint32(_load(root), 0x7b);
    if (rootTree == null) {
      throw const InvalidBookException('LRF page tree is missing.');
    }
    final pageTree = objects[rootTree];
    if (pageTree == null || pageTree.type != 1) {
      throw const InvalidBookException('LRF page tree reference is invalid.');
    }
    final pages = _idList(_load(pageTree).fields[0x5c]);
    if (pages.isEmpty || pages.length > _maxPages) {
      throw const InvalidBookException('LRF page count is invalid.');
    }

    final images = <BinaryFile>[];
    final imagePaths = <int, String>{};
    final html = <TextFile>[];
    final paths = <String>[];
    for (var index = 0; index < pages.length; index++) {
      final page = objects[pages[index]];
      if (page == null || page.type != 2) {
        throw const InvalidBookException('LRF page reference is invalid.');
      }
      final content = _renderPage(_load(page), images, imagePaths);
      final path = 'lrf/page-${index + 1}.html';
      html.add(textFile(path, '<!doctype html><html><body>$content</body></html>'));
      paths.add(path);
    }

    final tocLabels = _readToc();
    final nav = <NavPoint>[];
    for (var index = 0; index < pages.length; index++) {
      final label = tocLabels[pages[index]] ?? 'Page ${index + 1}';
      nav.add(
        NavPoint(
          classAttribute: '',
          id: 'nav-${index + 1}',
          playOrder: '${index + 1}',
          label: label,
          content: paths[index],
        ),
      );
    }
    final cover = bookMetadata.cover == null
        ? firstImageCover(images)
        : binaryFile('lrf/thumbnail', bookMetadata.cover!.bytes);
    return DocumentBook(
      format: BookFormat.lrf,
      metadata: bookMetadata.cover == null
          ? bookMetadata.copyWith(cover: coverFromBinary(cover))
          : bookMetadata,
      files: Files(
        images: images,
        css: <TextFile>[],
        html: html,
        fonts: <BinaryFile>[],
        others: <BinaryFile>[],
      ),
      cover: cover,
      navigation: Navigation(title: bookMetadata.title ?? 'Contents', navPoints: nav),
      order: paths,
    );
  }

  void _readIndex() {
    for (var index = 0; index < objectCount; index++) {
      final cursor = indexOffset + index * 16;
      final id = _u32(cursor);
      final offset = _u32(cursor + 4);
      final size = _u32(cursor + 8);
      if (id == 0 || size < 10 || offset < 0x58 || offset > indexOffset - size) {
        throw const InvalidBookException('LRF object index entry is invalid.');
      }
      if (bytes[offset] != 0 || bytes[offset + 1] != 0xf5 || _u32(offset + 2) != id) {
        throw const InvalidBookException('LRF object header does not match the index.');
      }
      final type = _u16(offset + 6);
      if (objects.containsKey(id)) {
        throw const InvalidBookException('LRF object ID is duplicated.');
      }
      objects[id] = _LrfObject(id, type, offset, size);
    }
  }

  _LrfObject _load(final _LrfObject object) {
    if (object.fields.isNotEmpty || object.stream != null) return object;
    var cursor = object.offset + 8;
    final end = object.offset + object.size;
    var streamSize = -1;
    while (cursor < end) {
      if (cursor + 2 > end || bytes[cursor + 1] != 0xf5) {
        throw const InvalidBookException('LRF object tag is invalid.');
      }
      final tag = bytes[cursor];
      cursor += 2;
      if (tag == 0x01) {
        if (cursor != end) {
          throw const InvalidBookException('LRF object has trailing bytes.');
        }
        return object;
      }
      if (tag == 0x05) {
        if (streamSize < 0 || streamSize > _maxStreamBytes || cursor > end - streamSize - 2) {
          throw const InvalidBookException('LRF object stream size is invalid.');
        }
        final raw = _slice(cursor, streamSize);
        cursor += streamSize;
        if (bytes[cursor] != 0x06 || bytes[cursor + 1] != 0xf5) {
          throw const InvalidBookException('LRF stream terminator is missing.');
        }
        cursor += 2;
        object.stream = _decodeStream(raw, object.streamFlags, object.type);
        continue;
      }
      final size = _tagSize(tag, cursor, end);
      final payload = _slice(cursor, size);
      cursor += size;
      if (tag == 0x04) streamSize = _readU32(payload, 0);
      if (tag == 0x54) object.streamFlags = _readU16(payload, 0);
      object.fields[tag] = payload;
    }
    throw const InvalidBookException('LRF object end tag is missing.');
  }

  int _tagSize(final int tag, final int payloadAt, final int end) {
    if (tag == 0x78) {
      // Emphasis dots: a dword, an embedded UTF-16 string tag, and a word.
      if (payloadAt + 8 > end || bytes[payloadAt + 4] != 0x16 || bytes[payloadAt + 5] != 0xf5) {
        throw const InvalidBookException('LRF emphasis tag is invalid.');
      }
      final length = _u16(payloadAt + 6);
      final size = 10 + length;
      if (payloadAt + size > end) {
        throw const InvalidBookException('LRF emphasis tag is truncated.');
      }
      return size;
    }
    if (tag == 0x0b || tag == 0x5c) {
      if (payloadAt + 2 > end) throw const InvalidBookException('LRF list is truncated.');
      final count = _u16(payloadAt);
      if (count > _maxObjects || payloadAt + 2 + count * 4 > end) {
        throw const InvalidBookException('LRF object list is invalid.');
      }
      return 2 + count * 4;
    }
    if (const <int>{0x16, 0x55, 0x59, 0x5a, 0x5d}.contains(tag)) {
      if (payloadAt + 2 > end) throw const InvalidBookException('LRF string is truncated.');
      final size = _u16(payloadAt);
      if (payloadAt + 2 + size > end) {
        throw const InvalidBookException('LRF string size is invalid.');
      }
      return 2 + size;
    }
    final size = _fixedTagSize(tag);
    if (size == null) {
      throw const FormatNotSupportedException('LRF tag is not supported.');
    }
    if (payloadAt + size > end) {
      throw const InvalidBookException('LRF tag payload is truncated.');
    }
    return size;
  }

  int? _fixedTagSize(final int tag) => switch (tag) {
    0x06 ||
    0x62 ||
    0x63 ||
    0x64 ||
    0x65 ||
    0x66 ||
    0x67 ||
    0x68 ||
    0x69 ||
    0x6a ||
    0x6b ||
    0x6e ||
    0x71 ||
    0x72 ||
    0x81 ||
    0x82 ||
    0xa2 ||
    0xa6 ||
    0xa8 ||
    0xa9 ||
    0xaa ||
    0xab ||
    0xac ||
    0xad ||
    0xae ||
    0xb1 ||
    0xb2 ||
    0xb3 ||
    0xb4 ||
    0xb5 ||
    0xb6 ||
    0xb7 ||
    0xb8 ||
    0xb9 ||
    0xba ||
    0xbb ||
    0xbc ||
    0xbd ||
    0xbe ||
    0xc1 ||
    0xc2 ||
    0xc4 ||
    0xc7 ||
    0xc9 ||
    0xd2 ||
    0xd6 => 0,
    0x00 => 6,
    0x02 ||
    0x03 ||
    0x04 ||
    0x07 ||
    0x08 ||
    0x09 ||
    0x0a ||
    0x17 ||
    0x18 ||
    0x2d ||
    0x34 ||
    0x37 ||
    0x44 ||
    0x45 ||
    0x4b ||
    0x4c ||
    0x53 ||
    0x5b ||
    0x7b ||
    0x7c ||
    0xa1 ||
    0xa7 ||
    0xd8 ||
    0xf2 ||
    0xf3 ||
    0xf5 ||
    0xf6 ||
    0xf7 ||
    0xf8 => 4,
    0x0d ||
    0x0e ||
    0x11 ||
    0x12 ||
    0x13 ||
    0x14 ||
    0x15 ||
    0x19 ||
    0x1a ||
    0x1b ||
    0x1c ||
    0x1d ||
    0x1e ||
    0x21 ||
    0x22 ||
    0x23 ||
    0x24 ||
    0x25 ||
    0x26 ||
    0x27 ||
    0x28 ||
    0x2a ||
    0x2b ||
    0x2c ||
    0x2e ||
    0x31 ||
    0x32 ||
    0x33 ||
    0x35 ||
    0x36 ||
    0x38 ||
    0x39 ||
    0x3a ||
    0x3c ||
    0x3d ||
    0x3e ||
    0x41 ||
    0x42 ||
    0x46 ||
    0x47 ||
    0x48 ||
    0x51 ||
    0x52 ||
    0x54 ||
    0x56 ||
    0x57 ||
    0x58 ||
    0x5e ||
    0x61 ||
    0x6d ||
    0x75 ||
    0x76 ||
    0x77 ||
    0x79 ||
    0x7a ||
    0xc3 ||
    0xc5 ||
    0xc6 ||
    0xc8 ||
    0xca ||
    0xcc ||
    0xd4 ||
    0xda ||
    0xdb ||
    0xdc ||
    0xdd ||
    0xf1 ||
    0xf4 => 2,
    0x29 || 0xf9 => 6,
    0x49 || 0x4a || 0x6c || 0xd9 => 8,
    0x4e || 0xd1 => 12,
    0x73 => 10,
    0xd7 => 14,
    0x4d => 0,
    _ => null,
  };

  Uint8List _decodeStream(final Uint8List raw, final int flags, final int type) {
    if (flags & ~0x3ff != 0) {
      throw const FormatNotSupportedException('LRF stream flags are not supported.');
    }
    final value = Uint8List.fromList(raw);
    if (flags & 0x200 != 0) {
      final initial = xorKey & 0xff;
      final key = initial != 0 && initial <= 0xf0 ? value.length % initial + 0x0f : 0;
      final length = value.length > 0x400 && (type == 0x11 || type == 0x19 || type == 0x17)
          ? 0x400
          : value.length;
      for (var index = 0; index < length; index++) {
        value[index] ^= key;
      }
    }
    if (flags & 0x100 == 0) {
      decodedBytes += value.length;
      if (decodedBytes > _maxTotalOutputBytes) {
        throw const InvalidBookException('LRF decoded content exceeds the size limit.');
      }
      return value;
    }
    if (value.length < 4) {
      throw const InvalidBookException('LRF compressed stream is truncated.');
    }
    final expected = _readU32(value, 0);
    return _inflate(Uint8List.sublistView(value, 4), expected, _maxStreamBytes);
  }

  Uint8List _inflate(final Uint8List compressed, final int expected, final int limit) {
    if (expected > limit) {
      throw const InvalidBookException('LRF expanded content exceeds the size limit.');
    }
    final output = _LimitedOutput(limit);
    try {
      const ZLibDecoder().decodeStream(InputMemoryStream(compressed), output);
    } on InvalidBookException {
      rethrow;
    } on Object {
      throw const InvalidBookException('LRF zlib stream is invalid.');
    }
    if (output.length != expected) {
      throw const InvalidBookException('LRF expanded size differs from its declaration.');
    }
    decodedBytes += output.length;
    if (decodedBytes > _maxTotalOutputBytes) {
      throw const InvalidBookException('LRF decoded content exceeds the size limit.');
    }
    return output.getBytes();
  }

  String _renderPage(
    final _LrfObject page,
    final List<BinaryFile> images,
    final Map<int, String> imagePaths,
  ) {
    final stream = page.stream;
    if (stream == null) throw const InvalidBookException('LRF page has no content stream.');
    final html = StringBuffer();
    var cursor = 0;
    while (cursor < stream.length) {
      if (cursor + 2 > stream.length || stream[cursor + 1] != 0xf5) {
        throw const InvalidBookException('LRF page command is malformed.');
      }
      final tag = stream[cursor];
      cursor += 2;
      if (tag == 0x03) {
        if (cursor + 4 > stream.length) {
          throw const InvalidBookException('LRF page link is truncated.');
        }
        final blockId = _readU32(stream, cursor);
        cursor += 4;
        final block = objects[blockId];
        if (block == null || block.type != 6) {
          throw const InvalidBookException('LRF page block reference is invalid.');
        }
        html.write(_renderBlock(_load(block), images, imagePaths));
      } else {
        final size = _streamTagSize(tag, stream, cursor);
        cursor += size;
      }
    }
    return html.toString();
  }

  String _renderBlock(
    final _LrfObject block,
    final List<BinaryFile> images,
    final Map<int, String> imagePaths,
  ) {
    final stream = block.stream;
    if (stream == null || stream.length < 6 || stream[0] != 3 || stream[1] != 0xf5) {
      throw const InvalidBookException('LRF block has no content reference.');
    }
    final contentId = _readU32(stream, 2);
    final content = objects[contentId];
    if (content == null) throw const InvalidBookException('LRF block content is missing.');
    if (content.type == 10 || content.type == 0x1d) {
      return '<section>${_renderText(_load(content), images, imagePaths)}</section>';
    }
    if (content.type == 12) {
      return '<figure>${_renderImage(contentId, images, imagePaths)}</figure>';
    }
    throw const FormatNotSupportedException('LRF block type is not supported.');
  }

  String _renderImage(
    final int imageId,
    final List<BinaryFile> images,
    final Map<int, String> imagePaths,
  ) {
    final image = objects[imageId];
    if (image == null || image.type != 12) {
      throw const InvalidBookException('LRF image reference is invalid.');
    }
    final streamId = _fieldUint32(_load(image), 0x4c);
    if (streamId == null) throw const InvalidBookException('LRF image stream is missing.');
    final source = objects[streamId];
    if (source == null || source.type != 0x11) {
      throw const InvalidBookException('LRF image stream reference is invalid.');
    }
    final imageStream = _load(source);
    final data = imageStream.stream;
    if (data == null) throw const InvalidBookException('LRF image bytes are missing.');
    final path = imagePaths.putIfAbsent(streamId, () {
      final extension = switch (imageStream.streamFlags & 0xff) {
        0x11 => 'jpg',
        0x12 => 'png',
        0x13 => 'bmp',
        0x14 => 'gif',
        _ => throw const FormatNotSupportedException('LRF image encoding is not supported.'),
      };
      final name = 'lrf/image-$streamId.$extension';
      images.add(binaryFile(name, data));
      return name;
    });
    return '<img src="$path" alt="">';
  }

  String _renderText(
    final _LrfObject textObject,
    final List<BinaryFile> images,
    final Map<int, String> imagePaths,
  ) {
    final stream = textObject.stream;
    if (stream == null) throw const InvalidBookException('LRF text stream is missing.');
    final out = StringBuffer();
    var cursor = 0;
    var paragraph = false;
    var italic = false;
    while (cursor < stream.length) {
      if (cursor + 1 >= stream.length) {
        throw const InvalidBookException('LRF UTF-16 text is truncated.');
      }
      final tag = stream[cursor + 1] == 0xf5 ? stream[cursor] : -1;
      if (tag < 0 || _fixedTagSize(tag) == null && tag != 0x0b && tag != 0x5c) {
        final start = cursor;
        while (cursor + 1 < stream.length) {
          final next = stream[cursor + 1] == 0xf5 ? stream[cursor] : -1;
          if (next >= 0 && (_fixedTagSize(next) != null || next == 0x0b || next == 0x5c)) {
            break;
          }
          cursor += 2;
        }
        out.write(escapeHtml(_utf16(Uint8List.sublistView(stream, start, cursor))));
        continue;
      }
      cursor += 2;
      if (tag == 0xcc) {
        if (cursor + 2 > stream.length) {
          throw const InvalidBookException('LRF text run is truncated.');
        }
        final length = _readU16(stream, cursor);
        cursor += 2;
        if (length.isOdd || cursor + length > stream.length) {
          throw const InvalidBookException('LRF text run length is invalid.');
        }
        out.write(escapeHtml(_utf16(Uint8List.sublistView(stream, cursor, cursor + length))));
        cursor += length;
      } else if (tag == 0xa1) {
        cursor += _streamTagSize(tag, stream, cursor);
        if (paragraph) out.write('</p>');
        out.write('<p>');
        paragraph = true;
      } else if (tag == 0xa2) {
        if (italic) {
          out.write('</em>');
          italic = false;
        }
        if (paragraph) out.write('</p>');
        paragraph = false;
      } else if (tag == 0x81) {
        if (!italic) {
          out.write('<em>');
          italic = true;
        }
      } else if (tag == 0x82) {
        if (italic) {
          out.write('</em>');
          italic = false;
        }
      } else if (tag == 0xd2) {
        out.write('<br>');
      } else if (tag == 0xd1) {
        final size = _streamTagSize(tag, stream, cursor);
        final imageId = _readU32(stream, cursor + 4);
        out.write(_renderImage(imageId, images, imagePaths));
        cursor += size;
      } else {
        cursor += _streamTagSize(tag, stream, cursor);
      }
    }
    if (italic) {
      out.write('</em>');
    }
    if (paragraph) {
      out.write('</p>');
    }
    return out.toString();
  }

  int _streamTagSize(final int tag, final Uint8List stream, final int at) {
    if (tag == 0x0b || tag == 0x5c) {
      if (at + 2 > stream.length) throw const InvalidBookException('LRF stream list is truncated.');
      final size = 2 + _readU16(stream, at) * 4;
      if (at + size > stream.length) {
        throw const InvalidBookException('LRF stream list is invalid.');
      }
      return size;
    }
    final size = _fixedTagSize(tag);
    if (size == null) {
      throw const FormatNotSupportedException('LRF page or text command is not supported.');
    }
    if (at + size > stream.length) {
      throw const InvalidBookException('LRF stream command is truncated.');
    }
    return size;
  }

  Map<int, String> _readToc() {
    if (tocId == 0) return const <int, String>{};
    final toc = objects[tocId];
    if (toc == null || toc.type != 0x1e) {
      throw const InvalidBookException('LRF table of contents reference is invalid.');
    }
    final content = _load(toc).stream;
    if (content == null || content.length < 2) {
      throw const InvalidBookException('LRF table of contents is truncated.');
    }
    final count = _readU16(content, 0);
    if (count > _maxPages) throw const InvalidBookException('LRF TOC exceeds the entry limit.');
    var cursor = 4 * (count + 1);
    if (cursor > content.length) throw const InvalidBookException('LRF TOC index is truncated.');
    final entries = <int, String>{};
    for (var index = 0; index < count; index++) {
      if (cursor + 10 > content.length) {
        throw const InvalidBookException('LRF TOC entry is truncated.');
      }
      final pageId = _readU32(content, cursor);
      final length = _readU16(content, cursor + 8);
      cursor += 10;
      if (length.isOdd || cursor + length > content.length) {
        throw const InvalidBookException('LRF TOC label length is invalid.');
      }
      entries[pageId] = _utf16(Uint8List.sublistView(content, cursor, cursor + length));
      cursor += length;
    }
    return entries;
  }

  List<int> _idList(final Uint8List? payload) {
    if (payload == null || payload.length < 2) return const <int>[];
    final count = _readU16(payload, 0);
    if (payload.length != 2 + count * 4) {
      throw const InvalidBookException('LRF object list is invalid.');
    }
    return <int>[for (var i = 0; i < count; i++) _readU32(payload, 2 + i * 4)];
  }

  int? _fieldUint32(final _LrfObject object, final int tag) {
    final value = object.fields[tag];
    return value == null ? null : _readU32(value, 0);
  }

  int _readU16(final Uint8List source, final int at) {
    if (at < 0 || at + 2 > source.length) {
      throw const InvalidBookException('LRF field is truncated.');
    }
    return ByteData.sublistView(source).getUint16(at, Endian.little);
  }

  int _readU32(final Uint8List source, final int at) {
    if (at < 0 || at + 4 > source.length) {
      throw const InvalidBookException('LRF field is truncated.');
    }
    return ByteData.sublistView(source).getUint32(at, Endian.little);
  }

  String _utf16(final Uint8List source) {
    if (source.length.isOdd) {
      throw const InvalidBookException('LRF UTF-16 text has an odd byte count.');
    }
    final units = <int>[];
    for (var index = 0; index < source.length; index += 2) {
      units.add(source[index] | (source[index + 1] << 8));
    }
    return String.fromCharCodes(units).replaceAll('\u0000', '');
  }
}

final class _LimitedOutput extends OutputMemoryStream {
  _LimitedOutput(this.limit) : super(size: 0);

  final int limit;

  void _check(final int count) {
    if (count < 0 || length > limit - count) {
      throw const InvalidBookException('LRF expanded content exceeds the size limit.');
    }
  }

  @override
  void writeByte(final int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(final List<int> bytes, {final int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeBackReference(final int distance, final int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }

  @override
  void writeStream(final InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }
}
