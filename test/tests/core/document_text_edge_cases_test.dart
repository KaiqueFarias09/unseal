import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Edge-case regression tests for [documentText] and its memoized
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
          documentText(
            '<html><head><title>T</title></head>'
            '<body class="chapter" data-x="1"><p>inner</p></body></html>',
          ),
          'inner',
        );
      });

      test('matches body tags case-insensitively', () {
        expect(documentText('<BODY><P>UP</P></BODY>'), 'UP');
      });

      test('falls back to the whole source without a closing body', () {
        expect(documentText('<body><p>never closed'), 'never closed');
        expect(documentText('x</body>y'), 'xy');
      });

      test('cuts at the last </body> like the old greedy pipeline', () {
        expect(documentText('<body><p>a</p></body><body><p>b</p></body>'), 'ab');
        expect(documentText('intro<body>inner</body>tail'), 'inner');
      });

      test('skips a body tag that never closes before the next one', () {
        expect(documentText('a<body b < c>inner</body>z'), 'inner');
      });
    });

    group('comments', () {
      test('removes comments and everything up to the first -->', () {
        expect(documentText('a<!-- x -->b'), 'ab');
        expect(documentText('<!-- <!-- inner --> outer -->tail'), ' outer -->tail');
        expect(documentText('a<!--1-->b<!--2-->c'), 'abc');
        expect(documentText('<!---->'), '');
      });

      test('abruptly closed comments are declarations and vanish', () {
        expect(documentText('<!-->'), '');
        expect(documentText('<!--->'), '');
      });

      test('unterminated comments stay literal without a >, else are eaten', () {
        expect(documentText('x<!-- y'), 'x<!-- y');
        expect(documentText('<!-- a > b -->tail'), 'tail');
      });

      test('a script block is removed even when it sits in a comment', () {
        expect(documentText('<!-- <script>x</script> -->'), '');
        expect(documentText('<!-- a <script>b-->c</script> d -->'), '');
      });
    });

    group('CDATA sections', () {
      test(r'collapse to the literal $1 artifact of the old pipeline', () {
        expect(documentText('<p><![CDATA[<b>raw</b>]]></p>'), r'$1');
        expect(documentText('<![CDATA[&amp;]]>'), r'$1');
        expect(documentText('<![CDATA[x]]>ok'), r'$1ok');
      });

      test('unterminated CDATA without > stays literal, with > is a declaration', () {
        expect(documentText('<![CDATA[unclosed'), '<![CDATA[unclosed');
        expect(documentText('<![CDATA[a > b'), ' b');
      });

      test('the first ]]> ends the section, inner CDATA is content', () {
        expect(documentText('<![CDATA[<![CDATA[x]]>]]>'), r'$1]]>');
        expect(documentText('<![CDATA[a]]]>b'), '\$1b');
      });

      test('entity halves glue across the CDATA span', () {
        expect(documentText('&<![CDATA[amp]]>;'), r'&$1;');
        expect(documentText('&<![CDATA[amp;]]>'), r'&$1');
      });
    });

    group('unterminated markup', () {
      test('a lone < stays literal', () {
        expect(documentText('abc <def'), 'abc <def');
        expect(documentText('a < b'), 'a < b');
        expect(documentText('<!x no gt ever'), '<!x no gt ever');
      });

      test('a tag runs to the next > even across text and markup', () {
        expect(documentText('a < b > c'), 'a  c');
        expect(documentText('2 < 3 and 5 > 4'), '2  4');
        expect(documentText('a<<b>c'), 'ac');
        expect(documentText('<<script>x</script>p>'), '');
        expect(documentText('<<!--x-->p>'), '');
      });
    });

    group('entities', () {
      test('decodes named and numeric references once', () {
        expect(
          documentText('a &amp; b &lt;tag&gt; caf&eacute; a&nbsp;b'),
          'a & b <tag> caf\xE9 a\xA0b',
        );
        expect(documentText('&#65;&#x42;'), 'AB');
        expect(documentText('&#X41;'), 'A');
        expect(documentText('&#x4a;&#x4A;'), 'JJ');
        expect(documentText('&#x1F4DA;'), '\u{1F4DA}');
        expect(documentText('&amp;lt;'), '&lt;');
        expect(documentText('&#38;#60;'), '&#60;');
      });

      test('maps NUL and C1 controls to the replacement character', () {
        expect(documentText('&#145;&#146;&#147;'), '\uFFFD\uFFFD\uFFFD');
        expect(documentText('a&#0;b'), 'a\uFFFDb');
        expect(documentText('&#x8f;'), '\uFFFD');
      });

      test('out-of-range numerics stay literal', () {
        expect(documentText('&#1114112;'), '&#1114112;');
        expect(documentText('&#x110000;'), '&#x110000;');
        expect(documentText('&#1114111;&#x10FFFF;'), '\u{10FFFF}\u{10FFFF}');
        expect(documentText('&#99999999;'), '&#99999999;');
        expect(documentText('&#1234567;'), '&#1234567;');
      });

      test('unknown or malformed references stay literal', () {
        expect(documentText('a &nosuchentity; b'), 'a &nosuchentity; b');
        expect(documentText('&a;'), '&a;');
        expect(documentText('&#;'), '&#;');
        expect(documentText('&#x;'), '&#x;');
        expect(documentText('&#x41'), '&#x41');
        expect(documentText('&#65'), '&#65');
        expect(documentText('&amp'), '&amp');
        expect(documentText('a & b'), 'a & b');
        expect(documentText('&&amp;&;'), '&&&;');
        expect(documentText('&amp;&lt;&gt;'), '&<>');
        expect(documentText('&AMP;&Amp;'), '&AMP;&Amp;');
        expect(
          documentText('&thisisaverylongentitynamethatoverruns;'),
          '&thisisaverylongentitynamethatoverruns;',
        );
      });

      test('entities glued by removed markup still decode', () {
        expect(documentText('&am<p></p>p;'), '&');
        expect(documentText('&am<script></script>p;'), '&');
        expect(documentText('&am<!-- x -->p;'), '&');
        expect(documentText('&am<!DOCTYPE x>p;'), '&');
        expect(documentText('&am<![CDATA[]]>p;'), r'&am$1p;');
        expect(documentText('&#<p>6</p>5;'), 'A');
        expect(documentText('&#<p>x</p>41;'), 'A');
      });
    });

    group('script and style blocks', () {
      test('removes complete blocks regardless of tag case', () {
        expect(documentText('a<script>bad()</script>b'), 'ab');
        expect(documentText('<SCRIPT>bad()</SCRIPT>ok'), 'ok');
        expect(documentText('<SCRIPT>bad()</script>ok'), 'ok');
        expect(documentText('<script>bad()</SCRIPT>ok'), 'ok');
        expect(documentText('<script type="text/javascript" src="a.js">bad()</script>t'), 't');
        expect(documentText('a<style>p{color:red}</style>b'), 'ab');
      });

      test('a closing tag inside a string does not end the block early', () {
        expect(documentText('<script>var s = "</style>";</script>ok'), 'ok');
        expect(documentText('<style>a</script>b</style>ok'), 'ok');
        expect(documentText('<script><!--\ndocument.write("-->")\n// --></script>ok'), 'ok');
      });

      test('script look-alikes fall back to plain tag removal', () {
        expect(documentText('a<script>x</p>y'), 'axy');
        expect(documentText('<scriptx>not a block</scriptx>ok'), 'not a blockok');
        expect(documentText('a<script/>b'), 'ab');
        expect(documentText('a<script src="x>y">z</script>b'), 'ab');
        expect(documentText('<script>1()</script>x<script>2()</script>y'), 'xy');
      });
    });

    group('declarations', () {
      test('removes doctypes, PIs and other <!…> spans', () {
        expect(documentText('<!DOCTYPE html><p>x</p>'), 'x');
        expect(documentText('<?xml version="1.0"?><p>x</p>'), 'x');
        expect(documentText('<![CDATA[<!y>]]>z'), '\$1z');
      });

      test('a tag opener is removed while a later declaration still closes', () {
        // The '</sec' opener never finds a tag '>' (the declaration's
        // '>' is consumed by pass 4 first), yet the declaration itself
        // is still removed.
        expect(documentText('</sec<!tion>'), '</sec');
      });
    });

    group('whitespace', () {
      test('is kept as-is', () {
        expect(documentText('<p>line1\n   line2\ttab</p>'), 'line1\n   line2\ttab');
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
      expect(documentTextOf(file), documentText(file.content));
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
      manifest: Epub2Manifest(
        items: [ManifestItem(path: 'chapter1.html', id: 'c1', mediaType: 'application/xhtml+xml')],
      ),
      spine: Spine(tocId: null, items: const ['c1']),
      guide: null,
    ),
  );
}
