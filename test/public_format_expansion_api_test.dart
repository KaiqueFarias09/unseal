import 'dart:io';

import 'package:test/test.dart';
import 'package:unseal/markdown.dart' as markdown;
import 'package:unseal/palmdoc.dart' as palmdoc;
import 'package:unseal/rtf.dart' as rtf;

void main() {
  test('new format-specific entry points expose parsers and result types', () {
    final root = 'test/resources/books/format_expansion';
    final mdBytes = File('$root/garden.md').readAsBytesSync();
    final rtfBytes = File('$root/garden.rtf').readAsBytesSync();
    final pdbBytes = File('$root/garden.pdb').readAsBytesSync();

    final markdown.DocumentBook md = markdown.parseMarkdownBook(mdBytes);
    final rtf.DocumentBook rich = rtf.parseRtfBook(rtfBytes);
    final palmdoc.DocumentBook palm = palmdoc.parsePalmdocBook(pdbBytes);

    expect(md.format, markdown.BookFormat.markdown);
    expect(rich.format, rtf.BookFormat.rtf);
    expect(palm.format, palmdoc.BookFormat.palmdoc);
    expect(markdown.readMarkdownMetadata(mdBytes).title, md.metadata.title);
    expect(rtf.readRtfMetadata(rtfBytes).title, rich.metadata.title);
    expect(palmdoc.readPalmdocMetadata(pdbBytes).title, palm.metadata.title);
  });
}
