/// JBIG2 Huffman coding (Annex B): the bit Reader, the code-table
/// tree, the 15 standard tables, custom Tables segments and the
/// symbol-ID table with its run codes.
///
/// Ported from pdf.js v3.11.174 `src/core/jbig2.js`
/// (`Reader`, `HuffmanLine`, `HuffmanTreeNode`, `HuffmanTable`,
/// `decodeTablesSegment`, `getStandardTable`,
/// `getCustomHuffmanTable`, `getTextRegionHuffmanTables`,
/// `getSymbolDictionaryHuffmanTables`), Apache-2.0; parity comments
/// point at the mirrored functions.
library;

import 'dart:typed_data';

import '../exceptions/pdf_exception.dart';
import 'pdf_jbig2_segment.dart';

/// One Huffman table line, pdf.js `HuffmanLine`. pdf.js packs the
/// 2/4/5-value literal shapes into one object; the same fields land
/// here, with [isLowerRange] replacing the `"lower"` string tag.
// pdf.js jbig2.js HuffmanLine
final class _HuffmanLine {
  /// Builds the line from the pdf.js literal shape: 2 values = OOB
  /// (`[prefixLength, prefixCode]`), 4 = normal/upper, 5 = lower
  /// range (leading flag).
  _HuffmanLine(final List<int> lineData)
    : isOob = lineData.length == 2,
      rangeLow = lineData.length == 2 ? 0 : lineData[0],
      prefixLength = lineData.length == 2 ? lineData[0] : lineData[1],
      rangeLength = lineData.length == 2 ? 0 : lineData[2],
      prefixCode = lineData.length == 2 ? lineData[1] : lineData[3],
      isLowerRange = lineData.length == 5 && lineData[4] == 1;

  final bool isOob;
  final int rangeLow;
  final int prefixLength;
  final int rangeLength;
  int prefixCode = 0;
  final bool isLowerRange;
}

/// One node of the decode tree, pdf.js `HuffmanTreeNode`. The
/// children are flat arrays of two slots (bit 0 / bit 1); a -1
/// child id means the branch is missing.
// pdf.js jbig2.js HuffmanTreeNode
final class _HuffmanNode {
  int rangeLow = 0;
  int rangeLength = 0;
  bool isLowerRange = false;
  bool isOob = false;
  bool isLeaf = false;
  final List<int> children = <int>[-1, -1];
}

/// A Huffman code table, pdf.js `HuffmanTable`. The tree is a flat
/// arena of `_HuffmanNode`s (root at 0) instead of linked objects.
// pdf.js jbig2.js HuffmanTable
final class Jbig2HuffmanTable {
  /// Builds the table from the pdf.js-shaped [lines];
  /// [prefixCodesDone] mirrors pdf.js — standard tables ship literal
  /// prefix codes, segment-derived lines get theirs assigned per
  /// Annex B.3.
  Jbig2HuffmanTable(final List<List<int>> lines, {final bool prefixCodesDone = false}) {
    final parsed = lines.map(_HuffmanLine.new).toList();
    if (!prefixCodesDone) {
      _assignPrefixCodes(parsed);
    }
    for (final line in parsed) {
      if (line.prefixLength > 0) {
        _buildTree(line, line.prefixLength - 1);
      }
    }
  }

  final List<_HuffmanNode> _nodes = <_HuffmanNode>[_HuffmanNode()];

  // pdf.js jbig2.js HuffmanTreeNode.buildTree
  void _buildTree(final _HuffmanLine line, final int shift) {
    var node = 0;
    var s = shift;
    while (true) {
      final bit = (line.prefixCode >> s) & 1;
      if (s <= 0) {
        final child = _nodes[node].children[bit];
        if (child >= 0 && _nodes[child].isLeaf) {
          throw const PdfException('JBIG2 error: overallocated tree (invalid Huffman data).');
        }
        final leaf = _HuffmanNode()
          ..isLeaf = true
          ..rangeLength = line.rangeLength
          ..rangeLow = line.rangeLow
          ..isLowerRange = line.isLowerRange
          ..isOob = line.isOob;
        _nodes[node].children[bit] = _nodes.length;
        _nodes.add(leaf);
        return;
      }
      var child = _nodes[node].children[bit];
      if (child < 0 || _nodes[child].isLeaf) {
        child = _nodes.length;
        _nodes[node].children[bit] = child;
        _nodes.add(_HuffmanNode());
      }
      node = child;
      s--;
    }
  }

