part of '../parse_fb2_book.dart';

/// The FB2 XML bytes selected from a plain or ZIP-wrapped input.
final class _Fb2Source {
  const _Fb2Source._(this.bytes);

  /// Selects the FB2 document stored in [bytes].
  factory _Fb2Source.fromBytes(final Uint8List bytes) {
    if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      final Archive archive;
      try {
        archive = decodeBookZip(bytes);
      } on Exception catch (error) {
        throw Fb2Exception('Invalid FB2 ZIP archive: $error');
      }

      for (final file in archive.files) {
        if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
          return _Fb2Source.fromArchive(file);
        }
      }

      throw const Fb2Exception('No .fb2 document found inside the zip archive.');
    }

    return _Fb2Source._(bytes);
  }

  /// Selects the FB2 XML stored in an already decoded archive [entry].
  factory _Fb2Source.fromArchive(final ArchiveFile entry) {
    final content = entry.content;
    if (content is! List<int>) {
      throw const Fb2Exception('FB2 archive entry does not contain bytes.');
    }

    return _Fb2Source._(content);
  }

  /// Raw bytes of the selected FB2 XML document.
  final List<int> bytes;

  /// Parses the XML without imposing the book-body contract.
  XmlDocument parseXml() {
    // FB2 files may declare (or omit, or mislabel) any encoding; decode
    // with the BOM/declaration/detection policy, which never throws and
    // replaces undecodable bytes with U+FFFD.
    final raw = decodeXmlText(bytes);
    try {
      return XmlDocument.parse(raw);
    } on XmlException catch (error) {
      throw Fb2Exception('Invalid FB2 document: $error');
    }
  }

  /// Parses and validates the FictionBook root and body contract.
  _Fb2Document parseDocument() {
    final document = parseXml();
    final root = document.rootElement;
    if (root.name.local != 'FictionBook') throw const Fb2Exception('Not a FictionBook document.');

    final bodies = root.findElements('body').toList();
    if (bodies.isEmpty) throw const Fb2Exception('FB2 document has no body.');

    return _Fb2Document(root: root, bodies: bodies);
  }
}

/// Validated FB2 DOM plus its reading bodies.
final class _Fb2Document {
  /// Creates a validated document result.
  const _Fb2Document({required this.root, required this.bodies});

  /// FictionBook root element.
  final XmlElement root;

  /// Direct reading and named-note bodies in document order.
  final List<XmlElement> bodies;
}
