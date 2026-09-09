import '../header/mobi_header.dart';
import '../header/pdb_header.dart';
import 'mobi8_markup.dart';
import 'mobi8_resources.dart';
import 'mobi8_structure.dart';
import 'mobi_text.dart';

export 'mobi8_markup.dart' show Mobi8Assembly;
export 'mobi8_structure.dart' show Mobi8Part;

/// Assembles KF8 (AZW3) books from raw records.
///
/// Coordinates text extraction, index/skeleton interpretation, resource
/// decoding, and Kindle markup expansion through dedicated modules.
class Mobi8Reader {
  /// Creates a reader over [pdb] records with the KF8 [header].
  ///
  /// [textOffset] is the first text record of the KF8 half and
  /// [resourceOffsets] are the (start, end) record ranges holding
  /// resources (two ranges for joint MOBI 6 + KF8 files).
  const Mobi8Reader({
    required this.pdb,
    required this.header,
    required this.textOffset,
    required this.resourceOffsets,
    this.huffOffsetOverride,
  });

  /// The KF8 MOBI header.
  final MobiHeader header;

  /// PDB record access.
  final PdbRecordAccess pdb;

  /// Resource record ranges.
  final List<(int, int)> resourceOffsets;

  /// First text record index of the KF8 half.
  final int textOffset;

  /// Rebases the HUFF section for joint MOBI 6 + KF8 files.
  final int? huffOffsetOverride;

  /// Runs the full assembly.
  Mobi8Assembly assemble() {
    final rawText = extractMobiText(
      recordAt: pdb.record,
      recordCount: pdb.count,
      textOffset: textOffset,
      header: header,
      huffOffsetOverride: huffOffsetOverride,
    );
    final structure = Mobi8Structure.read(
      pdb: pdb,
      header: header,
      textOffset: textOffset,
      rawText: rawText,
    );
    final resources = Mobi8Resources.extract(pdb: pdb, resourceOffsets: resourceOffsets);

    return Mobi8MarkupAssembler(
      header: header,
      structure: structure,
      resources: resources,
    ).assemble();
  }
}