  /// Decodes one value (`HuffmanTable.decode` +
  /// `HuffmanTreeNode.decodeNode`): returns null on the OOB line.
  // pdf.js jbig2.js HuffmanTable.decode / HuffmanTreeNode.decodeNode
  int? decode(final Jbig2BitReader reader) {
    var node = 0;
    while (true) {
      final current = _nodes[node];
      if (current.isLeaf) {
        if (current.isOob) {
          return null;
        }
        final htOffset = reader.readBits(current.rangeLength);
        return current.rangeLow + (current.isLowerRange ? -htOffset : htOffset);
      }
      final next = current.children[reader.readBit()];
      if (next < 0) {
        throw const PdfException('JBIG2 error: invalid Huffman data.');
      }
      node = next;
    }
  }

  // pdf.js jbig2.js HuffmanTable.assignPrefixCodes
  void _assignPrefixCodes(final List<_HuffmanLine> lines) {
    // Annex B.3 Assigning the prefix codes.
    var prefixLengthMax = 0;
    for (final line in lines) {
      if (line.prefixLength > prefixLengthMax) {
        prefixLengthMax = line.prefixLength;
      }
    }

    final histogram = Uint32List(prefixLengthMax + 1);
    for (final line in lines) {
      histogram[line.prefixLength]++;
    }
    histogram[0] = 0;
    var currentLength = 1;
    var firstCode = 0;
    while (currentLength <= prefixLengthMax) {
      firstCode = (firstCode + histogram[currentLength - 1]) << 1;
      var currentCode = firstCode;
      for (final line in lines) {
        if (line.prefixLength == currentLength) {
          line.prefixCode = currentCode;
          currentCode++;
        }
      }
      currentLength++;
    }
  }
}

/// The MSB-first bit reader over a byte window, pdf.js `Reader`.
// pdf.js jbig2.js Reader
final class Jbig2BitReader {
  /// Creates a reader over [data] in `[start, end)`.
  Jbig2BitReader(this.data, this.start, this.end) : position = start;

  /// The bytes being read.
  final Uint8List data;

  /// The window start (kept for parity with the pdf.js field).
  final int start;

  /// The exclusive window end; mutable because pdf.js narrows it
  /// around an MMR collective bitmap.
  int end;

  /// The next byte index to load.
  int position;

  int _shift = -1;
  int _currentByte = 0;

  /// Reads one bit; pdf.js throws past the window end.
  // pdf.js jbig2.js Reader.readBit
  int readBit() {
    if (_shift < 0) {
      if (position >= end) {
        throw const PdfException('JBIG2 error: end of data while reading bit.');
      }
      _currentByte = data[position++];
      _shift = 7;
    }
    final bit = (_currentByte >> _shift) & 1;
    _shift--;
    return bit;
  }

  /// Reads [numBits] bits, first bit most significant.
  // pdf.js jbig2.js Reader.readBits
  int readBits(final int numBits) {
    var result = 0;
    for (var i = numBits - 1; i >= 0; i--) {
      result |= readBit() << i;
    }
    return result;
  }

  /// Realigns to the next byte boundary.
  // pdf.js jbig2.js Reader.byteAlign
  void byteAlign() {
    _shift = -1;
  }

  /// Reads the next whole byte, or -1 past the window end.
  // pdf.js jbig2.js Reader.next
  int next() {
    if (position >= end) {
      return -1;
    }
    return data[position++];
  }
}

