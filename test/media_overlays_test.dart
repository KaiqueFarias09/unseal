import 'package:e_livre/src/features/media_overlays/utils/parse_media_overlay.dart';
import 'package:test/test.dart';

void main() {
  group('parseMediaOverlay', () {
    test('parses pars with clips, fragments and nested seqs', () {
      const smil = '''
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <seq epub:textref="../text/chapter1.xhtml">
      <par id="p1">
        <text src="../text/chapter1.xhtml#para1"/>
        <audio src="audio/chapter1.mp3" clipBegin="0:00:00.000" clipEnd="0:00:12.500"/>
      </par>
      <par id="p2">
        <text src="../text/chapter1.xhtml#para2"/>
        <audio src="audio/chapter1.mp3" clipBegin="0:00:12.500" clipEnd="0:00:30.250"/>
      </par>
      <seq epub:textref="../text/section2.xhtml">
        <par id="p3">
          <text src="../text/section2.xhtml#s2p1"/>
          <audio src="audio/section2.mp3" clipBegin="00:00.000" clipEnd="9.5s"/>
        </par>
      </seq>
    </seq>
  </body>
</smil>''';

      final document = parseMediaOverlay(smil, smilPath: 'OEBPS/smil/chapter1.smil');

      expect(document.segments, hasLength(3));

      final first = document.segments[0];
      expect(first.sequence, 0);
      expect(first.audioPath, 'OEBPS/smil/audio/chapter1.mp3');
      expect(first.textPath, 'OEBPS/text/chapter1.xhtml');
      expect(first.fragment, 'para1');
      expect(first.clipBegin, Duration.zero);
      expect(first.clipEnd, const Duration(seconds: 12, milliseconds: 500));

      expect(document.segments[1].clipEnd, const Duration(seconds: 30, milliseconds: 250));

      // The nested seq switches the narrated document.
      final nested = document.segments[2];
      expect(nested.textPath, 'OEBPS/text/section2.xhtml');
      expect(nested.fragment, 's2p1');
      expect(nested.audioPath, 'OEBPS/smil/audio/section2.mp3');
      expect(nested.clipEnd, const Duration(milliseconds: 9500));
    });

    test('missing clipEnd plays to the end of the file', () {
      const smil = '''
<smil>
  <body>
    <par>
      <text src="c1.xhtml#p1"/>
      <audio src="audio/a.mp3" clipBegin="1.5s"/>
    </par>
  </body>
</smil>''';
      final document = parseMediaOverlay(smil, smilPath: 'c1.smil');
      expect(document.segments.single.clipBegin, const Duration(milliseconds: 1500));
      expect(document.segments.single.clipEnd, isNull);
    });

    test('fragment-only text srcs inherit the seq document', () {
      const smil = '''
<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <seq epub:textref="text/c1.xhtml">
      <par>
        <text src="#p1"/>
        <audio src="a.mp3" clipBegin="0s" clipEnd="2s"/>
      </par>
      <par>
        <text src="text/c1.xhtml#p2"/>
        <audio src="a.mp3" clipBegin="2s" clipEnd="4s"/>
      </par>
    </seq>
  </body>
</smil>''';
      final document = parseMediaOverlay(smil, smilPath: 'c1.smil');
      expect(document.segments[0].textPath, 'text/c1.xhtml');
      expect(document.segments[0].fragment, 'p1');
      expect(document.segments[1].textPath, 'text/c1.xhtml');
      expect(document.segments[1].fragment, 'p2');
    });
  });

  group('parseSmilClock', () {
    test('spec clock forms', () {
      expect(parseSmilClock('0:00:21.000'), const Duration(seconds: 21));
      expect(
        parseSmilClock('0:01:30.250'),
        const Duration(minutes: 1, seconds: 30, milliseconds: 250),
      );
      expect(parseSmilClock('00:09.5'), const Duration(milliseconds: 9500));
      expect(parseSmilClock('12.5s'), const Duration(milliseconds: 12500));
      expect(parseSmilClock('450ms'), const Duration(milliseconds: 450));
      expect(parseSmilClock('2min'), const Duration(minutes: 2));
      expect(parseSmilClock('1h'), const Duration(hours: 1));
      expect(parseSmilClock('21'), const Duration(seconds: 21));
    });

    test('junk returns null', () {
      expect(parseSmilClock(null), isNull);
      expect(parseSmilClock(''), isNull);
      expect(parseSmilClock('soon'), isNull);
    });
  });
}
