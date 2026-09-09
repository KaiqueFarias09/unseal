import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';

/// The PDB record slice the MOBI parser consumed as its header.
///
/// Plain MOBI 6 and standalone KF8 (AZW3) books parse record 0, but a
/// joint MOBI 6 + KF8 file parses the KF8 header found past the
/// BOUNDARY record (EXTH 121), so the wire must cross that slice —
/// crossing raw record 0 would make the receiving side re-parse the
/// wrong half (wrong flavor, wrong chapter and resource indexes).
Uint8List mobiWireRecord0(final Uint8List bytes) {
  final pdb = PdbHeader.parse(bytes);
  final header = MobiHeader.parse(pdb.record(0), pdb.ident);
  if (header.mobiVersion != 8 || header.skelIndex == nullIndex) {
    final k8i = header.exth?.kf8HeaderIndex;
    if (k8i != null && k8i >= 1 && k8i - 1 < pdb.count) {
      final boundary = pdb.record(k8i - 1);
      if (boundary.length >= 8 && String.fromCharCodes(boundary.sublist(0, 8)) == 'BOUNDARY') {
        return pdb.record(k8i);
      }
    }
  }

  return pdb.record(0);
}