const List<List<List<int>>> _standardTableLines = <List<List<int>>>[
  <List<int>>[], // no table B.0
  <List<int>>[
    <int>[0, 1, 4, 0],
    <int>[16, 2, 8, 2],
    <int>[272, 3, 16, 6],
    <int>[65808, 3, 32, 7],
  ], // B.1
  <List<int>>[
    <int>[0, 1, 0, 0],
    <int>[1, 2, 0, 2],
    <int>[2, 3, 0, 6],
    <int>[3, 4, 3, 0xe],
    <int>[11, 5, 6, 0x1e],
    <int>[75, 6, 32, 0x3e],
    <int>[6, 63],
  ], // B.2
  <List<int>>[
    <int>[-256, 8, 8, 0xfe],
    <int>[0, 1, 0, 0],
    <int>[1, 2, 0, 2],
    <int>[2, 3, 0, 6],
    <int>[3, 4, 3, 0xe],
    <int>[11, 5, 6, 0x1e],
    <int>[-257, 8, 32, 0xff, 1],
    <int>[75, 7, 32, 0x7e],
    <int>[6, 62],
  ], // B.3
  <List<int>>[
    <int>[1, 1, 0, 0],
    <int>[2, 2, 0, 2],
    <int>[3, 3, 0, 6],
    <int>[4, 4, 3, 0xe],
    <int>[12, 5, 6, 0x1e],
    <int>[76, 5, 32, 0x1f],
  ], // B.4
  <List<int>>[
    <int>[-255, 7, 8, 0x7e],
    <int>[1, 1, 0, 0],
    <int>[2, 2, 0, 2],
    <int>[3, 3, 0, 6],
    <int>[4, 4, 3, 0xe],
    <int>[12, 5, 6, 0x1e],
    <int>[-256, 7, 32, 0x7f, 1],
    <int>[76, 6, 32, 0x3e],
  ], // B.5
  <List<int>>[
    <int>[-2048, 5, 10, 0x1c],
    <int>[-1024, 4, 9, 8],
    <int>[-512, 4, 8, 9],
    <int>[-256, 4, 7, 0xa],
    <int>[-128, 5, 6, 0x1d],
    <int>[-64, 5, 5, 0x1e],
    <int>[-32, 4, 5, 0xb],
    <int>[0, 2, 7, 0],
    <int>[128, 3, 7, 2],
    <int>[256, 3, 8, 3],
    <int>[512, 4, 9, 0xc],
    <int>[1024, 4, 10, 0xd],
    <int>[-2049, 6, 32, 0x3e, 1],
    <int>[2048, 6, 32, 0x3f],
  ], // B.6
  <List<int>>[
    <int>[-1024, 4, 9, 8],
    <int>[-512, 3, 8, 0],
    <int>[-256, 4, 7, 9],
    <int>[-128, 5, 6, 0x1a],
    <int>[-64, 5, 5, 0x1b],
    <int>[-32, 4, 5, 0xa],
    <int>[0, 4, 5, 0xb],
    <int>[32, 5, 5, 0x1c],
    <int>[64, 5, 6, 0x1d],
    <int>[128, 4, 7, 0xc],
    <int>[256, 3, 8, 1],
    <int>[512, 3, 9, 2],
    <int>[1024, 3, 10, 3],
    <int>[-1025, 5, 32, 0x1e, 1],
    <int>[2048, 5, 32, 0x1f],
  ], // B.7
  <List<int>>[
    <int>[-15, 8, 3, 0xfc],
    <int>[-7, 9, 1, 0x1fc],
    <int>[-5, 8, 1, 0xfd],
    <int>[-3, 9, 0, 0x1fd],
    <int>[-2, 7, 0, 0x7c],
    <int>[-1, 4, 0, 0xa],
    <int>[0, 2, 1, 0],
    <int>[2, 5, 0, 0x1a],
    <int>[3, 6, 0, 0x3a],
    <int>[4, 3, 4, 4],
    <int>[20, 6, 1, 0x3b],
    <int>[22, 4, 4, 0xb],
    <int>[38, 4, 5, 0xc],
    <int>[70, 5, 6, 0x1b],
    <int>[134, 5, 7, 0x1c],
    <int>[262, 6, 7, 0x3c],
    <int>[390, 7, 8, 0x7d],
    <int>[646, 6, 10, 0x3d],
    <int>[-16, 9, 32, 0x1fe, 1],
    <int>[1670, 9, 32, 0x1ff],
    <int>[2, 1],
  ], // B.8
  <List<int>>[
    <int>[-31, 8, 4, 0xfc],
    <int>[-15, 9, 2, 0x1fc],
    <int>[-11, 8, 2, 0xfd],
    <int>[-7, 9, 1, 0x1fd],
    <int>[-5, 7, 1, 0x7c],
    <int>[-3, 4, 1, 0xa],
    <int>[-1, 3, 1, 2],
    <int>[1, 3, 1, 3],
    <int>[3, 5, 1, 0x1a],
    <int>[5, 6, 1, 0x3a],
    <int>[7, 3, 5, 4],
    <int>[39, 6, 2, 0x3b],
    <int>[43, 4, 5, 0xb],
    <int>[75, 4, 6, 0xc],
    <int>[139, 5, 7, 0x1b],
    <int>[267, 5, 8, 0x1c],
    <int>[523, 6, 8, 0x3c],
    <int>[779, 7, 9, 0x7d],
    <int>[1291, 6, 11, 0x3d],
    <int>[-32, 9, 32, 0x1fe, 1],
    <int>[3339, 9, 32, 0x1ff],
    <int>[2, 0],
  ], // B.9
  <List<int>>[
    <int>[-21, 7, 4, 0x7a],
    <int>[-5, 8, 0, 0xfc],
    <int>[-4, 7, 0, 0x7b],
    <int>[-3, 5, 0, 0x18],
    <int>[-2, 2, 2, 0],
    <int>[2, 5, 0, 0x19],
    <int>[3, 6, 0, 0x36],
    <int>[4, 7, 0, 0x7c],
    <int>[5, 8, 0, 0xfd],
    <int>[6, 2, 6, 1],
    <int>[70, 5, 5, 0x1a],
    <int>[102, 6, 5, 0x37],
    <int>[134, 6, 6, 0x38],
    <int>[198, 6, 7, 0x39],
    <int>[326, 6, 8, 0x3a],
    <int>[582, 6, 9, 0x3b],
    <int>[1094, 6, 10, 0x3c],
    <int>[2118, 7, 11, 0x7d],
    <int>[-22, 8, 32, 0xfe, 1],
    <int>[4166, 8, 32, 0xff],
    <int>[2, 2],
  ], // B.10
  <List<int>>[
    <int>[1, 1, 0, 0],
    <int>[2, 2, 1, 2],
    <int>[4, 4, 0, 0xc],
    <int>[5, 4, 1, 0xd],
    <int>[7, 5, 1, 0x1c],
    <int>[9, 5, 2, 0x1d],
    <int>[13, 6, 2, 0x3c],
    <int>[17, 7, 2, 0x7a],
    <int>[21, 7, 3, 0x7b],
    <int>[29, 7, 4, 0x7c],
    <int>[45, 7, 5, 0x7d],
    <int>[77, 7, 6, 0x7e],
    <int>[141, 7, 32, 0x7f],
  ], // B.11
  <List<int>>[
    <int>[1, 1, 0, 0],
    <int>[2, 2, 0, 2],
    <int>[3, 3, 1, 6],
    <int>[5, 5, 0, 0x1c],
    <int>[6, 5, 1, 0x1d],
    <int>[8, 6, 1, 0x3c],
    <int>[10, 7, 0, 0x7a],
    <int>[11, 7, 1, 0x7b],
    <int>[13, 7, 2, 0x7c],
    <int>[17, 7, 3, 0x7d],
    <int>[25, 7, 4, 0x7e],
    <int>[41, 8, 5, 0xfe],
    <int>[73, 8, 32, 0xff],
  ], // B.12
  <List<int>>[
    <int>[1, 1, 0, 0],
    <int>[2, 3, 0, 4],
    <int>[3, 4, 0, 0xc],
    <int>[4, 5, 0, 0x1c],
    <int>[5, 4, 1, 0xd],
    <int>[7, 3, 3, 5],
    <int>[15, 6, 1, 0x3a],
    <int>[17, 6, 2, 0x3b],
    <int>[21, 6, 3, 0x3c],
    <int>[29, 6, 4, 0x3d],
    <int>[45, 6, 5, 0x3e],
    <int>[77, 7, 6, 0x7e],
    <int>[141, 7, 32, 0x7f],
  ], // B.13
  <List<int>>[
    <int>[-2, 3, 0, 4],
    <int>[-1, 3, 0, 5],
    <int>[0, 1, 0, 0],
    <int>[1, 3, 0, 6],
    <int>[2, 3, 0, 7],
  ], // B.14
  <List<int>>[
    <int>[-24, 7, 4, 0x7c],
    <int>[-8, 6, 2, 0x3c],
    <int>[-4, 5, 1, 0x1c],
    <int>[-2, 4, 0, 0xc],
    <int>[-1, 3, 0, 4],
    <int>[0, 1, 0, 0],
    <int>[1, 3, 0, 5],
    <int>[2, 4, 0, 0xd],
    <int>[3, 5, 1, 0x1d],
    <int>[5, 6, 2, 0x3d],
    <int>[9, 7, 4, 0x7d],
    <int>[-25, 7, 32, 0x7e, 1],
    <int>[25, 7, 32, 0x7f],
  ], // B.15
];

