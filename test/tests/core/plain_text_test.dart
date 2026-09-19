import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('extractPlainText — markup', () {
    test('strips simple tags', () {
      expect(extractPlainText('<p>hello <b>world</b></p>'), 'hello world');
    });

    test('collapses adjacent tags into one space', () {
      expect(extractPlainText('<p>a</p><p>b</p>'), 'a b');
      expect(extractPlainText('a<br/><br/>b'), 'a b');
    });

    test('keeps a lone < as text', () {
      expect(extractPlainText('a < b'), 'a < b');
    });

    test('eats from < up to the first > across nested <', () {
      // Mirrors the `<[^>]*>` pattern: everything to the first '>'.
      expect(extractPlainText('a < b <c> d'), 'a d');
    });

    test('keeps an unterminated tag as text', () {
      expect(extractPlainText('unterminated <tag'), 'unterminated <tag');
    });

    test('eats a tag whose attribute swallows a >', () {
      // The tag pattern stops at the first '>' even inside quotes.
      expect(extractPlainText('<div class="a > b">attr</div>'), 'b">attr');
    });

    test('removes comments', () {
      expect(extractPlainText('before<!-- c -->after'), 'before after');
      expect(extractPlainText('a<!-- c1 --><!-- c2 -->b'), 'a b');
      expect(extractPlainText('<!-- eats <p> inside -->tail'), 'tail');
    });

    test('keeps an unterminated comment as text through the tag rule', () {
      // No '-->' anywhere: the comment pattern never matches, so only
      // '<!--' is eaten as a tag up to the first '>'.
      expect(extractPlainText('x<!-- no close'), 'x<!-- no close');
    });
  });

  group('extractPlainText — script and style blocks', () {
    test('removes script blocks', () {
      expect(extractPlainText('<p>a</p><script>evil()</script><p>b</p>'), 'a b');
    });

    test('removes style blocks', () {
      expect(extractPlainText('<style>p{color:red}</style>text'), 'text');
    });

    test('matches block names case-insensitively', () {
      expect(extractPlainText('<SCRIPT>alert(1)</SCRIPT>t'), 't');
      expect(extractPlainText('<STYLE>a{}</STYLE>tail'), 'tail');
    });

    test('matches opening tags with attributes', () {
      expect(extractPlainText('<script src="x.js" defer></script>ok'), 'ok');
    });

    test('does not treat <scriptx> as a script block', () {
      expect(extractPlainText('<scriptx>not a script</scriptx>'), 'not a script');
    });

    test('unterminated block still drops its opening tag', () {
      expect(extractPlainText('<script>no close'), 'no close');
    });

    test('block content may span lines', () {
      expect(extractPlainText('<script>\nvar a = 1;\nvar b = 2;\n</script>x'), 'x');
    });
  });

  group('extractPlainText — entities', () {
    test('decodes the named entities', () {
      expect(extractPlainText('&nbsp;'), '');
      expect(extractPlainText('a&nbsp;b'), 'a b');
      expect(extractPlainText('&amp;'), '&');
      expect(extractPlainText('&lt;'), '<');
      expect(extractPlainText('&gt;'), '>');
      expect(extractPlainText('&quot;'), '"');
      expect(extractPlainText('&#39;'), "'");
      expect(extractPlainText('&apos;'), "'");
    });

    test('named entities are case-sensitive', () {
      expect(extractPlainText('&AMP;'), '&AMP;');
      expect(extractPlainText('&LT;'), '&LT;');
    });

    test('decodes decimal and hex references', () {
      expect(extractPlainText('&#65;&#x42;'), 'AB');
      expect(extractPlainText('&#x1F600;'), '😀');
    });

    test('hex references require a lowercase x', () {
      expect(extractPlainText('&#X43;'), '&#X43;');
    });

    test('references require their trailing semicolon', () {
      expect(extractPlainText('just &amp'), 'just &amp');
      expect(extractPlainText('&#65'), '&#65');
      expect(extractPlainText('&#x41'), '&#x41');
    });

    test('malformed references stay literal', () {
      expect(extractPlainText('&#;'), '&#;');
      expect(extractPlainText('&#x;'), '&#x;');
      expect(extractPlainText('&#xZZ;'), '&#xZZ;');
    });

    test('does not confuse &#39; with a longer number', () {
      expect(extractPlainText('&#395;'), String.fromCharCode(395));
    });

    test('decodes double-escaped entities once (browser behaviour)', () {
      // The old sequential pipeline decoded these twice; decoding
      // once matches how browsers render them.
      expect(extractPlainText('&amp;lt;'), '&lt;');
      expect(extractPlainText('&amp;#60;'), '&#60;');
      expect(extractPlainText('&#38;#x40;'), '&#x40;');
      expect(extractPlainText('&amp;amp;'), '&amp;');
      expect(extractPlainText('&amp;nbsp;'), '&nbsp;');
    });

    test('an entity expanding to markup stays text', () {
      // Decoding happens after markup removal.
      expect(extractPlainText('&#60;b&#62;bold&#60;/b&#62;'), '<b>bold</b>');
      expect(extractPlainText('&lt;script&gt;'), '<script>');
    });

    test('an entity expanding to whitespace collapses', () {
      expect(extractPlainText('a&#32;&#32;b'), 'a b');
    });
  });

  group('extractPlainText — whitespace', () {
    test('collapses runs and trims edges', () {
      expect(extractPlainText('<p>a\n\t  b</p>'), 'a b');
      expect(extractPlainText('  leading and trailing  '), 'leading and trailing');
      expect(extractPlainText('\t\n\r mix'), 'mix');
    });

    test('collapses exotic unicode whitespace', () {
      expect(extractPlainText('a\u00A0\u2028\u2029\u3000b'), 'a b');
      expect(extractPlainText('a\u2003b'), 'a b');
    });

    test('keeps non-whitespace unicode untouched', () {
      expect(extractPlainText('olá & 你好 — æon'), 'olá & 你好 — æon');
    });

    test('empty and markup-only inputs yield empty text', () {
      expect(extractPlainText(''), '');
      expect(extractPlainText('   '), '');
      expect(extractPlainText('<p></p>'), '');
      expect(extractPlainText('<!-- x --><style></style>'), '');
    });

    test('leading markup never leaves a leading space', () {
      expect(extractPlainText('<html><body>hi</body></html>'), 'hi');
      expect(extractPlainText('<?xml version="1.0"?><p>x</p>'), 'x');
    });
  });

  group('extractPlainText — realistic fragment', () {
    test('combines every rule', () {
      const html = '''
<?xml version="1.0"?>
<html><head><style>h1 { color: red; }</style></head>
<body><!-- header -->
<h1 class="title">Don&nbsp;Quixote &amp; Sancho</h1>
<p>“Tilting at&nbsp;windmills&#8230;” &#8212; <em>Cervantes</em></p>
<script>tracking();</script>
</body></html>
''';
      expect(
        extractPlainText(html),
        'Don Quixote & Sancho '
        '“Tilting at windmills…” — Cervantes',
      );
    });
  });
}
