/// Deterministic position-list generation under the
/// `unseal.readium.positions/1` profile, over an eager [Book] or a live
/// [BookSession] — per `doc/readium-locators.md`.
///
/// Generation is a pure walk of the reading order: no clocks, no
/// randomness, no map-iteration order, so the same book bytes and
/// identity produce identical lists. Eager and session generation agree
/// when the canonical-text profile matches.
///
/// A full build can materialize the whole book text: global progressions
/// need every section's length before the first position is emitted, so
/// session builds run a lengths pass (retaining integers only) followed
/// by an anchor pass that re-loads one occurrence at a time — a cold
/// session decodes the text twice, a warm cache once. Cancellation is
/// honored between steps of both passes.
library;

import '../../../foundation/entities/entities.dart';
import '../../../foundation/text/canonical_document_text.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/revision_digest.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import '../../comic/entities/comic_book.dart';
import '../../pdf/entities/pdf_book.dart';
import '../../progressive/book_session.dart';
import 'readium_limits.dart';
import 'readium_locator.dart';
import 'readium_media_type.dart';
import 'readium_position_list.dart';
import 'readium_position_profile.dart';

/// One completed position-list build: the list, its binding, and the
/// final coverage.
final class ReadiumPositionBuild {
  /// Creates a build result.
  const ReadiumPositionBuild({
    required this.list,
    required this.binding,
    required this.coverage,
    required this.cancelled,
  });

  /// The generated list.
  final ReadiumPositionList list;

  /// The identity evidence the list binds to.
  final ReadiumPositionBinding binding;

  /// The final coverage snapshot.
  final ReadiumPositionCoverage coverage;

  /// Whether cancellation stopped the build early — the list is a
  /// frozen partial prefix of the profile's full output.
  final bool cancelled;
}

/// The generation entry points.
abstract final class ReadiumPositionListBuilder {
  const ReadiumPositionListBuilder._();

  /// The profile every generated list declares.
  static const ReadiumPositionProfile profile = ReadiumPositionProfile.v1;

  /// Generates the full position list of an eagerly parsed [book].
  ///
  /// [identity] binds the list to a publication revision when supplied;
  /// PDF books require the host-confirmed [documentUri] (an empty or
  /// missing URI throws [ArgumentError] — Unseal never mints one).
  /// Crossing [limits] fails [ReadiumPositionLimitException] before the
  /// crossed position is allocated.
  static ReadiumPositionBuild ofBook(
    final Book book, {
    final PublicationRevision? identity,
    final String? documentUri,
    final ReadiumPositionLimits limits = const ReadiumPositionLimits(),
  }) {
    final order = book.readingOrder;
    final orderRevision = _orderRevision(order);
    if (order.length > limits.maxPositions) {
      throw const ReadiumPositionLimitException('Reading order exceeds the position budget');
    }
    final textTotal = _sumTextLengths(book, limits);
    var textBefore = 0;
    final occurrences = <SectionOccurrence>[];
    final positions = <ReadiumLocator>[];

    for (var index = 0; index < order.length; index++) {
      final item = order[index];
      occurrences.add(
        SectionOccurrence(
          sectionIndex: index,
          resourcePath: item.name,
          readingOrderRevision: orderRevision,
        ),
      );

      final page = _pagePosition(book, index, pageCount: order.length, documentUri: documentUri);
      if (page != null) {
        _emit(positions, (final oneBased) => _withPosition(page, oneBased), limits);
        continue;
      }

      final text = _sectionText(book, index);
      final length = text?.length ?? 0;
      if (textBefore + length > limits.maxTextCodeUnits) {
        throw const ReadiumPositionLimitException(
          'Position text scan exceeds its code-unit budget',
        );
      }
      if (positions.length >= limits.maxPositions) {
        throw const ReadiumPositionLimitException('No remaining position budget');
      }
      for (final offset in profile.anchorUtf16Offsets(
        text ?? '',
        limits: ReadiumPositionLimits(
          maxPositions: limits.maxPositions - positions.length,
          maxTextCodeUnits: limits.maxTextCodeUnits,
        ),
      )) {
        _emit(
          positions,
          (final oneBased) => _reflowablePosition(
            href: item.name,
            mediaType: readiumMediaTypeOf(book, index),
            offset: offset,
            sectionLength: length,
            before: textBefore,
            total: textTotal,
            oneBasedPosition: oneBased,
          ),
          limits,
        );
      }
      textBefore += length;
    }

    return ReadiumPositionBuild(
      list: ReadiumPositionList(total: positions.length, positions: positions),
      binding: ReadiumPositionBinding(
        profile: profile,
        textProfile: _textProfileOf(book),
        occurrences: occurrences,
        identity: identity,
      ),
      coverage: ReadiumPositionCoverage(
        occurrencesCompleted: order.length,
        occurrencesTotal: order.length,
        positionsEmitted: positions.length,
        isComplete: true,
      ),
      cancelled: false,
    );
  }

