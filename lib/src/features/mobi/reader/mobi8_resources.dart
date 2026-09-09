import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../../../foundation/images/image_type_sniffer.dart';
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
    MobiContainer? container;

    for (final (start, end) in resourceOffsets) {
      for (var i = start; i < end && i < pdb.count; i++) {
        final fnameIdx = i - start + 1;
        final data = pdb.record(i);
        final type = data.length >= 4 ? String.fromCharCodes(data.sublist(0, 4)) : '';
        String? href;

        if (const {
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
            }.contains(type) ||
            _isUnknownMarker(data)) {
          // Ignored record kinds.
        } else if (type == 'FONT') {
          final font = decodeFontRecord(data);
          final name = 'font${fnameIdx.toString().padLeft(5, '0')}.${font.extension}';
          href = name;
          fonts.add(BinaryFile(content: font.data, name: name, type: font.extension, path: name));
        } else if (type == 'CONT') {
          container = _hasMagic(data, 'CONTBOUNDARY') ? null : MobiContainer(data);
        } else if (type == 'CRES') {
          if (container != null) {
            final image = container.loadImage(data);
            if (image != null) {
              final sniffed = sniffImageType(image)!;
              final name =
                  'image${container.resourceIndex.toString().padLeft(5, '0')}.${sniffed.fileExtension}';
              href = name;
              images.add(
                BinaryFile(content: image, name: name, type: sniffed.fileExtension, path: name),
              );
            }
          }
        } else if (_isPlaceholder(data) && container != null) {
          container.resourceIndex += 1;
        } else if (container == null) {
          final sniffed = sniffImageType(data);
          if (sniffed != null) {
            final name = 'image${fnameIdx.toString().padLeft(5, '0')}.${sniffed.fileExtension}';
            href = name;
            images.add(
              BinaryFile(content: data, name: name, type: sniffed.fileExtension, path: name),
            );
          }
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

bool _hasMagic(final Uint8List data, final String magic) {
  if (data.length < magic.length) return false;
  for (var i = 0; i < magic.length; i++) {
    if (data[i] != magic.codeUnitAt(i)) return false;
  }

  return true;
}

bool _isUnknownMarker(final Uint8List data) =>
    data.length >= 4 && data[0] == 0xE9 && data[1] == 0x8E && data[2] == 0x0D && data[3] == 0x0A;

bool _isPlaceholder(final Uint8List data) =>
    data.length == 4 && data[0] == 0xA0 && data[1] == 0xA0 && data[2] == 0xA0 && data[3] == 0xA0;