/// The standard tables cache, pdf.js `standardTablesCache`.
final List<Jbig2HuffmanTable?> _standardTablesCache = List<Jbig2HuffmanTable?>.filled(16, null);

/// Returns standard Huffman table B.[number]
/// (`getStandardTable` in pdf.js).
// pdf.js jbig2.js getStandardTable
Jbig2HuffmanTable jbig2GetStandardTable(final int number) {
  final cached = number >= 1 && number <= 15 ? _standardTablesCache[number] : null;
  if (cached != null) {
    return cached;
  }
  if (number < 1 || number > 15) {
    throw PdfException('JBIG2 error: standard table B.$number does not exist.');
  }
  final table = Jbig2HuffmanTable(_standardTableLines[number], prefixCodesDone: true);
  _standardTablesCache[number] = table;
  return table;
}

/// Returns the [index]-th custom Tables table referred to by
/// [referredTo] (`getCustomHuffmanTable` in pdf.js).
// pdf.js jbig2.js getCustomHuffmanTable
Jbig2HuffmanTable _jbig2GetCustomHuffmanTable(
  final int index,
  final List<int> referredTo,
  final Map<int, Jbig2HuffmanTable> customTables,
) {
  // Returns a Tables segment that has been earlier decoded.
  // See 7.4.2.1.6 (symbol dictionary) or 7.4.3.1.6 (text region).
  var currentIndex = 0;
  for (final segmentNumber in referredTo) {
    final table = customTables[segmentNumber];
    if (table != null) {
      if (index == currentIndex) {
        return table;
      }
      currentIndex++;
    }
  }
  throw const PdfException("JBIG2 error: can't find custom Huffman table.");
}

