import '../../../foundation/text/canonical_text_snapshot.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/revision_digest.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import 'anchor_limits.dart';

/// The schema version of the durable-anchor envelope. Additive fields
/// bump this version; decoders refuse unknown versions instead of
/// reinterpreting an older payload.
const int anchorSchemaVersion = 1;

/// The quoted selection plus its immediate surrounding context — the
/// evidence a resolution re-finds the selection with.
///
/// `exact` is the full text the anchor's range selected at capture
/// time (never truncated). `before` and `after` are the surrounding
/// context, truncated to [AnchorLimits.maxContextLength] at capture.
final class AnchorQuote {
  /// Creates a quote; [ArgumentError] reports an empty exact text on a
  /// non-point anchor.
  const AnchorQuote({required this.exact, this.before = '', this.after = ''});

  /// The exact text of the selection; empty for a point anchor.
  final String exact;

  /// The text immediately before the selection, empty at a section
  /// start (or after capture-side truncation).
  final String before;

  /// The text immediately after the selection, empty at a section end
  /// (or after capture-side truncation).
  final String after;

  @override
  bool operator ==(final Object other) =>
      other is AnchorQuote &&
      other.exact == exact &&
      other.before == before &&
      other.after == after;

  @override
  int get hashCode => Object.hash(exact, before, after);

  @override
  String toString() => 'AnchorQuote(…$exact…)';
}

/// The durable, additive annotation envelope: who captured a selection
/// where, under which identity and revisions, with the evidence to
/// re-find it after the publication changed.
///
/// The envelope is additive to the v1 annotation codecs — it never
/// reinterprets an `annotation_codec.dart` payload, and the v1 codecs
/// never see an anchor. Every field pairs with the common text
/// contract: [identity] is the `PublicationRevision`, [occurrence] the
/// `SectionOccurrence`, [profile] the extraction profile whose
/// canonical text the offsets address, and [textRevision] pins the
/// exact section text the [start]/[end] bounds were cut from.
///
/// Offsets are UTF-16 code units, inclusive start and exclusive end,
/// in that snapshot's canonical text — the same unit search and CFI
/// address.
final class AnnotationAnchor {
  /// Captures an anchor over materialized text; [ArgumentError]
  /// reports bounds outside the snapshot or evidence above [limits].
  ///
  /// The quote is cut from the snapshot text — `exact` is the range's
  /// full text, `before`/`after` the surrounding context truncated to
  /// the context limit. A point selection ([start] == [end]) captures
  /// with an empty exact text; it reuses only through identity, never
  /// through migration evidence.
  factory AnnotationAnchor.capture({
    required final CanonicalTextSnapshot snapshot,
    required final int start,
    required final int end,
    final String? annotationId,
    final AnchorLimits limits = const AnchorLimits(),
  }) {
    limits.requireValid();
    if (start < 0) {
      throw ArgumentError.value(start, 'start', 'Must be non-negative');
    }
    if (end < start) {
      throw ArgumentError.value(end, 'end', 'Must not precede the inclusive start');
    }
    if (end > snapshot.utf16Length) {
      throw ArgumentError.value(
        end,
        'end',
        'Must not exceed the snapshot length (${snapshot.utf16Length})',
      );
    }
    final exact = snapshot.text.substring(start, end);
    if (exact.length > limits.maxQuoteLength) {
      throw ArgumentError.value(
        exact.length,
        'start..end',
        'Selection exceeds AnchorLimits.maxQuoteLength (${limits.maxQuoteLength})',
      );
    }

    return AnnotationAnchor._(
      identity: snapshot.identity,
      occurrence: snapshot.occurrence,
      profile: snapshot.profile,
      textRevision: snapshot.textRevision,
      start: start,
      end: end,
      annotationId: annotationId,
      quote: AnchorQuote(
        exact: exact,
        before: _contextBefore(snapshot.text, start, limits.maxContextLength),
        after: _contextAfter(snapshot.text, end, limits.maxContextLength),
      ),
    );
  }

  const AnnotationAnchor._({
    required this.identity,
    required this.occurrence,
    required this.profile,
    required this.textRevision,
    required this.start,
    required this.end,
    required this.quote,
    this.annotationId,
  });

  /// Rebuilds an anchor from already-validated parts (the codec's
  /// internal constructor path); callers go through
  /// [AnnotationAnchor.capture] or the anchor codec, which enforce the
  /// contract.
  factory AnnotationAnchor.parts({
    required final PublicationRevision identity,
    required final SectionOccurrence occurrence,
    required final TextProfile profile,
    required final String textRevision,
    required final int start,
    required final int end,
    required final AnchorQuote quote,
    final String? annotationId,
  }) {
    if (!isSha256Revision(textRevision)) {
      throw ArgumentError.value(textRevision, 'textRevision', 'Must be sha256:<64 hex>');
    }

    return AnnotationAnchor._(
      identity: identity,
      occurrence: occurrence,
      profile: profile,
      textRevision: textRevision,
      start: start,
      end: end,
      quote: quote,
      annotationId: annotationId,
    );
  }

  /// The publication identity and source revision the selection was
  /// captured under.
  final PublicationRevision identity;

  /// Which section occurrence of the publication holds the selection.
  final SectionOccurrence occurrence;

  /// The extraction profile whose canonical text the offsets address.
  final TextProfile profile;

  /// The `sha256:` digest of the section text the bounds were cut
  /// from.
  final String textRevision;

  /// The inclusive first UTF-16 code unit of the selection.
  final int start;

  /// The exclusive end of the selection.
  final int end;

  /// The quote and context evidence.
  final AnchorQuote quote;

  /// The host's opaque annotation id, carried through untouched (the
  /// parser never mints or interprets it).
  final String? annotationId;

  /// Whether this anchor addresses a point selection.
  bool get isPoint => start == end;

  /// Whether the anchor carries enough identity to export for
  /// automatic reuse: a source revision with its evidence and a known
  /// reading order. In-memory-only anchors stay usable in memory and
  /// refuse export instead of inventing identity.
  bool get isExportable =>
      identity.sourceRevision != null && occurrence.readingOrderRevision != null;

  @override
  bool operator ==(final Object other) =>
      other is AnnotationAnchor &&
      other.identity == identity &&
      other.occurrence == occurrence &&
      other.profile == profile &&
      other.textRevision == textRevision &&
      other.start == start &&
      other.end == end &&
      other.quote == quote &&
      other.annotationId == annotationId;

  @override
  int get hashCode =>
      Object.hash(identity, occurrence, profile, textRevision, start, end, quote, annotationId);

  @override
  String toString() =>
      'AnnotationAnchor(${occurrence.resourcePath} #${occurrence.sectionIndex}, '
      '$start..$end)';

  static String _contextBefore(final String text, final int start, final int maxLength) {
    final from = start > maxLength ? start - maxLength : 0;

    return text.substring(from, start);
  }

  static String _contextAfter(final String text, final int end, final int maxLength) {
    final to = end + maxLength > text.length ? text.length : end + maxLength;

    return text.substring(end, to);
  }
}
