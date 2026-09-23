import 'dart:convert' as convert;
import 'dart:typed_data';

import '../../foundation/entities/entities.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../../foundation/text/xml_encoding.dart';

const _maxRtfBytes = 64 * 1024 * 1024;
const _maxRtfDepth = 128;
const _maxRtfOutputChars = 64 * 1024 * 1024;
const _htmlPath = 'document.html';

/// Converts readable RTF text and character emphasis to the common document model.
///
/// Images, tables, fields, and drawing objects are ignored. Their groups are
/// skipped so embedded binary data cannot appear as reading text.
DocumentBook parseRtfBook(final Uint8List bytes) {
  final parsed = _RtfReader(bytes).read();
  final title = parsed.title;
  final body = parsed.body;
  final html =
      '<!DOCTYPE html><html><head><meta charset="utf-8"><title>'
      '${_escape(title ?? '')}</title></head><body>$body</body></html>';
  final metadata = BookMetadata(
    format: BookFormat.rtf,
    title: title,
    authors: parsed.author == null ? const <String>[] : <String>[parsed.author!],
  );

  return DocumentBook(
    format: BookFormat.rtf,
    files: Files(
      images: const <BinaryFile>[],
      css: const <TextFile>[],
      html: <TextFile>[TextFile(name: _htmlPath, type: 'html', path: _htmlPath, content: html)],
      fonts: const <BinaryFile>[],
      others: const <BinaryFile>[],
    ),
    metadata: metadata,
    navigation: Navigation(
      title: title ?? 'Contents',
      navPoints: <NavPoint>[
        NavPoint(
          classAttribute: '',
          id: 'nav-1',
          playOrder: '1',
          label: title ?? 'Document',
          content: _htmlPath,
        ),
      ],
    ),
    order: const <String>[_htmlPath],
  );
}

/// Reads the title and author stored in an RTF information group.
BookMetadata readRtfMetadata(final Uint8List bytes) {
  final parsed = _RtfReader(bytes, metadataOnly: true).read();
  return BookMetadata(
    format: BookFormat.rtf,
    title: parsed.title,
    authors: parsed.author == null ? const <String>[] : <String>[parsed.author!],
  );
}

