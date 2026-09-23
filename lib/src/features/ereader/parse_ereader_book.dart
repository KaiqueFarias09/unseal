import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/text/xml_encoding.dart';
import '../mobi/header/pdb_header.dart';
import '../palmdoc/palmdoc_compression.dart';
import 'ereader_pml.dart';

const _maxBookBytes = 64 * 1024 * 1024;
const _maxRecords = 8192;
const _maxCompressedRecordBytes = 8192;
const _maxDecodedRecordBytes = 65535;

/// Parses an unencrypted eReader PDB into readable HTML and metadata.
///
/// A reading-oriented PML subset preserves headings, inline emphasis, local
/// links, and PNG images. Complex page layout remains outside this projection.
DocumentBook parseEreaderBook(final Uint8List bytes) {
  final source = _EreaderSource.read(bytes);
  final output = BytesBuilder(copy: false);
  var total = 0;
  for (var index = 1; index < source.nonTextRecord; index++) {
    final decoded = source.decodeTextRecord(index);
    total += decoded.length;
    if (total > _maxBookBytes) {
      throw const InvalidBookException('eReader text exceeds the 64 MiB limit.');
    }
    output.add(decoded);
  }

  final pml = decodeXmlTextAs(output.takeBytes(), XmlEncoding.cp1252);
  final images = source.images();
  final imagePaths = <String, String>{for (final image in images) image.name: image.path};
  final rendered = renderEreaderPml(pml, imagePaths: imagePaths);
  final supplemental = source.supplementalHtml();
  final htmlContent = supplemental.isEmpty
      ? rendered.html
      : rendered.html.replaceFirst('</body>', '$supplemental</body>');
  if (htmlContent.length > 2 * _maxBookBytes) {
    throw const InvalidBookException('Rendered eReader HTML exceeds the 128 MiB limit.');
  }
  final metadata = source.metadata();
  final htmlPath = _documentPath(source.pdb.name);
  final navigation = rendered.headings.isEmpty
      ? <NavPoint>[
          NavPoint(
            classAttribute: '',
            id: 'nav-1',
            playOrder: '1',
            label: metadata.title ?? 'Document',
            content: htmlPath,
          ),
        ]
      : <NavPoint>[
          for (var i = 0; i < rendered.headings.length; i++)
            NavPoint(
              classAttribute: '',
              id: 'nav-${i + 1}',
              playOrder: '${i + 1}',
              label: rendered.headings[i].label,
              content: '$htmlPath#${rendered.headings[i].id}',
            ),
        ];
  return DocumentBook(
    format: BookFormat.ereader,
    files: Files(
      images: images,
      css: const <TextFile>[],
      html: <TextFile>[
        TextFile(name: htmlPath, type: 'html', path: htmlPath, content: htmlContent),
      ],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: Navigation(title: metadata.title ?? 'Contents', navPoints: navigation),
    order: <String>[htmlPath],
  );
}

/// Reads eReader title and author without expanding any text record.
BookMetadata readEreaderMetadata(final Uint8List bytes) => _EreaderSource.read(bytes).metadata();

final class _EreaderSource {
  const _EreaderSource(
    this.pdb,
    this.compression,
    this.nonTextRecord,
    this.metadataRecord,
    this.imageStart,
    this.imageCount,
    this.footnoteStart,
    this.footnoteCount,
    this.sidebarStart,
    this.sidebarCount,
  );

  final PdbHeader pdb;
  final int compression;
  final int nonTextRecord;
  final int? metadataRecord;
  final int imageStart;
  final int imageCount;
  final int footnoteStart;
  final int footnoteCount;
  final int sidebarStart;
  final int sidebarCount;

  static _EreaderSource read(final Uint8List bytes) {
    if (bytes.length > _maxBookBytes) {
      throw const InvalidBookException('eReader PDB exceeds the 64 MiB input limit.');
    }
    final pdb = PdbHeader.parse(bytes);
    if (pdb.ident != 'PNRDPPRS' || pdb.count < 2 || pdb.count > _maxRecords) {
      throw const InvalidBookException('Invalid eReader PDB identity or record count.');
    }
    final header = pdb.record(0);
    final view = ByteData.sublistView(header);
    if (header.length == 132) {
      final compression = view.getUint16(0);
      if (compression == 260 || compression == 272) {
        throw const DrmProtectedException('DRM-protected eReader books are not supported.');
      }
      if (compression != 2 && compression != 10) {
        throw const FormatNotSupportedException('Unsupported eReader compression.');
      }
      final nonTextRecord = view.getUint16(12);
      if (nonTextRecord < 2 || nonTextRecord > pdb.count) {
        throw const InvalidBookException('Invalid eReader text record range.');
      }
      final hasMetadata = view.getUint16(24) == 1;
      final metadataRecord = hasMetadata ? view.getUint16(44) : null;
      if (metadataRecord != null &&
          (metadataRecord < nonTextRecord || metadataRecord >= pdb.count)) {
        throw const InvalidBookException('Invalid eReader metadata record.');
      }
      final imageCount = view.getUint16(20);
      final imageStart = view.getUint16(40);
      final footnoteCount = view.getUint16(28);
      final sidebarCount = view.getUint16(30);
      final footnoteStart = view.getUint16(48);
      final sidebarStart = view.getUint16(50);
      if (imageCount > 0 && (imageStart < nonTextRecord || imageStart + imageCount > pdb.count)) {
        throw const InvalidBookException('Invalid eReader image record range.');
      }
      if ((footnoteCount > 0 &&
              (footnoteStart < nonTextRecord || footnoteStart + footnoteCount > pdb.count)) ||
          (sidebarCount > 0 &&
              (sidebarStart < nonTextRecord || sidebarStart + sidebarCount > pdb.count))) {
        throw const InvalidBookException('Invalid eReader note record range.');
      }
      return _EreaderSource(
        pdb,
        compression,
        nonTextRecord,
        metadataRecord,
        imageStart,
        imageCount,
        footnoteStart,
        footnoteCount,
        sidebarStart,
        sidebarCount,
      );
    }
    if (header.length == 202 || header.length == 116) {
      final version = view.getUint16(0);
      if (version != 2 && version != 4) {
        throw const FormatNotSupportedException('Unsupported legacy eReader version.');
      }
      final nonTextRecord = view.getUint16(8);
      if (nonTextRecord < 2 || nonTextRecord > pdb.count) {
        throw const InvalidBookException('Invalid eReader text record range.');
      }
      return _EreaderSource(pdb, -1, nonTextRecord, null, 0, 0, 0, 0, 0, 0);
    }
    throw const FormatNotSupportedException('Unsupported eReader header layout.');
  }

  Uint8List decodeTextRecord(final int index) {
    final record = pdb.record(index);
    if (record.length > _maxCompressedRecordBytes) {
      throw const InvalidBookException('eReader text record exceeds its compressed input limit.');
    }
    if (compression == -1) {
      final unmasked = Uint8List.fromList(<int>[for (final byte in record) byte ^ 0xA5]);
      return decompressPalmdocRecord(unmasked, maxOutputBytes: _maxDecodedRecordBytes);
    }
    if (compression == 2) {
      return decompressPalmdocRecord(record, maxOutputBytes: _maxDecodedRecordBytes);
    }
    try {
      // An 8 KiB compressed record bounds transient expansion in the web
      // decoder; the decoded result is checked before retaining it.
      final decoded = const ZLibDecoder().decodeBytes(record, verify: true);
      if (decoded.length > _maxDecodedRecordBytes) {
        throw const InvalidBookException('eReader text record exceeds 65535 decoded bytes.');
      }
      return decoded;
    } on FormatException {
      throw const InvalidBookException('Invalid eReader zlib text record.');
    }
  }

  List<BinaryFile> images() {
    final images = <BinaryFile>[];
    final names = <String>{};
    for (var index = imageStart; index < imageStart + imageCount; index++) {
      final record = pdb.record(index);
      if (record.length < 70 ||
          record.length > 65505 ||
          record[0] != 0x50 ||
          record[1] != 0x4e ||
          record[2] != 0x47 ||
          record[3] != 0x20) {
        throw const InvalidBookException('Invalid eReader PNG image record.');
      }
      var end = 4;
      while (end < 36 && record[end] != 0) {
        end++;
      }
      final name = decodeXmlTextAs(Uint8List.sublistView(record, 4, end), XmlEncoding.cp1252);
      if (name.isEmpty ||
          !RegExp(r'^[A-Za-z0-9_.-]+\.png$', caseSensitive: false).hasMatch(name) ||
          !names.add(name)) {
        throw const InvalidBookException('Invalid or duplicate eReader image name.');
      }
      final data = Uint8List.sublistView(record, 62);
      if (data.length < 8 ||
          data[0] != 0x89 ||
          data[1] != 0x50 ||
          data[2] != 0x4e ||
          data[3] != 0x47 ||
          data[4] != 0x0d ||
          data[5] != 0x0a ||
          data[6] != 0x1a ||
          data[7] != 0x0a) {
        throw const InvalidBookException('Invalid eReader PNG image payload.');
      }
      images.add(BinaryFile(content: data, name: name, type: 'png', path: 'images/$name'));
    }
    return images;
  }

  String supplementalHtml() {
    final html = StringBuffer();
    var decodedBytes = 0;
    for (final section in <(String, int, int)>[
      ('fn', footnoteStart, footnoteCount),
      ('sb', sidebarStart, sidebarCount),
    ]) {
      final (prefix, start, count) = section;
      if (count <= 1) continue;
      final idsRecord = pdb.record(start);
      if (idsRecord.length > 64 * 1024) {
        throw const InvalidBookException('eReader note ID record exceeds 64 KiB.');
      }
      final ids = decodeXmlTextAs(
        idsRecord,
        XmlEncoding.cp1252,
      ).split('\u0000').where((id) => id.isNotEmpty).toList();
      for (var index = 1; index < count; index++) {
        final text = decodeTextRecord(start + index);
        decodedBytes += text.length;
        if (decodedBytes > _maxBookBytes) {
          throw const InvalidBookException('eReader notes exceed the 64 MiB limit.');
        }
        final name = index - 1 < ids.length ? ids[index - 1] : 'note-$index';
        final id = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$').hasMatch(name) ? name : 'note-$index';
        final rendered = renderEreaderPml(
          decodeXmlTextAs(text, XmlEncoding.cp1252),
          imagePaths: const <String, String>{},
        ).html;
        final bodyStart = rendered.indexOf('<body>') + '<body>'.length;
        final bodyEnd = rendered.lastIndexOf('</body>');
        html.write('<aside id="$prefix-$id">${rendered.substring(bodyStart, bodyEnd)}</aside>');
      }
    }
    return html.toString();
  }

  BookMetadata metadata() {
    String? title;
    final authors = <String>[];
    String? publisher;
    String? rights;
    String? isbn;
    final index = metadataRecord;
    if (index != null) {
      final record = pdb.record(index);
      if (record.length > 64 * 1024) {
        throw const InvalidBookException('eReader metadata record exceeds 64 KiB.');
      }
      final parts = decodeXmlTextAs(record, XmlEncoding.cp1252).split('\u0000');
      if (parts.isNotEmpty && parts[0].trim().isNotEmpty) title = parts[0].trim();
      if (parts.length > 1 && parts[1].trim().isNotEmpty) authors.add(parts[1].trim());
      if (parts.length > 2 && parts[2].trim().isNotEmpty) rights = parts[2].trim();
      if (parts.length > 3 && parts[3].trim().isNotEmpty) publisher = parts[3].trim();
      if (parts.length > 4 && parts[4].trim().isNotEmpty) isbn = parts[4].trim();
    }
    title ??= pdb.name.trim().isEmpty ? null : pdb.name.trim();
    return BookMetadata(
      format: BookFormat.ereader,
      title: title,
      authors: authors,
      publisher: publisher,
      rights: rights,
      isbn: isbn,
    );
  }
}

String _documentPath(final String name) {
  final stem = name
      .trim()
      .replaceAll(RegExp(r'[^A-Za-z0-9 ._-]'), '_')
      .replaceFirst(RegExp(r'^\.+'), '');
  return '${stem.isEmpty ? 'index' : stem}.html';
}
