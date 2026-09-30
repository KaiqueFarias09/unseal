import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/images/image_dimensions.dart';
import '../../foundation/images/image_type_sniffer.dart';
import 'bzz_decoder.dart';
import 'djvu_book.dart';
import 'djvu_decode_budget.dart';
import 'djvu_exception.dart';
import 'djvu_layer_compositor.dart';
import 'djvu_outline.dart';
import 'djvu_text.dart';
import 'iw44_decoder.dart';
import 'jb2_decoder.dart';

const _maxInputBytes = 128 * 1024 * 1024;
const _maxPages = 1024;
const _maxChunks = 65536;
const _maxJpegBytes = 32 * 1024 * 1024;
const _maxTextBytes = 8 * 1024 * 1024;
const _maxPagePixels = 100000000;

/// Opens direct BGjp JPEG pages, page-local JB2 masks, and bounded IW44 layers.
///
/// JB2 support covers page-local direct symbols, matched refinements, and local
/// symbol copies. IW44 supports ordered BG44/FG44 chunks and composition with
/// a page-local JB2 selection mask. Hidden text comes from BZZ-compressed
/// TXTz chunks (TXTa stays supported) and a top-level NAVM chunk becomes the
/// document navigation. Shared dictionaries still fail with
/// [DjvuUnsupportedCodecException].
DjvuBook parseDjvuBook(final Uint8List bytes) {
  final document = _DjvuDocument(bytes);
  final pages = <DjvuPage>[];
  final decodeBudget = DjvuDecodeBudget();
  for (final chunk in document.pages) {
    pages.add(document.decodePage(chunk, pages.length + 1, decodeBudget));
  }

  final firstImage = pages.first.image.content;
  final size = imageSize(firstImage);
  final imageType = sniffImageType(firstImage);
  if (size == null || imageType == null) {
    throw const DjvuException('Decoded DjVu page image has an invalid image header.');
  }
  return DjvuBook(
    bytes: bytes,
    pages: pages,
    metadata: BookMetadata(
      format: BookFormat.djvu,
      cover: BookCover(bytes: firstImage, type: imageType, width: size.width, height: size.height),
    ),
    navigation: document.navigation(),
  );
}

