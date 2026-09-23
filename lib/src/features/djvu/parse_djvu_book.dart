import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'djvu_book.dart';
import 'djvu_exception.dart';

const _maxInputBytes = 128 * 1024 * 1024;
const _maxPages = 1024;
const _maxChunks = 65536;
const _maxJpegBytes = 32 * 1024 * 1024;
const _maxTextBytes = 8 * 1024 * 1024;
const _maxPagePixels = 100000000;

/// Opens DjVu pages that use the specification's direct BGjp JPEG encoding.
///
/// The common JB2 and IW44 image codecs are recognized but currently fail with
/// [DjvuUnsupportedCodecException]. The parser never reports an invisible page
/// as successfully opened.
DjvuBook parseDjvuBook(final Uint8List bytes) {
  final document = _DjvuDocument(bytes);
  final pages = <DjvuPage>[];
  for (final chunk in document.pages) {
    pages.add(document.decodePage(chunk, pages.length + 1));
  }

  final firstImage = pages.first.image.content;
  final size = imageSize(firstImage);
  return DjvuBook(
    bytes: bytes,
    pages: pages,
    metadata: BookMetadata(
      format: BookFormat.djvu,
      cover: BookCover(
        bytes: firstImage,
        type: ImageType.jpeg,
        width: size?.width,
        height: size?.height,
      ),
    ),
  );
}

/// Validates the container and reads DjVu metadata without decoding image data.
///
/// This path also accepts valid pages whose JB2/IW44 image codecs are not yet
/// supported by [parseDjvuBook].
BookMetadata readDjvuMetadata(final Uint8List bytes) {
  _DjvuDocument(bytes);
  return const BookMetadata(format: BookFormat.djvu);
}

final class _Chunk {
  const _Chunk(this.id, this.start, this.data, this.end, this.next);

  final String id;
  final int start;
  final int data;
  final int end;
  final int next;
  int get length => end - data;
}

final class _DjvuDocument {
  _DjvuDocument(this.bytes) : data = ByteData.sublistView(bytes) {
    if (bytes.length > _maxInputBytes) {
      throw const DjvuException('DjVu file exceeds the 128 MiB input limit.');
    }
    if (bytes.length < 16 || _ascii(0, 4) != 'AT&T') {
      throw const DjvuException('Missing DjVu AT&T header.');
    }
    final root = _chunk(4, bytes.length);
    if (root.id != 'FORM' || root.length < 4 || root.next != bytes.length) {
      throw const DjvuException('Invalid DjVu root FORM.');
    }

    final kind = _ascii(root.data, 4);
    if (kind == 'DJVU') {
      pages = <_Chunk>[root];
    } else if (kind == 'DJVM') {
      pages = _bundledPages(root);
    } else {
      throw const DjvuException('Unsupported DjVu root FORM type.');
    }
    if (pages.isEmpty) throw const DjvuException('DjVu document has no pages.');
    if (pages.length > _maxPages) throw const DjvuException('DjVu exceeds the 1024-page limit.');
    for (final page in pages) {
      _pageInfo(page);
    }
  }

  final Uint8List bytes;
  final ByteData data;
  late final List<_Chunk> pages;
  var _chunkCount = 0;

  List<_Chunk> _bundledPages(final _Chunk root) {
    final entries = _children(root.data + 4, root.end);
    if (entries.isEmpty || entries.first.id != 'DIRM') {
      throw const DjvuException('DjVu multipage document is missing DIRM.');
    }
    final directory = entries.first;
    if (directory.length < 3) throw const DjvuException('Truncated DjVu DIRM header.');
    if (bytes[directory.data] & 0x7F != 1) {
      throw const DjvuException('Unsupported DjVu DIRM version.');
    }
    if (bytes[directory.data] & 0x80 == 0) {
      throw const DjvuUnsupportedCodecException(
        'Indirect DjVu documents require external component files.',
      );
    }
    final count = data.getUint16(directory.data + 1);
    if (count == 0 || count > _maxPages + 1024 || directory.length < 3 + count * 4) {
      throw const DjvuException('Invalid DjVu component count or DIRM offsets.');
    }

    // DIRM lists component offsets, including shared resources and thumbnails.
    // Its compressed names are not needed to order the embedded page FORMs.
    final components = <int, _Chunk>{};
    for (final entry in entries.skip(1)) {
      if (entry.id == 'FORM') components[entry.start] = entry;
    }
    final result = <_Chunk>[];
    final used = <int>{};
    for (var index = 0; index < count; index++) {
      final offset = data.getUint32(directory.data + 3 + index * 4);
      final component = components[offset];
      if (component == null || !used.add(offset)) {
        throw const DjvuException('DIRM points outside a unique embedded component.');
      }
      if (component.length < 4) {
        throw const DjvuException('Truncated DjVu component FORM type.');
      }
      final type = _ascii(component.data, 4);
      if (type == 'DJVU') result.add(component);
    }
    return result;
  }