/// The Huffman tables one text region uses, selected per
/// 7.4.3.1.6; pdf.js returns them as an object literal.
final class Jbig2TextRegionHuffmanTables {
  /// The 7.4.3.1.7 symbol-ID table.
  final Jbig2HuffmanTable symbolIdTable;

  /// The IAFS first-S table.
  final Jbig2HuffmanTable tableFirstS;

  /// The IADS delta-S table.
  final Jbig2HuffmanTable tableDeltaS;

  /// The IADT delta-T table.
  final Jbig2HuffmanTable tableDeltaT;

  /// Creates the text-region table set.
  const Jbig2TextRegionHuffmanTables(
    this.symbolIdTable,
    this.tableFirstS,
    this.tableDeltaS,
    this.tableDeltaT,
  );
}

/// The Huffman tables one symbol dictionary uses, selected per
/// 7.4.2.1.6.
final class Jbig2SymbolDictionaryHuffmanTables {
  /// The IADH delta-height table.
  final Jbig2HuffmanTable tableDeltaHeight;

  /// The IADW delta-width table.
  final Jbig2HuffmanTable tableDeltaWidth;

  /// The BN (bitmap-size) table.
  final Jbig2HuffmanTable tableBitmapSize;

  /// The BAI (aggregate instances) table.
  final Jbig2HuffmanTable tableAggregateInstances;

