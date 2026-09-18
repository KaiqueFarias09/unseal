import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/images/image_type_sniffer.dart';
import '../codec/mobi_byte_search.dart';
import '../header/pdb_header.dart';
import 'mobi_container.dart';
import 'mobi_font.dart';

/// Images, fonts, and embed-index mapping extracted from KF8 records.
final class Mobi8Resources {
  /// Creates an extracted KF8 resource result.
  const Mobi8Resources({required this.images, required this.fonts, required this.resourceMap});

  /// Extracts all supported resources from the PDB [resourceOffsets].
  factory Mobi8Resources.extract({
    required final PdbRecordAccess pdb,
    required final List<(int, int)> resourceOffsets,
  }) {
    final images = <BinaryFile>[];
    final fonts = <BinaryFile>[];
    final resourceMap = <String?>[];
    for (final (start, end) in resourceOffsets) {
      MobiContainer? container;
      for (var i = start; i < end && i < pdb.count; i++) {
        final resourceNumber = resourceMap.length + 1;
        final data = pdb.record(i);
        final type = data.length >= 4 ? String.fromCharCodes(data.sublist(0, 4)) : '';
        final href = _extractResource(
          type: type,
          data: data,
          resourceNumber: resourceNumber,
          container: container,
          images: images,
          fonts: fonts,
        );

        if (type == 'CONT') {
          container = hasAsciiAt(data, 'CONTBOUNDARY') ? null : MobiContainer(data);
        }

        resourceMap.add(href);
      }
    }

    return Mobi8Resources(images: images, fonts: fonts, resourceMap: resourceMap);
  }

  /// Decoded raster resources in record order.
  final List<BinaryFile> images;

  /// Decoded embedded fonts in record order.
  final List<BinaryFile> fonts;

  /// One-based Kindle embed index to output resource name.
  final List<String?> resourceMap;
}

String? _extractResource({
  required final String type,
  required final Uint8List data,
  required final int resourceNumber,
  required final MobiContainer? container,
  required final List<BinaryFile> images,
  required final List<BinaryFile> fonts,
}) {
  const ignoredRecordTypes = <String>{
    'FLIS',
    'FCIS',
    'SRCS',
    'BOUN',
    'FDST',
    'DATP',
    'AUDI',
    'VIDE',
    'RESC',
    'CMET',
    'PAGE',
  };
  if (type == 'CONT' || ignoredRecordTypes.contains(type) || _isUnknownMarker(data)) {
    return null;
  }

  if (type == 'FONT') {
    final font = decodeFontRecord(data);
    final name = _resourceName('font', resourceNumber, font.extension);
    fonts.add(BinaryFile(content: font.data, name: name, type: font.extension, path: name));

    return name;
  }

  if (type == 'CRES') {
    if (container == null) return null;

    final image = container.loadImage(data);
    if (image == null) return null;

    return _addImage(image, resourceNumber, images);
  }

  if (_isPlaceholder(data) && container != null) {
    container.resourceIndex += 1;

    return null;
  }

  if (container == null) return _addImage(data, resourceNumber, images);

  return null;
}

String? _addImage(final Uint8List data, final int resourceNumber, final List<BinaryFile> images) {
  final sniffed = sniffImageType(data);
  if (sniffed == null) return null;

  final name = _resourceName('image', resourceNumber, sniffed.fileExtension);
  images.add(BinaryFile(content: data, name: name, type: sniffed.fileExtension, path: name));

  return name;
}

String _resourceName(final String kind, final int number, final String extension) {
  return '$kind${number.toString().padLeft(5, '0')}.$extension';
}

bool _isUnknownMarker(final Uint8List data) {
  return data.length >= 4 &&
      data[0] == 0xE9 &&
      data[1] == 0x8E &&
      data[2] == 0x0D &&
      data[3] == 0x0A;
}

bool _isPlaceholder(final Uint8List data) {
  return data.length == 4 &&
      data[0] == 0xA0 &&
      data[1] == 0xA0 &&
      data[2] == 0xA0 &&
      data[3] == 0xA0;
}