  /// Generates the position list over a live [session], walking one
  /// reading-order occurrence per step through the session's existing
  /// content APIs: a lengths pass retains only integers, then the anchor
  /// pass re-loads one occurrence at a time.
  ///
  /// [onCoverage] fires after every completed anchor-pass occurrence.
  /// [cancellation] stops the walk at the next step boundary (either
  /// pass) and returns the frozen partial list with `cancelled: true`;
  /// the session stays usable. A PDF session needs the host-confirmed
  /// [documentUri].
  static Future<ReadiumPositionBuild> ofSession(
    final BookSession session, {
    final PublicationRevision? identity,
    final String? documentUri,
    final ReadiumPositionLimits limits = const ReadiumPositionLimits(),
    final ReadiumPositionCancellationToken? cancellation,
    final void Function(ReadiumPositionCoverage coverage)? onCoverage,
  }) async {
    final book = session.book;
    final order = book.readingOrder;
    final orderRevision = _orderRevision(order);
    final comic = book is ComicBook ? book : null;
    final pdf = book is PdfBook ? book : null;
    if (pdf != null && (documentUri == null || documentUri.isEmpty)) {
      throw ArgumentError.value(
        documentUri,
        'documentUri',
        'PDF position lists need the host-confirmed document URI',
      );
    }

    // Lengths pass: the reflowable total must be known before the first
    // anchor carries a global progression. Page-based books skip it.
    if (order.length > limits.maxPositions) {
      throw const ReadiumPositionLimitException('Reading order exceeds the position budget');
    }
    final lengths = List<int>.filled(order.length, 0);
    var unitsVisited = 0;
    if (comic == null && pdf == null) {
      for (var index = 0; index < order.length; index++) {
        if (cancellation?.isCancelled ?? false) {
          return _cancelledBuild(
            book,
            identity,
            occurrences: const <SectionOccurrence>[],
            positions: const <ReadiumLocator>[],
            completed: 0,
            missing: 0,
            total: order.length,
          );
        }

        lengths[index] = (await _sessionSectionText(session, order[index]))?.length ?? 0;
        unitsVisited += lengths[index];
        if (unitsVisited > limits.maxTextCodeUnits) {
          throw const ReadiumPositionLimitException(
            'Position text scan exceeds its code-unit budget',
          );
        }
      }
    }
    final textTotal = lengths.fold(0, (final sum, final length) => sum + length);

    // Anchor pass: one occurrence per step.
    final occurrences = <SectionOccurrence>[];
    final positions = <ReadiumLocator>[];
    var textBefore = 0;
    var missing = 0;

    for (var index = 0; index < order.length; index++) {
      if (cancellation?.isCancelled ?? false) {
        return _cancelledBuild(
          book,
          identity,
          occurrences: occurrences,
          positions: positions,
          completed: index,
          missing: missing,
          total: order.length,
        );
      }

      final item = order[index];
      occurrences.add(
        SectionOccurrence(
          sectionIndex: index,
          resourcePath: item.name,
          readingOrderRevision: orderRevision,
        ),
      );
      void reportCoverage() => onCoverage?.call(
        ReadiumPositionCoverage(
          occurrencesCompleted: index + 1,
          occurrencesTotal: order.length,
          positionsEmitted: positions.length,
          missingResources: missing,
          isComplete: index + 1 == order.length && missing == 0,
        ),
      );

      if (comic != null) {
        _emit(
          positions,
          (final oneBased) => ReadiumLocator(
            href: comic.pages[index].path,
            type: mediaTypeForName(comic.pages[index].name),
            locations: ReadiumLocations(
              position: oneBased,
              progression: 0.0,
              totalProgression: index / comic.pageCount,
            ),
          ),
          limits,
        );
        reportCoverage();
        continue;
      }

      if (pdf != null) {
        _emit(
          positions,
          (final oneBased) => ReadiumLocator(
            href: documentUri!,
            type: 'application/pdf',
            locations: ReadiumLocations(
              fragments: ['page=${index + 1}'],
              position: oneBased,
              progression: 0.0,
              totalProgression: index / pdf.pageCount,
            ),
          ),
          limits,
        );
        reportCoverage();
        continue;
      }

      final text = await _sessionSectionText(session, item);
      if (item.isHtml && text == null) {
        missing++;
        reportCoverage();
        continue;
      }
      final length = text?.length ?? 0;
      if (textBefore + length > limits.maxTextCodeUnits) {
        throw const ReadiumPositionLimitException(
          'Position text scan exceeds its code-unit budget',
        );
      }
      if (positions.length >= limits.maxPositions) {
        throw const ReadiumPositionLimitException('No remaining position budget');
      }
      for (final offset in profile.anchorUtf16Offsets(
        text ?? '',
        limits: ReadiumPositionLimits(
          maxPositions: limits.maxPositions - positions.length,
          maxTextCodeUnits: limits.maxTextCodeUnits,
        ),
      )) {
        _emit(
          positions,
          (final oneBased) => _reflowablePosition(
            href: item.name,
            mediaType: readiumMediaTypeOf(book, index),
            offset: offset,
            sectionLength: length,
            before: textBefore,
            total: textTotal,
            oneBasedPosition: oneBased,
          ),
          limits,
        );
      }
      textBefore += length;
      reportCoverage();
    }

    return ReadiumPositionBuild(
      list: ReadiumPositionList(total: positions.length, positions: positions),
      binding: ReadiumPositionBinding(
        profile: profile,
        textProfile: _textProfileOf(book),
        occurrences: occurrences,
        identity: identity,
      ),
      coverage: ReadiumPositionCoverage(
        occurrencesCompleted: order.length,
        occurrencesTotal: order.length,
        positionsEmitted: positions.length,
        missingResources: missing,
        isComplete: missing == 0,
      ),
      cancelled: false,
    );
  }