  /// Creates the symbol-dictionary table set.
  const Jbig2SymbolDictionaryHuffmanTables(
    this.tableDeltaHeight,
    this.tableDeltaWidth,
    this.tableBitmapSize,
    this.tableAggregateInstances,
  );
}

/// Reads the run-code length lines 0..34, builds the symbol-ID
/// table and selects the FS/DS/DT tables
/// (`getTextRegionHuffmanTables` in pdf.js).
// pdf.js jbig2.js getTextRegionHuffmanTables
Jbig2TextRegionHuffmanTables jbig2GetTextRegionHuffmanTables({
  required final int huffmanFs,
  required final int huffmanDs,
  required final int huffmanDt,
  required final bool refinement,
  required final List<int> referredTo,
  required final Map<int, Jbig2HuffmanTable> customTables,
  required final int numberOfSymbols,
  required final Jbig2BitReader reader,
}) {
  // 7.4.3.1.7 Symbol ID Huffman table decoding

  // Read code lengths for RUNCODEs 0...34.
  final codes = <_HuffmanLine>[
    for (var i = 0; i <= 34; i++) _HuffmanLine(<int>[i, reader.readBits(4), 0, 0]),
  ];
  // Assign Huffman codes for RUNCODEs.
  final runCodesTable = Jbig2HuffmanTable(
    codes.map((final l) => <int>[l.rangeLow, l.prefixLength, l.rangeLength, l.prefixCode]).toList(),
  );

  // Read a Huffman code using the assignment above.
  // Interpret the RUNCODE codes and the additional bits (if any).
  codes.clear();
  for (var i = 0; i < numberOfSymbols;) {
    final codeLength = runCodesTable.decode(reader);
    if (codeLength == null) {
      throw const PdfException('JBIG2 error: OOB in symbol ID table.');
    }
    if (codeLength >= 32) {
      int repeatedLength;
      int numberOfRepeats;
      switch (codeLength) {
        case 32:
          if (i == 0) {
            throw const PdfException('JBIG2 error: no previous value in symbol ID table.');
          }
          numberOfRepeats = reader.readBits(2) + 3;
          repeatedLength = codes[i - 1].prefixLength;
        case 33:
          numberOfRepeats = reader.readBits(3) + 3;
          repeatedLength = 0;
        case 34:
          numberOfRepeats = reader.readBits(7) + 11;
          repeatedLength = 0;
        default:
          throw const PdfException('JBIG2 error: invalid code length in symbol ID table.');
      }
      for (var j = 0; j < numberOfRepeats; j++) {
        codes.add(_HuffmanLine(<int>[i, repeatedLength, 0, 0]));
        i++;
      }
    } else {
      codes.add(_HuffmanLine(<int>[i, codeLength, 0, 0]));
      i++;
    }
  }
  reader.byteAlign();
  final symbolIDTable = Jbig2HuffmanTable(
    codes.map((final l) => <int>[l.rangeLow, l.prefixLength, l.rangeLength, l.prefixCode]).toList(),
  );

  // 7.4.3.1.6 Text region segment Huffman table selection

  var customIndex = 0;
  Jbig2HuffmanTable tableFirstS;
  switch (huffmanFs) {
    case 0 || 1:
      tableFirstS = jbig2GetStandardTable(huffmanFs + 6);
    case 3:
      tableFirstS = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
      customIndex++;
    default:
      throw const PdfException('JBIG2 error: invalid Huffman FS selector.');
  }

  Jbig2HuffmanTable tableDeltaS;
  switch (huffmanDs) {
    case 0 || 1 || 2:
      tableDeltaS = jbig2GetStandardTable(huffmanDs + 8);
    case 3:
      tableDeltaS = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
      customIndex++;
    default:
      throw const PdfException('JBIG2 error: invalid Huffman DS selector.');
  }

  Jbig2HuffmanTable tableDeltaT;
  switch (huffmanDt) {
    case 0 || 1 || 2:
      tableDeltaT = jbig2GetStandardTable(huffmanDt + 11);
    case 3:
      tableDeltaT = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
      customIndex++;
    default:
      throw const PdfException('JBIG2 error: invalid Huffman DT selector.');
  }

  if (refinement) {
    // Load tables RDW, RDH, RDX and RDY.
    throw const PdfException('JBIG2 error: refinement with Huffman is not supported.');
  }

  return Jbig2TextRegionHuffmanTables(symbolIDTable, tableFirstS, tableDeltaS, tableDeltaT);
}

