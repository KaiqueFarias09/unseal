/// One narrated fragment of an EPUB 3 media overlay: the audio clip
/// plus the content-document element it narrates.
final class OverlaySegment {
  /// Creates a segment.
  const OverlaySegment({
    required this.sequence,
    required this.audioPath,
    required this.textPath,
    this.fragment,
    required this.clipBegin,
    this.clipEnd,
  });

  /// Index of the segment in document order (0-based, across nested
  /// `seq` elements).
  final int sequence;

  /// Archive path of the audio clip file.
  final String audioPath;

  /// Archive path of the narrated content document.
  final String textPath;

  /// Fragment id inside the content document, when the `text src`
  /// carries one.
  final String? fragment;

  /// Where playback starts inside the audio file.
  final Duration clipBegin;

  /// Where playback stops; null plays to the end of the file.
  final Duration? clipEnd;

  @override
  String toString() => 'OverlaySegment(#$sequence $audioPath@$clipBegin text: $textPath#$fragment)';
}

/// A parsed SMIL overlay document: the flattened, ordered segments of
/// one content document's narration.
final class MediaOverlayDocument {
  /// Creates a document.
  const MediaOverlayDocument({required this.smilPath, required this.segments});

  /// Archive path of the SMIL file this document was parsed from.
  final String smilPath;

  /// Segments in playback order.
  final List<OverlaySegment> segments;

  /// Duration implied by parsed clips with `clipEnd`; informational only.
  ///
  /// This does not read the OPF `media:duration` value. Players derive timing
  /// from the audio itself.
  Duration get declaredDuration {
    return segments.fold(Duration.zero, (final total, final segment) {
      return total + ((segment.clipEnd ?? segment.clipBegin) - segment.clipBegin);
    });
  }
}
