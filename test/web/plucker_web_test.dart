@TestOn('browser')
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  test('Plucker zlib text opens in the browser', () async {
    final bytes = Uint8List.fromList(
      base64Decode(
        'UGx1Y2tlciBTYW1wbGUAAAAAAAAAAAAAAAAAAAAAAAAAAAAB5tm/PubZvz4AAAAAAAAAAAAAAAAAAAAARGF0YVBsa3IAAAAAAAAAAAADAAAAaAAAAAEAAAB2AAAAAgAAARAAAAAFAAAAAQACAAIAAAACAAQABQACAAUAlQEAABQAAwAuAAIALwACAA8AAwAVAAJ4nE2MMQ7CMBAEF1cUNPnBtWlc0yOokcwHDvsUWznsyDGC52NCw1a7o9Fi2GE0V336WSo5fiwqHcChZ8Ql1bXRwpWnykukV2qRqnDguwo1eTe7qU58yeFP5L6YcICB0eJZSVOesbcYfue3KHTOYesnLWvK01cRiyN9APTKKCAABQAAABAKAAACAAEAAQBqAAYAAubZvz4=',
      ),
    );
    final book = await Unseal.read(bytes);
    expect(book.format, BookFormat.plucker);
    expect(book.files.html.single.content, contains('Closing line.'));
    expect((await Unseal.readMetadata(bytes)).title, 'Plucker Sample');
  });

  test('Plucker packed grayscale and palette bitmaps parse in Chrome', () async {
    final bytes = Uint8List.fromList(
      base64Decode(
        'UGx1Y2tlciBCaXRtYXAgRm9ybWF0cwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARGF0YVBsa3IAAAAAAAAAAAAFAAAAdgAAAAAAAAB8AAAAAAAAAJYAAAAAAAAAsgAAAAAAAADSAAAAAAABAAEAAAACAAEADgAAAA4AAEJpdG1hcCBmaXh0dXJlAAsAAAAUAgAABQACAAIAAAIBAAAA/wAAG0DkwAAMAAAAGAIAAAUAAgAEAAAEAQAAAP8AAAF48AD+gQAAAA0AAAAUAgAAAwABAAQAAAgBAAAA/wAA1tfYAA==',
      ),
    );
    final book = await Unseal.read(bytes);
    expect(book.files.images, hasLength(3));

    List<int> rows(final Uint8List png) {
      final idatLength = ByteData.sublistView(png).getUint32(33);
      return const ZLibDecoder().decodeBytes(png.sublist(41, 41 + idatLength));
    }

    expect(rows(book.files.images[0].content), <int>[
      0,
      255,
      170,
      85,
      0,
      170,
      0,
      0,
      85,
      170,
      255,
      0,
    ]);
    expect(rows(book.files.images[1].content), <int>[
      0,
      255,
      238,
      136,
      119,
      0,
      0,
      0,
      17,
      119,
      238,
      255,
    ]);
    expect(rows(book.files.images[2].content), <int>[0, 0, 51, 0, 0, 0, 0, 17, 17, 17]);
  });

  test('Plucker custom palettes and RGB565 direct color parse in Chrome', () async {
    final encoded =
        '''
UGx1Y2tlciBQYWxtIENvbG9yIEZvcm1hdHMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAARGF0YVBsa3IAAAAAAAAAAAAFAAAAdgAAAAAAAAB8AAAAAAAAAKEAAAAAAAAA/wAAAAAAAAUdAAAAAAABAAEAAAACAAEAGQAAABkAAFBhbG0gY29sb3IgYml0bWFwIGZpeHR1cmUAFQAAAFYCAAADAAIAAkAABAEAAAD/AAAAEA9H2fAO/kLxDbWr8gxsFPMLI330Ctrm9QmRT/YISLj3B/8h+Aa2ivkFbfP6BCRc+wPbxfwCki79AUmX/gAAAP8CUPcwABYAAAQWAgAAAwABAARAAAgBAAAA/wAAAQD/t2kA/m7SAf0lOwL83KQD+5MNBPpKdgX5Ad8G+LhIB/dvsQj2JhoJ9d2DCvSU7AvzS1UM8gK+DfG5Jw7wcJAP7yf5EO7eYhHtlcsS7Ew0E+sDnRTqugYV6XFvFugo2Bfn30EY5paqGeVNExrkBHwb47vlHOJyTh3hKbce4OAgH9+XiSDeTvIh3QVbIty8xCPbcy0k2iqWJdnh/ybYmGgn10/RKNYGOinVvaMq1HQMK9MrdSzS4t4t0ZlHLtBQsC/PBxkwzr6CMc116zLMLFQzy+O9NMqaJjXJUY82yAj4N8e/YTjGdso5xS0zOsTknDvDmwU8wlJuPcEJ1z7AwEA/v3epQL4uEkG95XtCvJzkQ7tTTUS6CrZFucEfRrh4iEe3L/FItuZaSbWdw0q0VCxLswuVTLLC/k2xeWdOsDDQT6/nOVCunqJRrVULUqwMdFOrw91UqnpGVakxr1ao6BhXp5+BWKZW6lmlDVNapMS8W6N7JVyiMo5doen3XqCgYF+fV8lgng4yYZ3Fm2KcfARjmzNtZJrq1mWZoT9mmFioZ5cPEWiWxnpplX3japQ0TGuT67VskqIebZFZh26QEPBvj8dZcI5+wnGNNStyjOyUc4uj/XSKWmZ1iRHPdojIOHeHf6F4hjYKeYXtc3qEpNx7g1tFfIISrn2ByRd+gICAf3836YB+7lKBfaW7gnxcJIN7E42Eesr2hXmBX4Z4OMiHd+8xiHammol1XQOKdBRsi3PL1Yxygj6NcTmnjnDwEI9vp3mQbl7ikW0VS5JszLSTa4MdlGo6hpVp8e+WaKhYl2dfwZhmFiqZZc2TmmSE/JtjO2WcYvLOnWGpN55gYKCfXxcJoF7OcqFdhduiXDxEo1vzraRaqhalWWF/plgY6KdXz1GoVoa6qVU9I6pU9IyrU6v1rFJiXq1RGceuUNAwr0+HmbBOPgKxTfVrskys1LNLYz20ShqmtUnRD7ZIiHi3Rz/huEb2SrlFrbO6RGQcu0MbhbxC0u69QYlXvkBAwL8/9ynAPq6SwT1l+8I8HGTDO9PNxDqKNsU5QZ/GOPgIxzevccg2ZtrJNR1DyjTUrMszixXMMkJ+zTH5584wsFDPL2e50C4eItEt1YvSLIz00ytDXdQq+sbVKbEv1ihomNcnHwHYJtZq2SWN09okRDzbI/ul3CKyDt0haXfeICDg3x/XSeAejrLhHUUb4hz8hOMbs+3kGmpW5Rkhv+YY2CjnF4+R6BZG+ukV/WPqFLTM6xNrNewSIp7tEdkH7hCQcO8PR9nwDv5C8Q21q/IMbBTzCyN99Ara5vUJkU/2CEi49wf/IfgGtor5BW3z+gQkXPsD28X8ApIu/QFJl/4AAAD/AID/AAAXAAAAJAIAAAMAAgAGBAAQAQAAAP8AAAUGBQAAAAAA+AAH4AAf//8AAIQQ
'''
            .replaceAll('\n', '');
    final book = await Unseal.read(Uint8List.fromList(base64Decode(encoded)));
    expect(book.files.images, hasLength(3));

    List<int> rows(final Uint8List png) {
      final idatLength = ByteData.sublistView(png).getUint32(33);
      return const ZLibDecoder().decodeBytes(png.sublist(41, 41 + idatLength));
    }

    expect(rows(book.files.images[0].content), <int>[
      0,
      0,
      0,
      255,
      146,
      46,
      253,
      109,
      243,
      250,
      0,
      71,
      217,
      240,
      255,
      33,
      248,
      219,
      197,
      252,
    ]);
    expect(rows(book.files.images[1].content), <int>[0, 0, 0, 255, 128, 128, 127, 183, 105, 0]);
    expect(rows(book.files.images[2].content), <int>[
      0,
      255,
      0,
      0,
      0,
      255,
      0,
      0,
      0,
      255,
      0,
      255,
      255,
      255,
      0,
      0,
      0,
      132,
      130,
      132,
    ]);
  });
}
