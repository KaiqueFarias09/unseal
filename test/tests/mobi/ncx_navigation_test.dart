import 'package:e_livre/src/features/mobi/index/ncx_reader.dart';
import 'package:test/test.dart';

NcxEntry _entry({
  required final int num,
  final int hlvl = 0,
  final int parent = -1,
  final String text = '',
}) {
  return NcxEntry()
    ..num = num
    ..hlvl = hlvl
    ..parent = parent
    ..text = text;
}

void main() {
  group('buildNavigation', () {
    test('flattens single-level entries into roots', () {
      final navigation = buildNavigation([
        _entry(num: 0, text: 'One'),
        _entry(num: 1, text: 'Two'),
      ]);
      expect(navigation.navPoints.map((final p) => p.label), ['One', 'Two']);
      expect(navigation.navPoints.every((final p) => p.subNavPoints.isEmpty), isTrue);
    });

    test('nests children under their parent entry', () {
      final navigation = buildNavigation([
        _entry(num: 0, text: 'Part I'),
        _entry(num: 1, hlvl: 1, parent: 0, text: 'Chapter 1'),
        _entry(num: 2, hlvl: 1, parent: 0, text: 'Chapter 2'),
        _entry(num: 3, text: 'Part II'),
      ]);
      expect(navigation.navPoints.map((final p) => p.label), ['Part I', 'Part II']);
      expect(navigation.navPoints.first.subNavPoints.map((final p) => p.label), [
        'Chapter 1',
        'Chapter 2',
      ]);
    });

    test('supports deeper hierarchies', () {
      final navigation = buildNavigation([
        _entry(num: 0, text: 'Part'),
        _entry(num: 1, hlvl: 1, parent: 0, text: 'Chapter'),
        _entry(num: 2, hlvl: 2, parent: 1, text: 'Scene'),
      ]);
      final chapter = navigation.navPoints.first.subNavPoints.single;
      expect(chapter.subNavPoints.single.label, 'Scene');
    });

    test('orphans fall back to the roots', () {
      final navigation = buildNavigation([
        _entry(num: 0, text: 'Real root'),
        _entry(num: 1, hlvl: 1, parent: 99, text: 'Orphan'),
      ]);
      expect(navigation.navPoints.map((final p) => p.label), ['Real root', 'Orphan']);
    });

    test('assigns sequential play order across levels', () {
      final navigation = buildNavigation([
        _entry(num: 0, text: 'A'),
        _entry(num: 1, hlvl: 1, parent: 0, text: 'A.1'),
        _entry(num: 2, text: 'B'),
      ]);
      // Entries are numbered per hierarchy level: roots first, then
      // the deeper levels.
      expect(navigation.navPoints.map((final p) => p.playOrder), ['1', '2']);
      expect(navigation.navPoints.first.subNavPoints.single.playOrder, '3');
    });
  });
}
