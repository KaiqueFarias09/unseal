import 'dart:typed_data';
import 'package:unseal/src/features/pdf/codec/jpeg2000/jpx_dwt.dart';

void main() {
  // 4x4, one level. LL = [[1,2],[3,4]], HL=[[10,20],[30,40]],
  // LH=[[100,200],[300,400]], HH=[[7,8],[9,10]] in OpenJPEG layout:
  // rows 0-1: LL row0, LL row1 then HL? NO: buffer rows 0..1 = LL rows,
  // cols 2..3 of rows 0..1 = HL; rows 2..3 cols 0..1 = LH, cols 2..3 = HH.
  // Wait: OpenJPEG layout: row = [LL row | HL row], bottom rows = [LH | HH].
  final buffer = Int32List(16);
  // row 0: LL[0][0]=1, LL[0][1]=2, HL[0][0]=10, HL[0][1]=20
  buffer[0] = 1;
  buffer[1] = 2;
  buffer[2] = 10;
  buffer[3] = 20;
  // row 1: LL[1][0]=3, LL[1][1]=4, HL[1][0]=30, HL[1][1]=40
  buffer[4] = 3;
  buffer[5] = 4;
  buffer[6] = 30;
  buffer[7] = 40;
  // row 2: LH[0][0]=100, LH[0][1]=200, HH[0][0]=7, HH[0][1]=8
  buffer[8] = 100;
  buffer[9] = 200;
  buffer[10] = 7;
  buffer[11] = 8;
  // row 3: LH[1][0]=300, LH[1][1]=400, HH[1][0]=9, HH[1][1]=10
  buffer[12] = 300;
  buffer[13] = 400;
  buffer[14] = 9;
  buffer[15] = 10;

  JpxDwt.inverse(
    buffer: buffer,
    irreversible: false,
    resolutionBounds: [(0, 0, 2, 2), (0, 0, 4, 4)],
    width: 4,
  );
  for (var row = 0; row < 4; row++) {
    // Dev probe, not a test assertion: ignore the print lint.
    // ignore: avoid_print
    print('row $row: ${buffer.sublist(row * 4, row * 4 + 4)}');
  }
}
