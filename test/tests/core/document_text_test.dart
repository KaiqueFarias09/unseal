import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

/// Preserves the document-text regression coverage introduced when the
/// canonical text model moved into this library.
void main() {
  test('matches DOM textContent semantics', () {
    // Tags contribute nothing, exactly like textContent.
    expect(DocumentTextScanner('<p>a</p><p>b</p>').scan(), 'ab');
    expect(DocumentTextScanner('<p>Hello <b>world</b></p>').scan(), 'Hello world');
  });

  test('removes script, style, comments and doctype', () {
    expect(
      DocumentTextScanner(
        '<!DOCTYPE html><html><head><title>T</title>'
        '<style>.a{}</style><script>bad()</script></head>'
        '<body><!-- note -->text</body></html>',
      ).scan(),
      'text',
    );
  });

  test('contributes nothing outside <body>, matching the JS TreeWalker', () {
    expect(
      DocumentTextScanner(
        '<html><head><title>Offset pollution</title></head>'
        '<body><p>abc</p></body></html>',
      ).scan(),
      'abc',
    );
    expect(DocumentTextScanner('<p>no body tag</p>').scan(), 'no body tag');
  });

  test('decodes entities in a single pass', () {
    expect(DocumentTextScanner('a &amp; b').scan(), 'a & b');
    expect(DocumentTextScanner('&lt;tag&gt;').scan(), '<tag>');
    // &amp;lt; decodes to the literal "&lt;" once.
    expect(DocumentTextScanner('&amp;lt;').scan(), '&lt;');
    expect(DocumentTextScanner('caf&eacute;').scan(), 'caf\u00E9');
    // nbsp is U+00A0, not a space.
    expect(DocumentTextScanner('a&nbsp;b').scan(), 'a\u00A0b');
  });

  test('decodes numeric entities', () {
    expect(DocumentTextScanner('&#65;&#x42;').scan(), 'AB');
    expect(DocumentTextScanner('&#x1F4DA;').scan(), '\u{1F4DA}');
  });

  test('keeps raw whitespace', () {
    expect(DocumentTextScanner('<p>line1\n   line2</p>').scan(), 'line1\n   line2');
  });

  test('unknown entities stay literal', () {
    expect(DocumentTextScanner('a &nosuchentity; b').scan(), 'a &nosuchentity; b');
  });
}
