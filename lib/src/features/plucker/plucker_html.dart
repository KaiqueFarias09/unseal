import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/exceptions/unseal_exception.dart';

/// Renders the documented Plucker inline-function subset as safe HTML.
String renderPluckerParagraph(
  final Uint8List paragraph, {
  required final Set<int> textIds,
  required final Map<int, String> imagePaths,
}) {
  const escape = HtmlEscape(HtmlEscapeMode.element);
  final html = StringBuffer();
  String? font;
  var italic = false;
  var underline = false;
  var strike = false;
  var link = false;

  void setFont(final int number) {
    if (font != null) html.write('</$font>');
    font = switch (number) {
      1 => 'h1',
      2 => 'h2',
      3 => 'h3',
      4 => 'h4',
      5 => 'h5',
      6 => 'h6',
      7 => 'strong',
      8 => 'code',
      9 => 'small',
      10 => 'sub',
      11 => 'sup',
      _ => null,
    };
    if (font != null) html.write('<$font>');
  }

  for (var index = 0; index < paragraph.length; index++) {
    final byte = paragraph[index];
    if (byte != 0) {
      html.write(escape.convert(String.fromCharCode(byte)));
      continue;
    }
    if (++index >= paragraph.length) {
      throw const InvalidBookException('Truncated Plucker text function.');
    }
    final code = paragraph[index];
    final argumentBytes = code & 7;
    if (index + argumentBytes >= paragraph.length) {
      throw const InvalidBookException('Truncated Plucker text function argument.');
    }
    final args = Uint8List.sublistView(paragraph, index + 1, index + 1 + argumentBytes);
    final view = ByteData.sublistView(args);
    switch (code) {
      case 0x0a:
      case 0x0b:
      case 0x0c:
      case 0x0d:
        if (link) html.write('</a>');
        link = false;
        final uid = view.getUint16(0);
        if (textIds.contains(uid)) {
          final target = code == 0x0c || code == 0x0d ? 'r$uid-p${view.getUint16(2)}' : 'r$uid';
          html.write('<a href="#$target">');
          link = true;
        }
      case 0x08:
        if (link) html.write('</a>');
        link = false;
      case 0x11:
        setFont(args[0]);
      case 0x1a:
        final path = imagePaths[view.getUint16(0)];
        if (path != null) html.write('<img src="${escape.convert(path)}" alt=""/>');
      case 0x5c:
        final path = imagePaths[view.getUint16(2)] ?? imagePaths[view.getUint16(0)];
        if (path != null) html.write('<img src="${escape.convert(path)}" alt=""/>');
      case 0x33:
        html.write('<hr/>');
      case 0x38:
        html.write('<br/>');
      case 0x40:
        if (!italic) html.write('<em>');
        italic = true;
      case 0x48:
        if (italic) html.write('</em>');
        italic = false;
      case 0x60:
        if (!underline) html.write('<u>');
        underline = true;
      case 0x68:
        if (underline) html.write('</u>');
        underline = false;
      case 0x70:
        if (!strike) html.write('<s>');
        strike = true;
      case 0x78:
        if (strike) html.write('</s>');
        strike = false;
      case 0x83:
      case 0x85:
        final alternateLength = args[0];
        final value = code == 0x83 ? view.getUint16(1) : view.getUint32(1);
        if (value <= 0x10ffff && (value < 0xd800 || value > 0xdfff)) {
          html.write(escape.convert(String.fromCharCode(value)));
          if (index + argumentBytes + alternateLength >= paragraph.length) {
            throw const InvalidBookException('Truncated Plucker Unicode alternate text.');
          }
          index += alternateLength;
        }
    }
    index += argumentBytes;
  }
  if (link) html.write('</a>');
  if (strike) html.write('</s>');
  if (underline) html.write('</u>');
  if (italic) html.write('</em>');
  if (font != null) html.write('</$font>');
  return html.toString();
}
