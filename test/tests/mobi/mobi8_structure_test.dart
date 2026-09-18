import 'dart:typed_data';

import 'package:e_livre/src/features/mobi/exceptions/mobi_exception.dart';
import 'package:e_livre/src/features/mobi/header/mobi_header.dart';
import 'package:e_livre/src/features/mobi/header/pdb_header.dart';
import 'package:e_livre/src/features/mobi/reader/mobi8_structure.dart';
import 'package:test/test.dart';

import 'mobi_fixture_builder.dart';

void main() {
  test('rejects the FDST index when its record has the wrong marker', () {
    final record0 = buildMobiRecord0(mobiVersion: 8, fdstCount: 2);
    ByteData.sublistView(record0).setUint32(0xC0, 1);
    final header = MobiHeader.parse(record0, 'BOOKMOBI');
    final records = _Records(<Uint8List>[record0, Uint8List.fromList('BAD!'.codeUnits)]);

    expect(
      () => Mobi8Structure.read(pdb: records, header: header, textOffset: 1, rawText: Uint8List(0)),
      throwsA(
        isA<MobiException>().having(
          (final error) => error.message,
          'message',
          'KF8 does not have a valid FDST record',
        ),
      ),
    );
  });

  test('removes quoted aid attributes without truncating apostrophes', () {
    final record0 = buildMobiRecord0();
    final structure = Mobi8Structure.read(
      pdb: _Records([record0]),
      header: MobiHeader.parse(record0, 'BOOKMOBI'),
      textOffset: 1,
      rawText: Uint8List(0),
    );

    expect(structure.removeKindleAids('<p aid="reader\'s-anchor">Text</p>'), '<p>Text</p>');
  });
}

final class _Records implements PdbRecordAccess {
  const _Records(this.records);

  final List<Uint8List> records;

  @override
  int get count => records.length;

  @override
  Uint8List record(final int index) => records[index];
}