  ({int width, int height, int dpi, int rotation}) _pageInfo(final _Chunk page) {
    final entries = _children(page.data + 4, page.end);
    if (entries.isEmpty || entries.first.id != 'INFO' || entries.first.length < 10) {
      throw const DjvuException('DjVu page must begin with a ten-byte INFO chunk.');
    }
    final info = entries.first.data;
    final width = data.getUint16(info);
    final height = data.getUint16(info + 2);
    final dpi = data.getUint16(info + 6, Endian.little);
    final rotation = switch (bytes[info + 9] & 7) {
      1 => 0,
      5 => 90,
      2 => 180,
      6 => 270,
      _ => throw const DjvuException('Invalid DjVu page rotation.'),
    };
    if (width == 0 || height == 0 || dpi == 0) {
      throw const DjvuException('Invalid DjVu page dimensions or DPI.');
    }
    if (width * height > _maxPagePixels) {
      throw const DjvuException('DjVu page exceeds the 100-megapixel limit.');
    }
    return (width: width, height: height, dpi: dpi, rotation: rotation);
  }

  DjvuPage decodePage(final _Chunk page, final int number) {
    final info = _pageInfo(page);
    _Chunk? jpeg;
    _Chunk? text;
    final unsupported = <String>[];
    for (final chunk in _children(page.data + 4, page.end).skip(1)) {
      switch (chunk.id) {
        case 'BGjp':
          if (jpeg != null) throw const DjvuException('Duplicate DjVu BGjp chunk.');
          jpeg = chunk;
        case 'TXTa':
          if (text != null) throw const DjvuException('Duplicate DjVu TXTa chunk.');
          text = chunk;
        case 'Sjbz':
        case 'Djbz':
        case 'BG44':
        case 'FG44':
        case 'FGjp':
        case 'FGbz':
        case 'Smmr':
        case 'INCL':
          unsupported.add(chunk.id);
      }
    }
    if (unsupported.isNotEmpty || jpeg == null) {
      final codecs = unsupported.isEmpty ? 'no BGjp image' : unsupported.toSet().join(', ');
      throw DjvuUnsupportedCodecException(
        'DjVu page $number needs an unsupported image layer: $codecs.',
      );
    }
    if (jpeg.length == 0 || jpeg.length > _maxJpegBytes) {
      throw const DjvuException('DjVu JPEG page exceeds its size limit or is empty.');
    }
    final imageBytes = Uint8List.sublistView(bytes, jpeg.data, jpeg.end);
    final type = sniffImageType(imageBytes);
    final dimensions = imageSize(imageBytes);
    if (type?.fileExtension != 'jpg' ||
        dimensions == null ||
        imageBytes.length < 2 ||
        imageBytes[imageBytes.length - 2] != 0xFF ||
        imageBytes.last != 0xD9) {
      throw const DjvuException('DjVu BGjp chunk does not contain a valid JPEG header.');
    }
    if (dimensions.width == 0 ||
        dimensions.height == 0 ||
        dimensions.width > info.width ||
        dimensions.height > info.height) {
      throw const DjvuException('DjVu JPEG dimensions exceed the page dimensions.');
    }
    final image = BinaryFile(
      content: imageBytes,
      name: 'page-$number.jpg',
      type: 'jpg',
      path: 'images/page-$number.jpg',
    );
    return DjvuPage(
      width: info.width,
      height: info.height,
      dpi: info.dpi,
      rotation: info.rotation,
      image: image,
      text: text == null ? '' : _readText(text),
    );
  }

  String _readText(final _Chunk chunk) {
    if (chunk.length < 3 || chunk.length > _maxTextBytes) {
      throw const DjvuException('DjVu TXTa chunk exceeds its size limit or is truncated.');
    }
    final length = bytes[chunk.data] << 16 | bytes[chunk.data + 1] << 8 | bytes[chunk.data + 2];
    if (length + 4 > chunk.length || bytes[chunk.data + 3 + length] != 1) {
      throw const DjvuException('Truncated or unsupported DjVu TXTa text.');
    }
    try {
      return utf8.decode(Uint8List.sublistView(bytes, chunk.data + 3, chunk.data + 3 + length));
    } on FormatException {
      throw const DjvuException('DjVu TXTa text is not valid UTF-8.');
    }
  }

  List<_Chunk> _children(final int start, final int end) {
    final result = <_Chunk>[];
    var offset = start;
    while (offset < end) {
      final chunk = _chunk(offset, end);
      result.add(chunk);
      offset = chunk.next;
    }
    if (offset != end) throw const DjvuException('DjVu chunk padding exceeds its parent.');
    return result;
  }

  _Chunk _chunk(final int start, final int limit) {
    if (++_chunkCount > _maxChunks) {
      throw const DjvuException('DjVu exceeds the chunk count limit.');
    }
    if (start + 8 > limit) throw const DjvuException('Truncated DjVu chunk header.');
    final length = data.getUint32(start + 4);
    final dataStart = start + 8;
    if (length > limit - dataStart) throw const DjvuException('DjVu chunk exceeds its parent.');
    final end = dataStart + length;
    // A final odd-sized chunk needs no trailing pad because no next chunk
    // must be aligned. Real encoders omit that last byte.
    final next = end == limit ? end : end + (length & 1);
    if (next > limit) throw const DjvuException('Truncated DjVu chunk padding.');
    return _Chunk(_ascii(start, 4), start, dataStart, end, next);
  }

  String _ascii(final int start, final int length) =>
      String.fromCharCodes(bytes, start, start + length);
}
