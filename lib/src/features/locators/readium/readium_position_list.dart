/// The Readium position-list service model (`total` + `positions`),
/// its generation binding, coverage, and cancellation token — per the
/// pinned positions document and the profile in
/// `doc/readium-locators.md`.
///
/// The service JSON carries exactly what the official document declares;
/// the generation binding (publication identity, occurrences, text
/// profile) travels beside the list in Dart and never masquerades as
/// service fields. No official position-list schema exists (the official
/// schema path returned 404); this model is Unseal's declared contract.
library;

import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import 'readium_limits.dart';
import 'readium_locator.dart';
import 'readium_position_profile.dart';

/// A generated position list: the declared [total] and its [positions].
final class ReadiumPositionList {
  /// Creates a list; the position count must equal [total].
  ReadiumPositionList({required this.total, required this.positions})
    : assert(total == positions.length);

  /// The total number of positions.
  final int total;

  /// One Locator per position, in reading-order occurrence sequence.
  final List<ReadiumLocator> positions;

  /// Serializes to the pinned service shape: `{"total": N, "positions":
  /// [Locator…]}`.
  Map<String, Object?> toServiceJson() {
    return <String, Object?>{
      'total': total,
      'positions': <Map<String, Object?>>[for (final position in positions) position.serialize()],
    };
  }

  @override
  String toString() => 'ReadiumPositionList($total positions)';
}

/// The evidence a generated list binds to: which publication revision,
/// which occurrences, under which text profile. Hosts persist it beside
/// the service JSON when they need verified reuse later.
final class ReadiumPositionBinding {
  /// Creates a binding; every field is fixed at generation time.
  const ReadiumPositionBinding({
    required this.profile,
    required this.textProfile,
    required this.occurrences,
    this.identity,
  });

  /// The generation profile (`unseal.readium.positions/1`).
  final ReadiumPositionProfile profile;

  /// The canonical-text profile the offsets address (the document-text
  /// profile for EPUB; a PDF list binds its reading mode's reflow
  /// profile).
  final TextProfile textProfile;

  /// One occurrence record per position source, in generation order.
  final List<SectionOccurrence> occurrences;

  /// The publication identity, when the caller supplied one.
  final PublicationRevision? identity;

  /// Encodes the binding as a JSON-safe map for hosts that persist it.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'profile': profile.id,
      'textProfileId': textProfile.id,
      'textProfileAlgorithm': textProfile.algorithm,
      if (identity != null) ...<String, Object?>{
        'publicationId': identity!.publicationId,
        'editionId': identity!.editionId,
        'sourceRevision': identity!.sourceRevision,
        'sourceEvidence': identity!.sourceEvidence.name,
      },
      'occurrences': <Map<String, Object?>>[
        for (final occurrence in occurrences)
          <String, Object?>{
            'sectionIndex': occurrence.sectionIndex,
            'resourcePath': occurrence.resourcePath,
            'readingOrderRevision': occurrence.readingOrderRevision,
          },
      ],
    };
  }
}

/// Observable progress of a position-list build.
final class ReadiumPositionCoverage {
  /// Creates a coverage snapshot.
  const ReadiumPositionCoverage({
    required this.occurrencesCompleted,
    required this.occurrencesTotal,
    required this.positionsEmitted,
    required this.isComplete,
    this.missingResources = 0,
  });

  /// The zero-coverage start every build reports from.
  static const ReadiumPositionCoverage start = ReadiumPositionCoverage(
    occurrencesCompleted: 0,
    occurrencesTotal: 0,
    positionsEmitted: 0,
    isComplete: false,
  );

  /// Occurrences fully processed so far.
  final int occurrencesCompleted;

  /// Occurrences the build will visit in total.
  final int occurrencesTotal;

  /// Positions emitted so far.
  final int positionsEmitted;

  /// Occurrences whose content could not load in a session build (the
  /// resource is missing); they completed with zero positions and never
  /// silently pass as empty text.
  final int missingResources;

  /// Whether the build finished every occurrence.
  final bool isComplete;

  @override
  String toString() =>
      'ReadiumPositionCoverage($occurrencesCompleted/$occurrencesTotal, '
      '$positionsEmitted positions${isComplete ? ', complete' : ''})';
}

/// Cooperative cancellation between build steps; cancellation keeps the
/// session usable and freezes the partial list.
final class ReadiumPositionCancellationToken {
  /// Whether the build should stop at the next step boundary.
  bool isCancelled = false;
}

/// Decodes a position-list service document from an already-parsed JSON
/// map, rejecting structurally invalid shapes with null (the map-level
/// tolerance contract; string entry points fail typed).
ReadiumPositionList? tryDecodeReadiumPositionListModel(
  final Map<Object?, Object?> json, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
  final ReadiumPositionLimits positionLimits = const ReadiumPositionLimits(),
}) {
  final total = json['total'];
  if (total is! int || total < 0) return null;
  final entries = json['positions'];
  if (entries is! List<Object?>) return null;
  if (entries.length != total || entries.length > positionLimits.maxPositions) return null;

  final positions = <ReadiumLocator>[];
  for (final entry in entries) {
    if (entry is! Map<Object?, Object?>) return null;
    final locator = tryDecodeReadiumLocator(entry, limits: limits);
    if (locator == null) return null;
    positions.add(locator);
  }

  return ReadiumPositionList(total: total, positions: positions);
}
