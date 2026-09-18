import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Edge-case regression tests for [DocumentTextScanner.scan] and its memoized
/// accessor [documentTextOf].
///
/// The expected values were derived from the original multi-pass
/// regex pipeline before the single-pass rewrite and must stay
/// byte-identical: search and CFI offsets are stable across versions
/// only while this string space does not change.
void main() {
  group('documentText edge cases', () {
    group('body extraction', () {
      test('keeps only the inner body, attributes included', () {
        expect(
          DocumentTextScanner(
            '<html><head><title>T</title></head>'
            '<body class="chapter" data-x="1"><p>inner</p></body></html>',
          ).scan(),
          'inner',
        );
      });

      test('matches body tags case-insensitively', () {
        expect(DocumentTextScanner('<BODY><P>UP</P></BODY>').scan(), 'UP');
      });

      test('falls back to the whole source without a closing body', () {
        expect(DocumentTextScanner('<body><p>never closed').scan(), 'never closed');
        expect(DocumentTextScanner('x</body>y').scan(), 'xy');
      });

      test('cuts at the last </body> like the old greedy pipeline', () {
        expect(DocumentTextScanner('<body><p>a</p></body><body><p>b</p></body>').scan(), 'ab');
        expect(DocumentTextScanner('intro<body>inner</body>tail').scan(), 'inner');
      });

      test('skips a body tag that never closes before the next one', () {
        expect(DocumentTextScanner('a<body b < c>inner</body>z').scan(), 'inner');
      });
    });

    group('comments', () {
      test('removes comments and everything up to the first -->', () {
        expect(DocumentTextScanner('a<!-- x -->b').scan(), 'ab');
        expect(DocumentTextScanner('<!-- <!-- inner --> outer -->tail').scan(), ' outer -->tail');
        expect(DocumentTextScanner('a<!--1-->b<!--2-->c').scan(), 'abc');
        expect(DocumentTextScanner('<!---->').scan(), '');
      });

      test('abruptly closed comments are declarations and vanish', () {
        expect(DocumentTextScanner('<!-->').scan(), '');
        expect(DocumentTextScanner('<!--->').scan(), '');
      });

      test('unterminated comments stay literal without a >, else are eaten', () {
        expect(DocumentTextScanner('x<!-- y').scan(), 'x<!-- y');
        expect(DocumentTextScanner('<!-- a > b -->tail').scan(), 'tail');
      });

      test('a script block is removed even when it sits in a comment', () {
        expect(DocumentTextScanner('<!-- <script>x</script> -->').scan(), '');
        expect(DocumentTextScanner('<!-- a <script>b-->c</script> d -->').scan(), '');
      });
    });

    group('CDATA sections', () {
      test(r'collapse to the literal $1 artifact of the old pipeline', () {
        expect(DocumentTextScanner('<p><![CDATA[<b>raw</b>]]></p>').scan(), r'$1');
        expect(DocumentTextScanner('<![CDATA[&amp;]]>').scan(), r'$1');
        expect(DocumentTextScanner('<![CDATA[x]]>ok').scan(), r'$1ok');
      });

      test('unterminated CDATA without > stays literal, with > is a declaration', () {
        expect(DocumentTextScanner('<![CDATA[unclosed').scan(), '<![CDATA[unclosed');
        expect(DocumentTextScanner('<![CDATA[a > b').scan(), ' b');
      });

      test('the first ]]> ends the section, inner CDATA is content', () {
        expect(DocumentTextScanner('<![CDATA[<![CDATA[x]]>]]>').scan(), r'$1]]>');
        expect(DocumentTextScanner('<![CDATA[a]]]>b').scan(), '\$1b');
      });

      test('entity halves glue across the CDATA span', () {
        expect(DocumentTextScanner('&<![CDATA[amp]]>;').scan(), r'&$1;');
        expect(DocumentTextScanner('&<![CDATA[amp;]]>').scan(), r'&$1');
      });
    });

    group('unterminated markup', () {
      test('a lone < stays literal', () {
        expect(DocumentTextScanner('abc <def').scan(), 'abc <def');
        expect(DocumentTextScanner('a < b').scan(), 'a < b');
        expect(DocumentTextScanner('<!x no gt ever').scan(), '<!x no gt ever');
      });

      test('a < before a non-tag character stays literal text', () {
        // HTML5 tokenizer rule: only <letter> and </ open markup, so a
        // browser DOM keeps these strings intact — and so does the
        // offset space now.
        expect(DocumentTextScanner('a < b > c').scan(), 'a < b > c');
        expect(DocumentTextScanner('2 < 3 and 5 > 4').scan(), '2 < 3 and 5 > 4');
        expect(DocumentTextScanner('a<<b>c').scan(), 'a<c');
        // The second < still opens real markup (and a removed block):
        expect(DocumentTextScanner('<<script>x</script>p>').scan(), '<p>');
        expect(DocumentTextScanner('<<!--x-->p>').scan(), '<p>');
      });
    });

    group('entities', () {
      test('decodes named and numeric references once', () {
        expect(
          DocumentTextScanner('a &amp; b &lt;tag&gt; caf&eacute; a&nbsp;b').scan(),
          'a & b <tag> caf\xE9 a\xA0b',
        );
        expect(DocumentTextScanner('&#65;&#x42;').scan(), 'AB');
        expect(DocumentTextScanner('&#X41;').scan(), 'A');
        expect(DocumentTextScanner('&#x4a;&#x4A;').scan(), 'JJ');
        expect(DocumentTextScanner('&#x1F4DA;').scan(), '\u{1F4DA}');
        expect(DocumentTextScanner('&amp;lt;').scan(), '&lt;');
        expect(DocumentTextScanner('&#38;#60;').scan(), '&#60;');
      });

      test('maps NUL and C1 controls to the replacement character', () {
        expect(DocumentTextScanner('&#145;&#146;&#147;').scan(), '\uFFFD\uFFFD\uFFFD');
        expect(DocumentTextScanner('a&#0;b').scan(), 'a\uFFFDb');
        expect(DocumentTextScanner('&#x8f;').scan(), '\uFFFD');
      });

      test('out-of-range numerics stay literal', () {
        expect(DocumentTextScanner('&#1114112;').scan(), '&#1114112;');
        expect(DocumentTextScanner('&#x110000;').scan(), '&#x110000;');
        expect(DocumentTextScanner('&#1114111;&#x10FFFF;').scan(), '\u{10FFFF}\u{10FFFF}');
        expect(DocumentTextScanner('&#99999999;').scan(), '&#99999999;');
        expect(DocumentTextScanner('&#1234567;').scan(), '&#1234567;');
      });

      test('unknown or malformed references stay literal', () {
        expect(DocumentTextScanner('a &nosuchentity; b').scan(), 'a &nosuchentity; b');
        expect(DocumentTextScanner('&a;').scan(), '&a;');
        expect(DocumentTextScanner('&#;').scan(), '&#;');
        expect(DocumentTextScanner('&#x;').scan(), '&#x;');
        expect(DocumentTextScanner('&#x41').scan(), '&#x41');
        expect(DocumentTextScanner('&#65').scan(), '&#65');
        expect(DocumentTextScanner('&amp').scan(), '&amp');
        expect(DocumentTextScanner('a & b').scan(), 'a & b');
        expect(DocumentTextScanner('&&amp;&;').scan(), '&&&;');
        expect(DocumentTextScanner('&amp;&lt;&gt;').scan(), '&<>');
        expect(DocumentTextScanner('&AMP;&Amp;').scan(), '&AMP;&Amp;');
        expect(
          DocumentTextScanner('&thisisaverylongentitynamethatoverruns;').scan(),
          '&thisisaverylongentitynamethatoverruns;',
        );
      });

      test('entities glued by removed markup still decode', () {
        expect(DocumentTextScanner('&am<p></p>p;').scan(), '&');
        expect(DocumentTextScanner('&am<script></script>p;').scan(), '&');
        expect(DocumentTextScanner('&am<!-- x -->p;').scan(), '&');
        expect(DocumentTextScanner('&am<!DOCTYPE x>p;').scan(), '&');
        expect(DocumentTextScanner('&am<![CDATA[]]>p;').scan(), r'&am$1p;');
        expect(DocumentTextScanner('&#<p>6</p>5;').scan(), 'A');
        expect(DocumentTextScanner('&#<p>x</p>41;').scan(), 'A');
      });
    });

    group('script and style blocks', () {
      test('removes complete blocks regardless of tag case', () {
        expect(DocumentTextScanner('a<script>bad()</script>b').scan(), 'ab');
        expect(DocumentTextScanner('<SCRIPT>bad()</SCRIPT>ok').scan(), 'ok');
        expect(DocumentTextScanner('<SCRIPT>bad()</script>ok').scan(), 'ok');
        expect(DocumentTextScanner('<script>bad()</SCRIPT>ok').scan(), 'ok');
        expect(
          DocumentTextScanner('<script type="text/javascript" src="a.js">bad()</script>t').scan(),
          't',
        );
        expect(DocumentTextScanner('a<style>p{color:red}</style>b').scan(), 'ab');
      });

      test('a closing tag inside a string does not end the block early', () {
        expect(DocumentTextScanner('<script>var s = "</style>";</script>ok').scan(), 'ok');
        expect(DocumentTextScanner('<style>a</script>b</style>ok').scan(), 'ok');
        expect(
          DocumentTextScanner('<script><!--\ndocument.write("-->")\n// --></script>ok').scan(),
          'ok',
        );
      });

      test('script look-alikes fall back to plain tag removal', () {
        expect(DocumentTextScanner('a<script>x</p>y').scan(), 'axy');
        expect(DocumentTextScanner('<scriptx>not a block</scriptx>ok').scan(), 'not a blockok');
        expect(DocumentTextScanner('a<script/>b').scan(), 'ab');
        expect(DocumentTextScanner('a<script src="x>y">z</script>b').scan(), 'ab');
        expect(DocumentTextScanner('<script>1()</script>x<script>2()</script>y').scan(), 'xy');
      });
    });

    group('declarations', () {
      test('removes doctypes, PIs and other <!…> spans', () {
        expect(DocumentTextScanner('<!DOCTYPE html><p>x</p>').scan(), 'x');
        expect(DocumentTextScanner('<?xml version="1.0"?><p>x</p>').scan(), 'x');
        expect(DocumentTextScanner('<![CDATA[<!y>]]>z').scan(), '\$1z');
      });

      test('a tag opener is removed while a later declaration still closes', () {
        // The '</sec' opener never finds a tag '>' (the declaration's
        // '>' is consumed by pass 4 first), yet the declaration itself
        // is still removed.
        expect(DocumentTextScanner('</sec<!tion>').scan(), '</sec');
      });
    });

    group('whitespace', () {
      test('is kept as-is', () {
        expect(DocumentTextScanner('<p>line1\n   line2\ttab</p>').scan(), 'line1\n   line2\ttab');
      });
    });
  });

  group('documentTextOf memoization', () {
    test('returns identical strings on repeated access', () {
      final file = TextFile(
        name: 'chapter1.html',
        type: 'xhtml',
        path: 'chapter1.html',
        content: '<html><body><p>a&amp;b</p></body></html>',
      );
      final first = documentTextOf(file);
      expect(first, 'a&b');
      expect(documentTextOf(file), same(first));
    });

    test('computes the same canonical space as documentText', () {
      final file = TextFile(
        name: 'chapter1.html',
        type: 'xhtml',
        path: 'chapter1.html',
        content: '<body><p>caf&eacute; &#8212; text</p></body>',
      );
      expect(documentTextOf(file), DocumentTextScanner(file.content).scan());
      expect(documentTextOf(file), 'caf\xE9 \u2014 text');
    });

    test('a second search returns identical results through the memo', () {
      final book = _epubFixture('<html><body><p>needle in the haystack</p></body></html>');
      final first = book.search('needle');
      final second = book.search('needle');
      expect(first.matches, hasLength(1));
      expect(second.matches, hasLength(1));
      expect(second.matches.single.start, first.matches.single.start);
      expect(second.matches.single.end, first.matches.single.end);
      expect(second.matches.single.snippet, first.matches.single.snippet);
      // The memo retains the entry: repeated accessor calls hand back
      // the same string instance instead of recomputing it.
      final file = book.files.html.single;
      expect(documentTextOf(file), same(documentTextOf(file)));
    });
  });
}

/// Builds a minimal in-memory EPUB book around one HTML section.
Book _epubFixture(final String html) {
  return EpubBook(
    navigation: Navigation(title: 'Contents', navPoints: const []),
    files: Files(
      images: const [],
      css: const [],
      html: [TextFile(name: 'chapter1.html', type: 'xhtml', path: 'chapter1.html', content: html)],
      fonts: const [],
      others: const [],
    ),
    cover: BinaryFile.empty(),
    package: Epub2Package(
      xmlns: null,
      uniqueIdentifier: 'uid',
      version: '2.0',
      metadata: Epub2Metadata(
        rights: const [],
        contributor: null,
        creator: 'Test Author',
        publisher: null,
        title: 'Fixture',
        date: '2024-01-01',
        language: 'en',
        subject: null,
        description: null,
        identifiers: const ['test-id-1'],
        uniqueIdentifierValue: 'test-id-1',
      ),
      manifest: Manifest(
        items: [ManifestItem(path: 'chapter1.html', id: 'c1', mediaType: 'application/xhtml+xml')],
      ),
      spine: Spine(tocId: null, items: const ['c1']),
      guide: null,
    ),
  );
}
