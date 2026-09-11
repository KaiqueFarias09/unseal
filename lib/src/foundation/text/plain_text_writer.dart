part of 'plain_text.dart';

/// Owns whitespace-collapse state while [extractPlainText] traverses the input.
final class _PlainTextWriter {
  static const _space = 0x20;

  final StringBuffer _buffer = StringBuffer();
  var _isPendingSpace = false;
  var _isStarted = false;

  void markPendingSpace() => _isPendingSpace = true;

  void writeDecoded(final String text) {
    for (var i = 0; i < text.length; i++) {
      final codeUnit = text.codeUnitAt(i);
      if (_isWhitespace(codeUnit)) {
        _isPendingSpace = true;

        continue;
      }

      _flushPendingSpace();
      _isStarted = true;
      _buffer.writeCharCode(codeUnit);
    }
  }

  void writeText(final String text) {
    _flushPendingSpace();
    _isStarted = true;
    _buffer.write(text);
  }

  void writeUnit(final int codeUnit) {
    _flushPendingSpace();
    _isStarted = true;
    _buffer.writeCharCode(codeUnit);
  }

  String finish() => _buffer.toString().trim();

  void _flushPendingSpace() {
    if (_isPendingSpace) {
      if (_isStarted) _buffer.writeCharCode(_space);
      _isPendingSpace = false;
    }
  }
}
