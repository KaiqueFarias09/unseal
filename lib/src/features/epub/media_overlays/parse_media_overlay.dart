import 'package:e_livre/src/features/epub/media_overlays/media_overlay.dart';
import 'package:xml/xml.dart';

import '../../../foundation/archive/archive_access.dart';

/// Parses a SMIL media overlay document (EPUB 3) into flattened,
/// playback-ordered [OverlaySegment]s.
///
/// [smilPath] is the archive path of the SMIL file itself; `text` and
/// `audio` srcs inside it are relative to that location and are
/// resolved to archive paths here. Namespace-agnostic: SMIL files
/// carry the `http://www.w3.org/ns/SMIL` namespace (or none), and
/// both parse identically.
MediaOverlayDocument parseMediaOverlay(final String smilXml, {required final String smilPath}) {
  final document = XmlDocument.parse(smilXml);
  final root = document.rootElement;

  final segments = <OverlaySegment>[];
  var sequence = 0;

  // The default content document: the first `text` src that carries a
  // path (seq `epub:textref` may override it per subtree).
  String? defaultTextPath;

  void walk(final XmlElement element, final String? inheritedTextPath) {
    final local = element.name.local;
    if (local == 'par') {
      final textElement = _child(element, 'text');
      final audioElement = _child(element, 'audio');
      if (textElement == null || audioElement == null) {
        return;
      }

      final textSrc = textElement.getAttribute('src') ?? '';
      String textPath;
      String? fragment;
      if (textSrc.contains('#')) {
        final parts = textSrc.split('#');
        textPath = parts.first;
        fragment = parts.length > 1 ? parts.sublist(1).join('#') : null;
      } else {
        textPath = textSrc;
      }
      if (textPath.isEmpty) {
        textPath = inheritedTextPath ?? defaultTextPath ?? '';
        fragment ??= textSrc.replaceFirst('#', '').isEmpty ? null : textSrc.replaceFirst('#', '');
      } else {
        defaultTextPath ??= resolveItemPath(smilPath, textPath);
      }

      final resolvedText = textPath.isEmpty
          ? (inheritedTextPath ?? '')
          : resolveItemPath(smilPath, textPath);

      final audioSrc = audioElement.getAttribute('src') ?? '';
      if (audioSrc.isEmpty || resolvedText.isEmpty) {
        return;
      }
      final audioPath = resolveItemPath(smilPath, audioSrc);

      segments.add(
        OverlaySegment(
          sequence: sequence++,
          audioPath: audioPath,
          textPath: resolvedText,
          fragment: (fragment == null || fragment.isEmpty) ? _fragmentOf(textSrc) : fragment,
          clipBegin:
              parseSmilClock(audioElement.getAttribute('clipBegin')) ??
              parseSmilClock(audioElement.getAttribute('begin')) ??
              Duration.zero,
          clipEnd: parseSmilClock(audioElement.getAttribute('clipEnd')),
        ),
      );
      return;
    }

    if (local == 'seq') {
      final textref = element.getAttribute('epub:textref') ?? element.getAttribute('textref');
      final textPath = textref == null ? null : resolveItemPath(smilPath, textref);
      for (final child in element.childElements) {
        walk(child, textPath ?? inheritedTextPath);
      }
    }
  }

  for (final child in root.childElements) {
    if (child.name.local == 'body') {
      for (final inner in child.childElements) {
        walk(inner, null);
      }
    } else {
      walk(child, null);
    }
  }

  return MediaOverlayDocument(smilPath: smilPath, segments: segments);
}

XmlElement? _child(final XmlElement element, final String local) {
  for (final child in element.childElements) {
    if (child.name.local == local) {
      return child;
    }
  }
  return null;
}

String? _fragmentOf(final String src) {
  if (!src.contains('#')) {
    return null;
  }
  final fragment = src.split('#').sublist(1).join('#');
  return fragment.isEmpty ? null : fragment;
}

/// Parses a SMIL clock value into a [Duration]. Supported forms per
/// the SMIL/EPUB spec: full clock (`hh:mm:ss.fraction`), partial
/// clock (`mm:ss.fraction`), timecount with unit (`12.5s`, `450ms`,
/// `2min`, `1h`) and bare numbers (seconds). Returns null for empty
/// or unparseable values.
Duration? parseSmilClock(final String? value) {
  if (value == null) {
    return null;
  }
  final raw = value.trim();
  if (raw.isEmpty) {
    return null;
  }

  final fullClock = RegExp(r'^(\d+):(\d{1,2}):(\d{1,2}(?:\.\d+)?)$').firstMatch(raw);
  if (fullClock != null) {
    return Duration(
      hours: int.parse(fullClock.group(1)!),
      minutes: int.parse(fullClock.group(2)!),
      milliseconds: (_fractional(fullClock.group(3)!) * 1000).round(),
    );
  }

  final partialClock = RegExp(r'^(\d{1,2}):(\d{1,2}(?:\.\d+)?)$').firstMatch(raw);
  if (partialClock != null) {
    return Duration(
      minutes: int.parse(partialClock.group(1)!),
      milliseconds: (_fractional(partialClock.group(2)!) * 1000).round(),
    );
  }

  final timecount = RegExp(r'^(\d+(?:\.\d+)?)(ms|s|min|h)?$').firstMatch(raw);
  if (timecount != null) {
    final amount = double.parse(timecount.group(1)!);
    return switch (timecount.group(2)) {
      'ms' => Duration(milliseconds: amount.round()),
      'min' => Duration(milliseconds: (amount * 60000).round()),
      'h' => Duration(milliseconds: (amount * 3600000).round()),
      _ => Duration(milliseconds: (amount * 1000).round()),
    };
  }
  return null;
}

double _fractional(final String seconds) => double.parse(seconds);
