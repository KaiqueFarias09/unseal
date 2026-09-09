import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../../../foundation/text/xml_encoding.dart';
import '../exceptions/exceptions.dart';

/// The FB2 XML bytes selected from a plain or ZIP-wrapped input.
final class Fb2Source {
  const Fb2Source._(this.bytes);

  /// Selects the FB2 document stored in [bytes].
  factory Fb2Source.fromBytes(final Uint8List bytes) {
    if (bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B) {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final file in archive.files) {
        if (file.isFile && file.name.toLowerCase().endsWith('.fb2')) {
          return Fb2Source.fromArchive(file);
        }
      }
      throw const Fb2Exception('No .fb2 document found inside the zip archive.');
    }

    return Fb2Source._(bytes);
  }

  /// Selects the FB2 XML stored in an already decoded archive [entry].
  factory Fb2Source.fromArchive(final ArchiveFile entry) => Fb2Source._(entry.content as List<int>);

  /// Raw bytes of the selected FB2 XML document.
  final List<int> bytes;

  /// Parses the XML without imposing the book-body contract.
  XmlDocument parseXml() {
    // FB2 files may declare (or omit, or mislabel) any encoding; decode
    // with the Calibre-style BOM/declaration/detection policy, which
    // never throws and replaces undecodable bytes with U+FFFD.
    final raw = decodeXmlText(bytes);
    try {
      return XmlDocument.parse(raw);
    } on XmlException catch (error) {
      throw Fb2Exception('Invalid FB2 document: $error');
    }
  }

  /// Parses and validates the FictionBook root and body contract.
  Fb2Document parseDocument() {
    final document = parseXml();
    final root = document.rootElement;
    if (root.name.local != 'FictionBook') {
      throw const Fb2Exception('Not a FictionBook document.');
    }

    final bodies = root.findElements('body').toList();
    if (bodies.isEmpty) throw const Fb2Exception('FB2 document has no body.');

    return Fb2Document(root: root, bodies: bodies);
  }
}

/// Validated FB2 DOM plus its reading bodies.
final class Fb2Document {
  /// Creates a validated document result.
  const Fb2Document({required this.root, required this.bodies});

  /// FictionBook root element.
  final XmlElement root;

  /// Direct reading and named-note bodies in document order.
  final List<XmlElement> bodies;
}
