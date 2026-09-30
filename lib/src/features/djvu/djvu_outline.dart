import 'dart:convert';
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import 'bzz_decoder.dart';
import 'djvu_exception.dart';

/// Maximum decompressed NAVM payload. The 16-bit bookmark count bounds the
/// record stream at 65535 records of at least 7 bytes each (~448 KiB), so the
/// cap only guards hostile declarations.
const int _maxOutlineBytes = 1024 * 1024;

/// Decodes a BZZ-compressed NAVM outline chunk (DjVu 3 spec, §8.3.3).
///
/// The decompressed payload is a 16-bit bookmark count followed by that many
/// records: a child count byte, a 24-bit description length plus UTF-8 bytes,
/// and a 24-bit URL length plus UTF-8 bytes. Records are listed in depth-first
/// order and each record claims its immediate children from the records that
/// follow it.
///
/// The raw URL string is carried on each point's `content` target. Page
/// anchors (`#1`, `#p0002.djvu`) and file links are kept verbatim; resolving
/// them to page numbers is a presentation decision outside this parser.
List<NavPoint> decodeDjvuNavm(final Uint8List encoded) {
  final raw = decodeDjvuBzz(
    encoded,
    truncatedMessage: 'Truncated DjVu NAVM chunk.',
    maxOutputBytes: _maxOutlineBytes,
  );
  return decodeDjvuNavmRecords(raw);
}

/// Assembles the decompressed NAVM record stream into navigation points.
///
/// Split from [decodeDjvuNavm] so hostile decompressed record streams can be
/// exercised directly.
List<NavPoint> decodeDjvuNavmRecords(final Uint8List raw) {
  if (raw.length < 2) {
    throw const DjvuException('Truncated DjVu NAVM chunk.');
  }
  final count = (raw[0] << 8) | raw[1];
  if (count == 0) {
    return const <NavPoint>[];
  }

  var position = 2;
  final labels = List<String>.filled(count, '');
  final contents = List<String>.filled(count, '');
  final childCounts = Uint8List(count);
  for (var index = 0; index < count; index++) {
    if (position + 7 > raw.length) {
      throw const DjvuException('Truncated DjVu NAVM bookmark record.');
    }
    childCounts[index] = raw[position++];
    final descriptionLength = (raw[position] << 16) | (raw[position + 1] << 8) | raw[position + 2];
    position += 3;
    if (descriptionLength > raw.length - position) {
      throw const DjvuException('Truncated DjVu NAVM bookmark description.');
    }
    final urlPosition = position + descriptionLength;
    if (urlPosition + 3 > raw.length) {
      throw const DjvuException('Truncated DjVu NAVM bookmark URL.');
    }
    final urlLength = (raw[urlPosition] << 16) | (raw[urlPosition + 1] << 8) | raw[urlPosition + 2];
    if (urlLength > raw.length - urlPosition - 3) {
      throw const DjvuException('Truncated DjVu NAVM bookmark URL.');
    }
    try {
      labels[index] = utf8.decode(
        Uint8List.sublistView(raw, position, position + descriptionLength),
      );
      contents[index] = utf8.decode(
        Uint8List.sublistView(raw, urlPosition + 3, urlPosition + 3 + urlLength),
      );
    } on FormatException {
      throw const DjvuException('DjVu NAVM bookmark text is not valid UTF-8.');
    }
    position = urlPosition + 3 + urlLength;
  }

  // Assemble the depth-first record list into a tree. The stack holds nodes
  // that still claim children, so hostile child counts cannot recurse.
  final children = List<List<NavPoint>>.generate(count, (_) => <NavPoint>[]);
  final claimed = Uint8List(count);
  final roots = <NavPoint>[];
  final stack = <int>[];
  var assembled = 0;

  void finish(final int index) {
    assembled++;
    final point = _point(index, labels, contents, children);
    if (stack.isEmpty) {
      roots.add(point);
    } else {
      children[stack.last].add(point);
    }
  }

  for (var index = 0; index < count; index++) {
    while (stack.isNotEmpty && claimed[stack.last] == childCounts[stack.last]) {
      finish(stack.removeLast());
    }
    if (stack.isNotEmpty) {
      claimed[stack.last]++;
    }
    stack.add(index);
  }
  while (stack.isNotEmpty) {
    finish(stack.removeLast());
  }
  for (var index = 0; index < count; index++) {
    if (claimed[index] != childCounts[index]) {
      throw const DjvuException('DjVu NAVM child counts exceed the bookmark count.');
    }
  }
  if (assembled != count || roots.isEmpty) {
    throw const DjvuException('DjVu NAVM child counts exceed the bookmark count.');
  }
  return roots;
}

NavPoint _point(
  final int index,
  final List<String> labels,
  final List<String> contents,
  final List<List<NavPoint>> children,
) => NavPoint(
  classAttribute: 'bookmark',
  id: 'navm-${index + 1}',
  playOrder: '${index + 1}',
  label: labels[index],
  content: contents[index],
  subNavPoints: children[index],
);
