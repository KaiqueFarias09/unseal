import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/text/xml_encoding.dart';
import '../mobi/header/pdb_header.dart';
import '../palmdoc/palmdoc_compression.dart';
import '../txt/parse_txt_book.dart';

const _maxBookBytes = 64 * 1024 * 1024;
const _maxRecords = 8192;
const _maxCompressedRecordBytes = 8192;
const _maxDecodedRecordBytes = 65535;

/// Parses an unencrypted eReader PDB into readable text and metadata.
///
/// eReader's Palm Markup Language is reduced to reading text. Image, footnote,
/// sidebar, and page-layout instructions are not represented in this result.
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
  final readable = _stripPml(pml);
  final document = parseTxtBook(
    Uint8List.fromList(utf8.encode(readable)),
    sourceName: source.pdb.name,
  );
  final metadata = source.metadata();
  final htmlPath = document.files.html.single.path;
  return DocumentBook(
    format: BookFormat.ereader,
    files: document.files,
    metadata: metadata,
    navigation: Navigation(
      title: metadata.title ?? 'Contents',
      navPoints: <NavPoint>[
        NavPoint(
          classAttribute: '',
          id: 'nav-1',
          playOrder: '1',
          label: metadata.title ?? 'Document',
          content: htmlPath,
        ),
      ],
    ),
    order: <String>[htmlPath],
  );
}

/// Reads eReader title and author without expanding any text record.
BookMetadata readEreaderMetadata(final Uint8List bytes) => _EreaderSource.read(bytes).metadata();

final class _EreaderSource {
  const _EreaderSource(this.pdb, this.compression, this.nonTextRecord, this.metadataRecord);

  final PdbHeader pdb;
  final int compression;
  final int nonTextRecord;
  final int? metadataRecord;

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
      return _EreaderSource(pdb, compression, nonTextRecord, metadataRecord);
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
      return _EreaderSource(pdb, -1, nonTextRecord, null);
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

String _stripPml(final String source) {
  final output = StringBuffer();
  var cursor = 0;
  while (cursor < source.length) {
    final char = source[cursor++];
    if (char != r'\' || cursor >= source.length) {
      output.write(char);
      continue;
    }
    final command = source[cursor++];
    switch (command) {
      case r'\':
        output.write(r'\');
      case 'n':
        output.write('\n');
      case 't':
        output.write('\t');
      default:
        // Formatting commands may have a quoted argument (for example an
        // image name). Discard it together with the command, preserving prose.
        if (cursor < source.length && source[cursor] == '=') cursor++;
        if (cursor < source.length && source[cursor] == '"') {
          cursor++;
          while (cursor < source.length && source[cursor] != '"') {
            cursor++;
          }
          if (cursor < source.length) cursor++;
        }
    }
  }
  return output.toString();
}