String _escape(final String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

enum _Destination { body, info, title, author, skip }

final class _RtfState {
  const _RtfState({
    this.destination = _Destination.body,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strike = false,
    this.uc = 1,
  });

  final _Destination destination;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strike;
  final int uc;

  _RtfState copyWith({
    final _Destination? destination,
    final bool? bold,
    final bool? italic,
    final bool? underline,
    final bool? strike,
    final int? uc,
  }) => _RtfState(
    destination: destination ?? this.destination,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strike: strike ?? this.strike,
    uc: uc ?? this.uc,
  );
}

final class _RtfResult {
  const _RtfResult({required this.body, required this.title, required this.author});
  final String body;
  final String? title;
  final String? author;
}

/// A bounded RTF token reader. Each opening brace copies the current
/// formatting and destination, as required by the RTF group model.
final class _RtfReader {
  _RtfReader(this.bytes, {this.metadataOnly = false});

  final Uint8List bytes;
  final bool metadataOnly;
  final _paragraph = StringBuffer();
  final _run = StringBuffer();
  final _body = StringBuffer();
  final _title = StringBuffer();
  final _author = StringBuffer();
  final _pendingUtf8 = <int>[];
  final _stack = <_RtfState>[];
  _RtfState _state = const _RtfState();
  _RtfState _runState = const _RtfState();
  XmlEncoding _encoding = XmlEncoding.cp1252;
  int? _unsupportedCodepage;
  int _offset = 0;
  int _fallback = 0;
  int _outputChars = 0;
  int _htmlChars = 0;

  _RtfResult read() {
    if (bytes.length > _maxRtfBytes) {
      throw const InvalidBookException('RTF exceeds the 64 MiB input limit.');
    }
    if (bytes.length < 6 ||
        bytes[0] != 0x7B ||
        bytes[1] != 0x5C ||
        bytes[2] != 0x72 ||
        bytes[3] != 0x74 ||
        bytes[4] != 0x66) {
      throw const InvalidBookException('Invalid RTF header.');
    }

    while (_offset < bytes.length) {
      final byte = bytes[_offset++];
      switch (byte) {
        case 0x7B:
          _flushUtf8();
          if (_stack.length >= _maxRtfDepth) {
            throw const InvalidBookException('RTF group nesting limit exceeded.');
          }
          _flushRun();
          _stack.add(_state);
        case 0x7D:
          _flushUtf8();
          if (_stack.isEmpty) throw const InvalidBookException('Unbalanced RTF group.');
          _flushRun();
          _state = _stack.removeLast();
        case 0x5C:
          _readControl();
        case 0x0A || 0x0D:
          // Physical RTF line breaks are formatting, not reading text.
          break;
        default:
          _consumeByte(byte);
      }
    }
    _flushUtf8();
    if (_stack.isNotEmpty) throw const InvalidBookException('Unclosed RTF group.');
    _flushParagraph();
    return _RtfResult(body: _body.toString(), title: _nonempty(_title), author: _nonempty(_author));
  }

  String? _nonempty(final StringBuffer buffer) {
    final value = buffer.toString().trim();
    return value.isEmpty ? null : value;
  }

  String _decodeByte(final int byte) {
    if (byte < 0x80) return String.fromCharCode(byte);
    if (_unsupportedCodepage case final codepage?) {
      throw FormatNotSupportedException('RTF codepage $codepage is not supported.');
    }
    return decodeXmlTextAs(<int>[byte], _encoding);
  }

  void _consumeByte(final int byte) {
    if (_encoding == XmlEncoding.utf8 && byte >= 0x80) {
      _pendingUtf8.add(byte);
      final first = _pendingUtf8.first;
      final expected = first < 0xC0
          ? 1
          : first < 0xE0
          ? 2
          : first < 0xF0
          ? 3
          : 4;
      if (_pendingUtf8.length >= expected) _flushUtf8();
      return;
    }
    _flushUtf8();
    _emit(_decodeByte(byte));
  }

  void _flushUtf8() {
    if (_pendingUtf8.isEmpty) return;
    final decoded = convert.utf8.decode(_pendingUtf8, allowMalformed: true);
    _pendingUtf8.clear();
    _emit(decoded);
  }

  void _readControl() {
    if (_offset >= bytes.length) throw const InvalidBookException('Truncated RTF escape.');
    final start = _offset;
    final first = bytes[_offset++];
    if (!_isLetter(first)) {
      switch (first) {
        case 0x27: // \'hh
          if (_offset + 2 > bytes.length) {
            throw const InvalidBookException('Truncated RTF hex escape.');
          }
          final high = _hex(bytes[_offset++]);
          final low = _hex(bytes[_offset++]);
          if (high < 0 || low < 0) {
            throw const InvalidBookException('Invalid RTF hex escape.');
          }
          _consumeByte(high * 16 + low);
        case 0x5C || 0x7B || 0x7D:
          _flushUtf8();
          _emit(String.fromCharCode(first));
        case 0x7E:
          _flushUtf8();
          _emit('\u00A0');
        case 0x2D:
          _flushUtf8();
          _emit('\u00AD');
        case 0x5F:
          _flushUtf8();
          _emit('\u2011');
        case 0x2A:
          _state = _state.copyWith(destination: _Destination.skip);
        default:
          break;
      }
      return;
    }

    while (_offset < bytes.length && _isLetter(bytes[_offset])) {
      _offset++;
    }
    if (_offset - start > 32) {
      throw const InvalidBookException('RTF control word is too long.');
    }
    final word = String.fromCharCodes(bytes.sublist(start, _offset));
    var sign = 1;
    if (_offset < bytes.length && bytes[_offset] == 0x2D) {
      sign = -1;
      _offset++;
    }
    final numberStart = _offset;
    while (_offset < bytes.length && _isDigit(bytes[_offset])) {
      _offset++;
    }
    if (_offset - numberStart > 10) {
      throw const InvalidBookException('RTF control number is too long.');
    }
    final number = numberStart == _offset
        ? null
        : sign * int.parse(String.fromCharCodes(bytes.sublist(numberStart, _offset)));
    if (_offset < bytes.length && bytes[_offset] == 0x20) _offset++;
    _control(word, number);
  }

  void _control(final String word, final int? number) {
    _flushUtf8();
    if (word == 'bin') {
      if (number == null || number < 0 || number > bytes.length - _offset) {
        throw const InvalidBookException('Invalid RTF binary payload length.');
      }
      _offset += number;
      return;
    }
    if (word == 'ansicpg') {
      if (number == null || number <= 0) {
        throw const InvalidBookException('Invalid RTF codepage declaration.');
      }
      _unsupportedCodepage = const <int>{1251, 1252, 1256, 65001}.contains(number) ? null : number;
      _encoding = switch (number) {
        1251 => XmlEncoding.cp1251,
        1256 => XmlEncoding.cp1256,
        65001 => XmlEncoding.utf8,
        _ => XmlEncoding.cp1252,
      };
      return;
    }
    if (word == 'uc' && number != null) {
      if (number < 0 || number > 16) {
        throw const InvalidBookException('Invalid RTF Unicode fallback length.');
      }
      _state = _state.copyWith(uc: number);
      return;
    }
    if (word == 'u') {
      if (number == null || number < -32768 || number > 65535) {
        throw const InvalidBookException('Invalid RTF Unicode escape.');
      }
      _append(String.fromCharCode(number < 0 ? number + 65536 : number));
      _fallback = _state.uc;
      return;
    }

    if (_state.destination == _Destination.skip) return;
    if (word == 'info') {
      _state = _state.copyWith(destination: _Destination.info);
      return;
    }
    if (_state.destination == _Destination.info && word == 'title') {
      _state = _state.copyWith(destination: _Destination.title);
      return;
    }
    if (_state.destination == _Destination.info && word == 'author') {
      _state = _state.copyWith(destination: _Destination.author);
      return;
    }
    if (_skippedDestinations.contains(word)) {
      _state = _state.copyWith(destination: _Destination.skip);
      return;
    }
    if (_state.destination == _Destination.info) return;
    if (_state.destination == _Destination.title || _state.destination == _Destination.author) {
      if (word == 'par') _append(' ');
      return;
    }
    switch (word) {
      case 'b':
        _style(_state.copyWith(bold: number != 0));
      case 'i':
        _style(_state.copyWith(italic: number != 0));
      case 'ul':
        _style(_state.copyWith(underline: number != 0));
      case 'ulnone':
        _style(_state.copyWith(underline: false));
      case 'strike':
        _style(_state.copyWith(strike: number != 0));
      case 'plain':
        _style(_state.copyWith(bold: false, italic: false, underline: false, strike: false));
      case 'par':
        _flushParagraph();
      case 'line':
        _flushRun();
        _paragraph.write('<br>');
      case 'tab':
        _append('\t');
      case 'emdash':
        _append('—');
      case 'endash':
        _append('–');
      case 'bullet':
        _append('•');
      case 'lquote':
        _append('‘');
      case 'rquote':
        _append('’');
      case 'ldblquote':
        _append('“');
      case 'rdblquote':
        _append('”');
      default:
        break;
    }
  }

  void _style(final _RtfState next) {
    _flushRun();
    _state = next;
  }

  void _emit(final String value) {
    if (_fallback > 0) {
      _fallback--;
      return;
    }
    _append(value);
  }

  void _append(final String value) {
    if (_state.destination == _Destination.skip || _state.destination == _Destination.info) {
      return;
    }
    if (metadataOnly && _state.destination == _Destination.body) return;
    _outputChars += value.length;
    if (_outputChars > _maxRtfOutputChars) {
      throw const InvalidBookException('RTF text output limit exceeded.');
    }
    switch (_state.destination) {
      case _Destination.body:
        if (_run.length >= 64 * 1024) _flushRun();
        if (_run.isEmpty) _runState = _state;
        _run.write(value);
      case _Destination.title:
        _title.write(value);
      case _Destination.author:
        _author.write(value);
      case _Destination.info || _Destination.skip:
        break;
    }
  }

  void _flushRun() {
    if (_run.isEmpty) return;
    var value = _escape(_run.toString()).replaceAll('\t', '&emsp;');
    if (_runState.bold) value = '<strong>$value</strong>';
    if (_runState.italic) value = '<em>$value</em>';
    if (_runState.underline) value = '<u>$value</u>';
    if (_runState.strike) value = '<s>$value</s>';
    _htmlChars += value.length;
    if (_htmlChars > _maxRtfOutputChars) {
      throw const InvalidBookException('RTF HTML output limit exceeded.');
    }
    _paragraph.write(value);
    _run.clear();
  }

  void _flushParagraph() {
    _flushRun();
    if (_paragraph.isEmpty) return;
    _htmlChars += 8;
    if (_htmlChars > _maxRtfOutputChars) {
      throw const InvalidBookException('RTF HTML output limit exceeded.');
    }
    _body.write('<p>${_paragraph.toString()}</p>\n');
    _paragraph.clear();
  }
}

bool _isLetter(final int value) =>
    (value >= 0x41 && value <= 0x5A) || (value >= 0x61 && value <= 0x7A);
bool _isDigit(final int value) => value >= 0x30 && value <= 0x39;
int _hex(final int value) {
  if (value >= 0x30 && value <= 0x39) return value - 0x30;
  if (value >= 0x41 && value <= 0x46) return value - 0x41 + 10;
  if (value >= 0x61 && value <= 0x66) return value - 0x61 + 10;
  return -1;
}

const _skippedDestinations = <String>{
  'fonttbl',
  'colortbl',
  'stylesheet',
  'listtable',
  'listoverridetable',
  'pict',
  'object',
  'objdata',
  'header',
  'footer',
  'headerl',
  'headerr',
  'footerl',
  'footerr',
  'footnote',
  'annotation',
  'field',
  'fldinst',
  'xmlopen',
  'xmlattrname',
  'xmlattrvalue',
  'generator',
  'datafield',
};
