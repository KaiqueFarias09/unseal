import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

/// Ported from the e_livre_viewer `document_text_test.dart` suite
/// when the canonical text model moved into this library.
void main() {
  test('matches DOM textContent semantics', () {
    // Tags contribute nothing, exactly like textContent.
    expect(documentText('<p>a</p><p>b</p>'), 'ab');
    expect(documentText('<p>Hello <b>world</b></p>'), 'Hello world');
  });

  test('removes script, style, comments and doctype', () {
    expect(
      documentText(
        '<!DOCTYPE html><html><head><title>T</title>'
        '<style>.a{}</style><script>bad()</script></head>'
        '<body><!-- note -->text</body></html>',
      ),
      'text',
    );
  });

  test('contributes nothing outside <body>, matching the JS TreeWalker', () {
    expect(
      documentText(
        '<html><head><title>Offset pollution</title></head>'
        '<body><p>abc</p></body></html>',
      ),
      'abc',
    );
    expect(documentText('<p>no body tag</p>'), 'no body tag');
  });

  test('decodes entities in a single pass', () {
    expect(documentText('a &amp; b'), 'a & b');
    expect(documentText('&lt;tag&gt;'), '<tag>');
    // &amp;lt; decodes to the literal "&lt;" once.
    expect(documentText('&amp;lt;'), '&lt;');
    expect(documentText('caf&eacute;'), 'caf\u00E9');
    // nbsp is U+00A0, not a space.
    expect(documentText('a&nbsp;b'), 'a\u00A0b');
  });

  test('decodes numeric entities', () {
    expect(documentText('&#65;&#x42;'), 'AB');
    expect(documentText('&#x1F4DA;'), '\u{1F4DA}');
  });

  test('keeps raw whitespace', () {
    expect(documentText('<p>line1\n   line2</p>'), 'line1\n   line2');
  });

  test('unknown entities stay literal', () {
    expect(documentText('a &nosuchentity; b'), 'a &nosuchentity; b');
  });
}