/// Validates the container and reads DjVu metadata without decoding image data.
///
/// This path validates page metadata without decoding JPEG or JB2 image data.
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
  _Chunk? _outline;
  _Chunk? _dirm;
  var _dirmCount = 0;
  Map<int, _Chunk>? _components;
  final Map<String, DjvuJb2SharedDictionary> _dictionaries = {};
  final Map<int, DjvuJb2SharedDictionary> _inlineDictionaries = {};
  Map<String, _Chunk>? _resolvedDjbzChunks;
  List<({String id, _Chunk component})>? _resolvedDirmIds;
  final DjvuSharedDictionaryLedger _dictionaryLedger = DjvuSharedDictionaryLedger();
  var _chunkCount = 0;

  /// Builds the document navigation from the top-level NAVM chunk, when the
  /// document carries one. Documents without NAVM keep empty navigation.
  Navigation navigation() {
    final outline = _outline;
    if (outline == null) {
      return Navigation(title: '', navPoints: const <NavPoint>[]);
    }
    return Navigation(
      title: '',
      navPoints: decodeDjvuNavm(Uint8List.sublistView(bytes, outline.data, outline.end)),
    );
  }

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
    // Its compressed names are not needed to order the embedded page FORMs,
    // but the id strings resolve INCL shared-dictionary references lazily.
    _dirm = directory;
    _dirmCount = count;
    final components = <int, _Chunk>{};
    for (final entry in entries.skip(1)) {
      if (entry.id == 'FORM') {
        components[entry.start] = entry;
      } else if (entry.id == 'NAVM' && _outline == null) {
        _outline = entry;
      }
    }
    _components = components;
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

  /// Resolves the shared dictionary an INCL chunk names, decoding the
  /// document's Djbz chunks on first use and caching the symbol lists.
  DjvuJb2SharedDictionary sharedDictionary(final String id) {
    final cached = _dictionaries[id];
    if (cached != null) return cached;
    final djbz = _djbzChunksById()[id];
    if (djbz == null) {
      throw DjvuException('DjVu INCL chunk references an unknown shared dictionary "$id".');
    }
    final dictionary = decodeDjvuJb2Dictionary(
      Uint8List.sublistView(bytes, djbz.data, djbz.end),
      ledger: _dictionaryLedger,
    );
    _dictionaries[id] = dictionary;
    return dictionary;
  }

  /// Maps DIRM component ids to their Djbz chunks, decoding the compressed
  /// DIRM names on first use. Dictionaries live in FORM:DJVI components or
  /// inline inside a page form; both are registered under their component id.
  Map<String, _Chunk> _djbzChunksById() {
    if (_resolvedDjbzChunks != null) return _resolvedDjbzChunks!;
    final resolved = <String, _Chunk>{};
    final directory = _dirm;
    if (directory != null) {
      for (final entry in _dirmIds(directory)) {
        for (final chunk in _children(entry.component.data + 4, entry.component.end)) {
          if (chunk.id == 'Djbz') {
            resolved[entry.id] = chunk;
            break;
          }
        }
      }
    }
    _resolvedDjbzChunks = resolved;
    return resolved;
  }

  /// The document's own component id for [component], when the DIRM names it.
  String? _componentIdOf(final _Chunk component) {
    for (final entry in _dirmIdsCached()) {
      if (entry.component.start == component.start) return entry.id;
    }
    return null;
  }

  List<({String id, _Chunk component})> _dirmIdsCached() {
    final cached = _resolvedDirmIds;
    if (cached != null) return cached;
    final directory = _dirm;
    final resolved = directory == null
        ? const <({String id, _Chunk component})>[]
        : _dirmIds(directory);
    _resolvedDirmIds = resolved;
    return resolved;
  }

  /// Decodes the DIRM name table into component ids in directory order.
  List<({String id, _Chunk component})> _dirmIds(final _Chunk directory) {
    final bundled = bytes[directory.data] & 0x80 != 0;
    final namesStart = directory.data + 3 + (bundled ? _dirmCount * 4 : 0);
    final names = decodeDjvuBzz(
      Uint8List.sublistView(bytes, namesStart, directory.end),
      truncatedMessage: 'Truncated DjVu DIRM names.',
    );
    var position = _dirmCount * 3; // Skip the declared component sizes.
    // The name table groups sizes, then all flag bytes, then the strings.
    final flags = Uint8List(_dirmCount);
    for (var index = 0; index < _dirmCount; index++) {
      flags[index] = names[position++];
    }
    final result = <({String id, _Chunk component})>[];
    for (var index = 0; index < _dirmCount; index++) {
      final id = _zstr(names, (final next) => position = next, position);
      if (flags[index] & 0x80 != 0) position = _skipZstr(names, position);
      if (flags[index] & 0x40 != 0) position = _skipZstr(names, position);
      final offset = data.getUint32(directory.data + 3 + index * 4);
      final component = _components![offset];
      if (component != null) result.add((component: component, id: id));
    }
    return result;
  }

  /// Reads one NUL-terminated string at [start], passing its end to [consume].
  String _zstr(final Uint8List names, final void Function(int) consume, final int start) {
    final end = _skipZstr(names, start);
    consume(end);
    return String.fromCharCodes(names, start, end - 1);
  }

  int _skipZstr(final Uint8List names, final int start) {
    var end = start;
    while (end < names.length && names[end] != 0) {
      end++;
    }
    if (end >= names.length) {
      throw const DjvuException('Truncated DjVu DIRM names.');
    }
    return end + 1;
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
      // DjVuLibre treats unrecognized orientation flags as upright; several
      // independently produced pages use zero for this default orientation.
      _ => 0,
    };
    if (width == 0 || height == 0 || dpi == 0) {
      throw const DjvuException('Invalid DjVu page dimensions or DPI.');
    }
    if (width * height > _maxPagePixels) {
      throw const DjvuException('DjVu page exceeds the 100-megapixel limit.');
    }
    return (width: width, height: height, dpi: dpi, rotation: rotation);
  }

  DjvuPage decodePage(final _Chunk page, final int number, final DjvuDecodeBudget decodeBudget) {
    final info = _pageInfo(page);
    _Chunk? jpeg;
    _Chunk? jb2;
    _Chunk? legacyText;
    _Chunk? compressedText;
    _Chunk? inlineDjbz;
    final inclTargets = <String>[];
    final backgroundChunks = <_Chunk>[];
    final foregroundChunks = <_Chunk>[];
    final unsupported = <String>[];
    for (final chunk in _children(page.data + 4, page.end).skip(1)) {
      switch (chunk.id) {
        case 'BGjp':
          if (jpeg != null) throw const DjvuException('Duplicate DjVu BGjp chunk.');
          jpeg = chunk;
        case 'TXTa':
          if (legacyText != null) throw const DjvuException('Duplicate DjVu TXTa chunk.');
          legacyText = chunk;
        case 'TXTz':
          if (compressedText != null) throw const DjvuException('Duplicate DjVu TXTz chunk.');
          compressedText = chunk;
        case 'Sjbz':
          if (jb2 != null) throw const DjvuException('Duplicate DjVu Sjbz chunk.');
          jb2 = chunk;
        case 'BG44':
          backgroundChunks.add(chunk);
        case 'FG44':
          foregroundChunks.add(chunk);
        case 'Djbz':
          if (inlineDjbz != null) throw const DjvuException('Duplicate DjVu Djbz chunk.');
          inlineDjbz = chunk;
        case 'INCL':
          inclTargets.add(_ascii(chunk.data, chunk.length));
        case 'FGjp':
        case 'Smmr':
          // These chunks replace a supported layer (JPEG foreground, MMR
          // mask); pages that need them stay typed rejections. FGbz only
          // recolors Sjbz blits, so like annotations it is ignored.
          unsupported.add(chunk.id);
      }
    }
    if (jpeg != null &&
        (jb2 != null || backgroundChunks.isNotEmpty || foregroundChunks.isNotEmpty)) {
      unsupported.add('multiple image layers');
    }
    // A mask without a color layer is a valid FGbz page: the ignored color
    // chunk would recolor blits, and the mask renders as black ink instead.
    if (foregroundChunks.isNotEmpty && (backgroundChunks.isEmpty || jb2 == null)) {
      unsupported.add('incomplete IW44 compound layers');
    }
    if (unsupported.isNotEmpty) {
      final codecs = unsupported.toSet().join(', ');
      throw DjvuUnsupportedCodecException(
        'DjVu page $number needs an unsupported image layer: $codecs.',
      );
    }
    if (jpeg == null && jb2 == null && backgroundChunks.isEmpty) {
      throw DjvuUnsupportedCodecException('DjVu page $number has no supported image layer.');
    }

    // The page's shared JB2 dictionary: the component the INCL chunk names,
    // or — when the page carries only its own inline Djbz — the page's own
    // component id. Dictionary symbols accumulate once per document.
    DjvuJb2SharedDictionary? dictionary;
    if (jb2 != null && (inclTargets.isNotEmpty || inlineDjbz != null)) {
      String? target;
      if (inclTargets.isNotEmpty) {
        final distinct = inclTargets.toSet();
        if (distinct.length > 1) {
          throw const DjvuException('DjVu page references multiple shared dictionaries.');
        }
        target = inclTargets.first;
      } else {
        target = _componentIdOf(page);
      }
      if (target != null) {
        dictionary = sharedDictionary(target);
      } else if (inlineDjbz != null) {
        // A single-page document has no DIRM id; its inline dictionary
        // applies directly.
        final inline = inlineDjbz;
        dictionary = _inlineDictionaries.putIfAbsent(inline.start, () {
          return decodeDjvuJb2Dictionary(
            Uint8List.sublistView(bytes, inline.data, inline.end),
            ledger: _dictionaryLedger,
          );
        });
      }
    }

    late final Uint8List imageBytes;
    late final String extension;
    if (jpeg != null) {
      if (jpeg.length == 0 || jpeg.length > _maxJpegBytes) {
        throw const DjvuException('DjVu JPEG page exceeds its size limit or is empty.');
      }
      imageBytes = Uint8List.sublistView(bytes, jpeg.data, jpeg.end);
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
      extension = 'jpg';
    } else if (backgroundChunks.isNotEmpty) {
      final background = decodeDjvuIw44(
        <Uint8List>[
          for (final chunk in backgroundChunks) Uint8List.sublistView(bytes, chunk.data, chunk.end),
        ],
        pageWidth: info.width,
        pageHeight: info.height,
        budget: decodeBudget,
      );
      final foreground = foregroundChunks.isEmpty
          ? null
          : decodeDjvuIw44(
              <Uint8List>[
                for (final chunk in foregroundChunks)
                  Uint8List.sublistView(bytes, chunk.data, chunk.end),
              ],
              pageWidth: info.width,
              pageHeight: info.height,
              budget: decodeBudget,
            );
      DjvuJb2Mask? mask;
      if (jb2 != null) {
        final pagePixels = info.width * info.height;
        decodeBudget.reserve(pixels: pagePixels, rasterBytes: pagePixels);
        mask = decodeDjvuJb2Mask(
          Uint8List.sublistView(bytes, jb2.data, jb2.end),
          expectedWidth: info.width,
          expectedHeight: info.height,
          inherited: dictionary,
        );
      }
      imageBytes = composeDjvuLayersBmp(
        background: DjvuRgbRaster(
          width: background.width,
          height: background.height,
          rgb: background.rgb,
        ),
        foreground: foreground == null
            ? null
            : DjvuRgbRaster(
                width: foreground.width,
                height: foreground.height,
                rgb: foreground.rgb,
              ),
        mask: mask,
        pageWidth: info.width,
        pageHeight: info.height,
        budget: decodeBudget,
      );
      extension = 'bmp';
    } else {
      final rowStride = ((info.width + 31) ~/ 32) * 4;
      decodeBudget.reserve(
        pixels: info.width * info.height,
        rasterBytes: 62 + rowStride * info.height,
      );
      final mask = decodeDjvuJb2Mask(
        Uint8List.sublistView(bytes, jb2!.data, jb2.end),
        expectedWidth: info.width,
        expectedHeight: info.height,
        inherited: dictionary,
      );
      imageBytes = encodeDjvuJb2Bmp(mask);
      extension = 'bmp';
    }
    final image = BinaryFile(
      content: imageBytes,
      name: 'page-$number.$extension',
      type: extension,
      path: 'images/page-$number.$extension',
    );
    // A compressed TXTz chunk carries the same contract as TXTa; the
    // compressed form wins when a page stores both (the corpus has no such
    // page; TXTa is a discouraged legacy encoding).
    final text = compressedText ?? legacyText;
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
    if (chunk.id == 'TXTz') {
      return decodeDjvuTextChunk(Uint8List.sublistView(bytes, chunk.data, chunk.end)).text;
    }
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
