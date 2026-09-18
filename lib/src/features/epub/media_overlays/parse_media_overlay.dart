import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';
import 'media_overlay.dart';
import 'parse_smil_clock.dart';

/// Parses a SMIL media overlay document (EPUB 3) into flattened,
/// playback-ordered [OverlaySegment]s.
///
/// [smilPath] is the archive path of the SMIL file itself; `text` and
/// `audio` srcs inside it are relative to that location and are
/// resolved to archive paths here. Namespace-agnostic: SMIL files
/// carry the `http://www.w3.org/ns/SMIL` namespace (or none), and
/// both parse identically.
MediaOverlayDocument parseMediaOverlay(final String smilXml, {required final String smilPath}) {
  return _MediaOverlayParser(smilPath).parse(smilXml);
}

XmlElement? _child(final XmlElement element, final String local) {
  for (final child in element.childElements) {
    if (child.name.local == local) return child;
  }

  return null;
}

({String path, String? fragment}) _splitReference(final String source) {
  final separator = source.indexOf('#');
  if (separator < 0) return (path: source, fragment: null);

  final fragment = source.substring(separator + 1);

  return (path: source.substring(0, separator), fragment: fragment.isEmpty ? null : fragment);
}

final class _MediaOverlayParser {
  _MediaOverlayParser(this.smilPath);

  final String smilPath;
  final List<OverlaySegment> _segments = <OverlaySegment>[];

  String? _defaultTextPath;
  int _sequence = 0;

  MediaOverlayDocument parse(final String smilXml) {
    final root = XmlDocument.parse(smilXml).rootElement;
    for (final child in root.childElements) {
      if (child.name.local == 'body') {
        for (final bodyChild in child.childElements) {
          _walk(bodyChild, null);
        }
        continue;
      }

      _walk(child, null);
    }

    return MediaOverlayDocument(smilPath: smilPath, segments: _segments);
  }

  void _walk(final XmlElement element, final String? inheritedTextPath) {
    if (element.name.local == 'par') {
      _addParallelSegment(element, inheritedTextPath);

      return;
    }
    if (element.name.local == 'seq') _walkSequence(element, inheritedTextPath);
  }

  void _walkSequence(final XmlElement element, final String? inheritedTextPath) {
    final textReference = element.getAttribute('epub:textref') ?? element.getAttribute('textref');
    final textPath = textReference == null
        ? inheritedTextPath
        : resolveItemPath(smilPath, textReference);
    for (final child in element.childElements) {
      _walk(child, textPath);
    }
  }

  void _addParallelSegment(final XmlElement element, final String? inheritedTextPath) {
    final textElement = _child(element, 'text');
    final audioElement = _child(element, 'audio');
    if (textElement == null || audioElement == null) return;

    final textSource = textElement.getAttribute('src') ?? '';
    final reference = _splitReference(textSource);
    final textPath = reference.path.isEmpty
        ? inheritedTextPath ?? _defaultTextPath ?? ''
        : resolveItemPath(smilPath, reference.path);

    if (reference.path.isNotEmpty) _defaultTextPath ??= textPath;

    final audioSource = audioElement.getAttribute('src') ?? '';
    if (audioSource.isEmpty || textPath.isEmpty) return;

    _segments.add(
      OverlaySegment(
        sequence: _sequence++,
        audioPath: resolveItemPath(smilPath, audioSource),
        textPath: textPath,
        fragment: reference.fragment,
        clipBegin:
            parseSmilClock(audioElement.getAttribute('clipBegin')) ??
            parseSmilClock(audioElement.getAttribute('begin')) ??
            Duration.zero,
        clipEnd: parseSmilClock(audioElement.getAttribute('clipEnd')),
      ),
    );
  }
}