/// Selects the symbol-dictionary Huffman tables
/// (`getSymbolDictionaryHuffmanTables` in pdf.js).
// pdf.js jbig2.js getSymbolDictionaryHuffmanTables
Jbig2SymbolDictionaryHuffmanTables jbig2GetSymbolDictionaryHuffmanTables({
  required final int huffmanDhSelector,
  required final int huffmanDwSelector,
  required final int bitmapSizeSelector,
  required final int aggregationInstancesSelector,
  required final List<int> referredTo,
  required final Map<int, Jbig2HuffmanTable> customTables,
}) {
  // 7.4.2.1.6 Symbol dictionary segment Huffman table selection

  var customIndex = 0;
  Jbig2HuffmanTable tableDeltaHeight;
  switch (huffmanDhSelector) {
    case 0 || 1:
      tableDeltaHeight = jbig2GetStandardTable(huffmanDhSelector + 4);
    case 3:
      tableDeltaHeight = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
      customIndex++;
    default:
      throw const PdfException('JBIG2 error: invalid Huffman DH selector.');
  }

  Jbig2HuffmanTable tableDeltaWidth;
  switch (huffmanDwSelector) {
    case 0 || 1:
      tableDeltaWidth = jbig2GetStandardTable(huffmanDwSelector + 2);
    case 3:
      tableDeltaWidth = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
      customIndex++;
    default:
      throw const PdfException('JBIG2 error: invalid Huffman DW selector.');
  }

  Jbig2HuffmanTable tableBitmapSize;
  if (bitmapSizeSelector != 0) {
    tableBitmapSize = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
    customIndex++;
  } else {
    tableBitmapSize = jbig2GetStandardTable(1);
  }

  Jbig2HuffmanTable tableAggregateInstances;
  if (aggregationInstancesSelector != 0) {
    tableAggregateInstances = _jbig2GetCustomHuffmanTable(customIndex, referredTo, customTables);
  } else {
    tableAggregateInstances = jbig2GetStandardTable(1);
  }

  return Jbig2SymbolDictionaryHuffmanTables(
    tableDeltaHeight,
    tableDeltaWidth,
    tableBitmapSize,
    tableAggregateInstances,
  );
}

/// Reads a custom Huffman Tables segment
/// (`decodeTablesSegment` in pdf.js), Annex B.2.
// pdf.js jbig2.js decodeTablesSegment
Jbig2HuffmanTable jbig2DecodeTablesSegment(final Uint8List data, final int start, final int end) {
  final flags = data[start];
  final lowestValue = jbig2ReadUint32(data, start + 1);
  final highestValue = jbig2ReadUint32(data, start + 5);
  final reader = Jbig2BitReader(data, start + 9, end);

  final prefixSizeBits = ((flags >> 1) & 7) + 1;
  final rangeSizeBits = ((flags >> 4) & 7) + 1;
  final lines = <List<int>>[];
  int prefixLength;
  int rangeLength;
  var currentRangeLow = lowestValue;

  // Normal table lines
  do {
    prefixLength = reader.readBits(prefixSizeBits);
    rangeLength = reader.readBits(rangeSizeBits);
    lines.add(<int>[currentRangeLow, prefixLength, rangeLength, 0]);
    currentRangeLow += 1 << rangeLength;
  } while (currentRangeLow < highestValue);

  // Lower range table line
  prefixLength = reader.readBits(prefixSizeBits);
  lines.add(<int>[lowestValue - 1, prefixLength, 32, 0, 1]);

  // Upper range table line
  prefixLength = reader.readBits(prefixSizeBits);
  lines.add(<int>[highestValue, prefixLength, 32, 0]);

  if (flags & 1 != 0) {
    // Out-of-band table line
    prefixLength = reader.readBits(prefixSizeBits);
    lines.add(<int>[prefixLength, 0]);
  }

  return Jbig2HuffmanTable(lines);
}