  static ReadiumPositionBuild _cancelledBuild(
    final Book book,
    final PublicationRevision? identity, {
    required final List<SectionOccurrence> occurrences,
    required final List<ReadiumLocator> positions,
    required final int completed,
    required final int missing,
    required final int total,
  }) {
    final frozen = List<ReadiumLocator>.of(positions);

    return ReadiumPositionBuild(
      list: ReadiumPositionList(total: frozen.length, positions: frozen),
      binding: ReadiumPositionBinding(
        profile: profile,
        textProfile: _textProfileOf(book),
        occurrences: List<SectionOccurrence>.of(occurrences),
        identity: identity,
      ),
      coverage: ReadiumPositionCoverage(
        occurrencesCompleted: completed,
        occurrencesTotal: total,
        positionsEmitted: frozen.length,
        missingResources: missing,
        isComplete: false,
      ),
      cancelled: true,
    );
  }

  static void _emit(
    final List<ReadiumLocator> positions,
    final ReadiumLocator Function(int oneBasedPosition) build,
    final ReadiumPositionLimits limits,
  ) {
    if (positions.length >= limits.maxPositions) {
      throw ReadiumPositionLimitException(
        'Position list crossed the ${limits.maxPositions}-position limit before '
        'emitting position ${positions.length + 1}.',
      );
    }
    final oneBasedPosition = positions.length + 1;
    positions.add(build(oneBasedPosition));
  }

