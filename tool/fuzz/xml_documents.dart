import 'dart:convert';
import 'dart:typed_data';

import 'seeded_random.dart';

/// Builds well-formed XML documents with grammar-adjacent edge features:
/// namespaces, entity forms, CDATA, comments, processing instructions,
/// internal DTD subsets and declaration/BOM variations.
///
/// Everything produced here PARSES as XML — the fuzz value comes from
/// exercising namespace resolution, entity expansion and encoding paths,
/// not from malformed bytes (mutation handles those).
final class XmlDocumentSpec {
  const XmlDocumentSpec({
    required this.root,
    required this.body,
    this.withBom = false,
    this.declaration = '<?xml version="1.0" encoding="utf-8"?>\n',
    this.doctype,
  });

  /// Root element name.
  final String root;

  /// Inner markup (already well-formed).
  final String body;

  /// Whether to prefix a UTF-8 BOM.
  final bool withBom;

  /// XML declaration line (or empty).
  final String declaration;

  /// Optional DOCTYPE (internal subset included verbatim).
  final String? doctype;
}

/// Serializes [spec] to bytes (BOM + declaration + doctype + document).
Uint8List buildXmlDocument(final XmlDocumentSpec spec) {
  final buffer = StringBuffer();
  if (spec.withBom) {
    // The BOM is written as the literal U+FEFF code unit; utf8 encoding
    // turns it into the three EF BB BF bytes.
    buffer.write('\uFEFF');
  }
  buffer.write(spec.declaration);
  if (spec.doctype != null) {
    buffer.write('${spec.doctype}\n');
  }
  buffer.write(spec.body);
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

/// FictionBook-shaped document exercising namespaced attributes, the
/// four predefined entities, numeric entities and a CDATA section.
XmlDocumentSpec fb2StyleSpec(final SeededRandom random) {
  final title = '${random.word(5)} ${random.word(6)}';
  return XmlDocumentSpec(
    root: 'FictionBook',
    body:
        '<FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" '
        'xmlns:l="http://www.w3.org/1999/xlink">\n'
        '  <description>\n'
        '    <title-info>\n'
        '      <book-title>$title</book-title>\n'
        '      <author><first-name>${random.word(4)}</first-name>'
        '<last-name>${random.word(6)}</last-name></author>\n'
        '    </title-info>\n'
        '  </description>\n'
        '  <body>\n'
        '    <section>\n'
        '      <title><p>Entities: &amp; &lt; &gt; &apos; &quot; '
        '&#65; &#x42;</p></title>\n'
        '      <p>Attribute xlink: "<a l:href="#note1">ref</a>"</p>\n'
        '      <p><![CDATA[raw <markup> & symbols inside cdata]]></p>\n'
        '      <!-- a comment with <angle> brackets -->\n'
        '      <empty-line/>\n'
        '    </section>\n'
        '  </body>\n'
        '</FictionBook>\n',
  );
}

/// EPUB OPF-shaped package document with deep namespace usage.
XmlDocumentSpec opfStyleSpec(final SeededRandom random) {
  final title = '${random.word(7)} ${random.word(4)}';
  return XmlDocumentSpec(
    root: 'package',
    body:
        '<package xmlns="http://www.idpf.org/2007/opf" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0" '
        'unique-identifier="uid" xml:lang="en">\n'
        '  <metadata>\n'
        '    <dc:identifier id="uid">urn:uuid:${random.alphanumeric(8)}-0000</dc:identifier>\n'
        '    <dc:title xml:lang="en">$title</dc:title>\n'
        '    <dc:creator id="creator">${random.word(5)} ${random.word(5)}</dc:creator>\n'
        '    <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>\n'
        '    <meta property="dcterms:modified">2026-01-01T00:00:00Z</meta>\n'
        '  </metadata>\n'
        '  <manifest>\n'
        '    <item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>\n'
        '  </manifest>\n'
        '  <spine>\n    <itemref idref="c1"/>\n  </spine>\n'
        '</package>\n',
  );
}

/// Document with an internal DTD subset (entity definitions in scope).
XmlDocumentSpec doctypeInternalSubsetSpec(final SeededRandom random) {
  return XmlDocumentSpec(
    root: 'book',
    declaration: '<?xml version="1.0" standalone="yes"?>\n',
    doctype:
        '<!DOCTYPE book [\n'
        '  <!ELEMENT book (title,para+)>\n'
        '  <!ENTITY publisher "${random.word(6)} Press">\n'
        '  <!ENTITY long "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx">\n'
        ']>',
    body:
        '<book>\n'
        '  <title>Internal &publisher; entity</title>\n'
        '  <para>${random.word(8)} &long; tail.</para>\n'
        '</book>\n',
  );
}

/// Comments, processing instructions and a comment-before-declaration-free
/// prologue.
XmlDocumentSpec prologueVariationSpec(final SeededRandom random) {
  return XmlDocumentSpec(
    root: 'container',
    declaration: '',
    body:
        '<?xml-stylesheet type="text/css" href="style.css"?>\n'
        '<!-- leading comment -->\n'
        '<container>\n'
        '  <item id="${random.alphanumeric(6)}">value</item>\n'
        '  <nested xmlns:extra="urn:example:extra" extra:flag="true">\n'
        '    <deep>text with\ttabs and\nnewlines</deep>\n'
        '  </nested>\n'
        '</container>\n',
  );
}
