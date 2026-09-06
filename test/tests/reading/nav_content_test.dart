import 'package:e_livre/src/features/reading/nav_resolution.dart';
import 'package:test/test.dart';

void main() {
  group('parseNavContent goldens', () {
    test('plain EPUB href: path only', () {
      final parsed = parseNavContent('OEBPS/chapter1.xhtml');
      expect(parsed.path, 'OEBPS/chapter1.xhtml');
      expect(parsed.fragment, isNull);
      expect(parsed.filepos, isNull);
    });

    test('EPUB href with fragment: both kept, split on the first #', () {
      final parsed = parseNavContent('xhtml/halftitle.xhtml#d6e189');
      expect(parsed.path, 'xhtml/halftitle.xhtml');
      expect(parsed.fragment, 'd6e189');
      expect(parsed.filepos, isNull);
    });

    test('fragment containing a second # stays whole', () {
      final parsed = parseNavContent('chapter.xhtml#frag#extra');
      expect(parsed.path, 'chapter.xhtml');
      expect(parsed.fragment, 'frag#extra');
    });

    test('bare fragment: no path', () {
      final parsed = parseNavContent('#contents_1');
      expect(parsed.path, isNull);
      expect(parsed.fragment, 'contents_1');
      expect(parsed.filepos, isNull);
    });

    test('MOBI filepos fragment: numeric position plus fragment text', () {
      final parsed = parseNavContent('#filepos471');
      expect(parsed.path, isNull);
      expect(parsed.fragment, 'filepos471');
      expect(parsed.filepos, 471);
    });

    test('bare MOBI filepos without #', () {
      final parsed = parseNavContent('filepos42');
      expect(parsed.path, isNull);
      expect(parsed.fragment, isNull);
      expect(parsed.filepos, 42);
    });

    test('percent-encoded hrefs are kept as written', () {
      final parsed = parseNavContent('chapter%201.xhtml#note%201');
      expect(parsed.path, 'chapter%201.xhtml');
      expect(parsed.fragment, 'note%201');
    });

    test('trailing hash: empty fragment is no fragment', () {
      final parsed = parseNavContent('chapter.xhtml#');
      expect(parsed.path, 'chapter.xhtml');
      expect(parsed.fragment, isNull);
    });

    test('whitespace is trimmed', () {
      final parsed = parseNavContent('  chapter.xhtml#frag  ');
      expect(parsed.path, 'chapter.xhtml');
      expect(parsed.fragment, 'frag');
    });

    test('empty content parses to an empty shape', () {
      final parsed = parseNavContent('');
      expect(parsed.path, isNull);
      expect(parsed.fragment, isNull);
      expect(parsed.filepos, isNull);
    });

    test('unknown shape: whole string becomes the path', () {
      final parsed = parseNavContent('not a link at all');
      expect(parsed.path, 'not a link at all');
      expect(parsed.fragment, isNull);
      expect(parsed.filepos, isNull);
    });

    test('filepos-shaped path keeps the number only', () {
      final parsed = parseNavContent('#filepos0012');
      expect(parsed.filepos, 12);
    });
  });
}