  static ReadiumLocator _reflowablePosition({
    required final String href,
    required final String mediaType,
    required final int offset,
    required final int sectionLength,
    required final int before,
    required final int total,
    required final int oneBasedPosition,
  }) {
    return ReadiumLocator(
      href: href,
      type: mediaType,
      locations: ReadiumLocations(
        position: oneBasedPosition,
        progression: sectionLength == 0 ? 0.0 : offset / sectionLength,
        totalProgression: total == 0 ? 0.0 : (before + offset) / total,
      ),
    );
  }

  /// Re-creates [locator] with the one-based publication position the
  /// emit order assigns (locations are final; the builder owns it).
  static ReadiumLocator _withPosition(final ReadiumLocator locator, final int oneBased) {
    return ReadiumLocator(
      href: locator.href,
      type: locator.type,
      title: locator.title,
      locations: ReadiumLocations(
        fragments: locator.locations.fragments,
        position: oneBased,
        progression: locator.locations.progression,
        totalProgression: locator.locations.totalProgression,
        extensions: locator.locations.extensions,
      ),
      text: locator.text,
    );
  }

  static ReadiumLocator? _pagePosition(
    final Book book,
    final int index, {
    required final int pageCount,
    required final String? documentUri,
  }) {
    final comic = book is ComicBook ? book : null;
    if (comic != null) {
      return ReadiumLocator(
        href: comic.pages[index].path,
        type: mediaTypeForName(comic.pages[index].name),
        locations: ReadiumLocations(
          progression: 0.0,
          totalProgression: pageCount == 0 ? 0.0 : index / pageCount,
        ),
      );
    }

    final pdf = book is PdfBook ? book : null;
    if (pdf != null) {
      if (documentUri == null || documentUri.isEmpty) {
        throw ArgumentError.value(
          documentUri,
          'documentUri',
          'PDF position lists need the host-confirmed document URI',
        );
      }

      return ReadiumLocator(
        href: documentUri,
        type: 'application/pdf',
        locations: ReadiumLocations(
          fragments: ['page=${index + 1}'],
          progression: 0.0,
          totalProgression: pageCount == 0 ? 0.0 : index / pageCount,
        ),
      );
    }

    return null;
  }

  static String _orderRevision(final List<ReadingOrderItem> order) {
    return RevisionDigest.readingOrderRevision([
      for (final entry in order) (entry.name, entry.isHtml),
    ]);
  }

  static int _sumTextLengths(final Book book, final ReadiumPositionLimits limits) {
    final filesByPath = <String, TextFile>{for (final file in book.files.html) file.path: file};
    var total = 0;
    for (final section in book.readingOrder) {
      if (!section.isHtml) continue;
      final file = filesByPath[section.name];
      if (file != null) total += documentTextOf(file).length;
      if (total > limits.maxTextCodeUnits) {
        throw const ReadiumPositionLimitException(
          'Position text scan exceeds its code-unit budget',
        );
      }
    }

    return total;
  }

  static String? _sectionText(final Book book, final int index) {
    final order = book.readingOrder;
    if (index < 0 || index >= order.length || !order[index].isHtml) return null;
    for (final file in book.files.html) {
      if (file.path == order[index].name) return documentTextOf(file);
    }

    return null;
  }

  static Future<String?> _sessionSectionText(
    final BookSession session,
    final ReadingOrderItem item,
  ) async {
    if (!item.isHtml) return null;

    return session.loadDocumentText(item.name);
  }

  static TextProfile _textProfileOf(final Book book) {
    final pdf = book is PdfBook ? book : null;
    if (pdf?.canonicalTextProfile != null) return pdf!.canonicalTextProfile!;

    return documentTextProfile;
  }
}
