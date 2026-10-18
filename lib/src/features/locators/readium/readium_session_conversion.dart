/// Session-aware Readium conversions: the same outcome contract as
/// `readium_conversion.dart`, executed through a live [BookSession]'s
/// CFI transport so the addressed document is the only content the
/// session materializes.
library;

import '../../../foundation/entities/entities.dart';
import '../../comic/entities/comic_book.dart';
import '../../epub/entities/entities.dart';
import '../../pdf/entities/pdf_book.dart';
import '../../progressive/book_session.dart';
import '../book_locator.dart';
import 'readium_conversion.dart';
import 'readium_locator.dart';
import 'readium_media_type.dart';

/// Conversions over a live session.
extension ReadiumSessionLocatorConversion on BookSession {
  /// Converts this book's [locator] into a Readium Locator. EPUB text
  /// locators build their CFI through the session transport and confirm
  /// it by resolving back; point locators confirm exactly, range
  /// locators carry only their start and come back approximate.
  Future<ReadiumConversion<ReadiumLocator>> toReadiumLocator(
    final BookLocator locator, {
    final String? documentUri,
  }) async {
    final book = this.book;
    switch (locator) {
      case final TextLocator text:
        if (book is! EpubBook) {
          return book.toReadiumLocator(text, documentUri: documentUri);
        }
        if (text.sectionIndex < 0 || text.sectionIndex >= book.readingOrder.length) {
          return ReadiumUnsupported(
            ReadiumUnsupportedReason.foreignResource,
            detail: 'sectionIndex ${text.sectionIndex} is outside the reading order',
          );
        }
        final cfi = await buildCfi(contentIndex: text.sectionIndex, offsetInText: text.start);
        final resolved = await resolveCfi(cfi);
        final confirmed =
            resolved != null &&
            resolved.contentIndex == text.sectionIndex &&
            (resolved.charOffset ?? 0) == text.start;
        if (!confirmed) {
          return ReadiumApproximate(
            _progressionLocator(this.book, text),
            note: 'the session resolver could not confirm a CFI for this offset',
          );
        }
        if (text.end != text.start) {
          return ReadiumApproximate(
            _readiumForOffsets(this.book, text.sectionIndex, text.start, fragments: [cfi]),
            note:
                'session CFI transport builds point locators; the range '
                'travels by its start',
          );
        }

        return ReadiumExact(
          _readiumForOffsets(this.book, text.sectionIndex, text.start, fragments: [cfi]),
          evidence:
              'session transport confirmed $cfi back to section '
              '${text.sectionIndex} at ${text.start}',
        );
      case final PageLocator page:
        return book.toReadiumLocator(page, documentUri: documentUri);
      case final CfiLocator cfi:
        if (book is! EpubBook) return book.toReadiumLocator(cfi);
        final resolved = await resolveCfi(cfi.cfi);
        if (resolved == null) {
          return const ReadiumUnsupported(
            ReadiumUnsupportedReason.unresolvedFragment,
            detail: 'The CFI does not resolve against this session',
          );
        }
        return ReadiumExact(
          ReadiumLocator(
            href: resolved.contentPath,
            type: readiumMediaTypeOf(book, resolved.contentIndex),
            locations: ReadiumLocations(fragments: [cfi.cfi]),
          ),
          evidence: 'Session transport resolved the CFI to occurrence ${resolved.contentIndex}',
        );
    }
  }

  /// Converts a Readium [locator] against the session's book; CFI
  /// fragments resolve through the session transport. [occurrenceHint]
  /// selects the reading-order occurrence when a repeated href alone
  /// would stay ambiguous.
  Future<ReadiumConversion<BookLocator>> toBookLocator(
    final ReadiumLocator locator, {
    final int? occurrenceHint,
    final String? documentUri,
  }) async {
    final book = this.book;
    if (book is PdfBook || book is ComicBook) {
      return book.toBookLocator(locator, occurrenceHint: occurrenceHint, documentUri: documentUri);
    }
    final matches = <int>[
      for (var index = 0; index < book.readingOrder.length; index++)
        if (book.readingOrder[index].name == locator.href) index,
    ];
    if (matches.isEmpty) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.foreignResource,
        detail: 'href ${locator.href} matches no reading-order resource',
      );
    }
    if (matches.length > 1 && occurrenceHint == null) {
      return ReadiumAmbiguous(
        [for (final match in matches.take(8)) TextLocator(sectionIndex: match, start: 0, end: 0)],
        reason:
            'href repeats ${matches.length} times in the reading order and no '
            'occurrence hint was supplied',
      );
    }
    final targetIndex = occurrenceHint ?? matches.single;
    if (!matches.contains(targetIndex)) {
      return const ReadiumUnsupported(
        ReadiumUnsupportedReason.foreignResource,
        detail: 'Occurrence hint does not address the locator href',
      );
    }

    for (final fragment in locator.locations.fragments) {
      final cfiSource = _decodeCfiFragment(fragment);
      if (cfiSource == null) continue;

      final full = await resolveCfi(cfiSource);
      if (full != null && full.contentIndex != targetIndex) {
        return const ReadiumUnsupported(
          ReadiumUnsupportedReason.foreignResource,
          detail: 'CFI targets a different reading-order occurrence than href',
        );
      }
      if (full != null) {
        return ReadiumExact(
          TextLocator(
            sectionIndex: full.contentIndex,
            start: full.charOffset ?? 0,
            end: full.endCharOffset ?? full.charOffset ?? 0,
          ),
          evidence:
              'session transport resolved the CFI to section '
              '${full.contentIndex} at ${full.charOffset}',
        );
      }

      // A partial CFI: compose the spine steps of the confirmed
      // occurrence, then resolve.
      final composed = _composePartialCfi(cfiSource, targetIndex);
      final resolved = await resolveCfi(composed);
      if (resolved != null && resolved.contentIndex == targetIndex) {
        return ReadiumExact(
          TextLocator(
            sectionIndex: resolved.contentIndex,
            start: resolved.charOffset ?? 0,
            end: resolved.endCharOffset ?? resolved.charOffset ?? 0,
          ),
          evidence:
              'partial CFI resolved against occurrence $targetIndex to offset '
              '${resolved.charOffset}',
        );
      }

      return ReadiumApproximate(
        TextLocator(sectionIndex: targetIndex, start: 0, end: 0),
        note: 'the CFI fragment does not resolve; the resource is known, the position is not',
      );
    }

    final progression = locator.locations.progression;
    if (progression != null) {
      final length = (await loadDocumentText(locator.href))?.length ?? 0;
      final offset = length == 0 ? 0 : (progression * length).round().clamp(0, length);

      return ReadiumApproximate(
        TextLocator(sectionIndex: targetIndex, start: offset, end: offset),
        note: 'isolated progression never proves an exact range',
      );
    }

    return ReadiumApproximate(
      TextLocator(sectionIndex: targetIndex, start: 0, end: 0),
      note: 'the resource is known; no location expression refines it',
    );
  }

  ReadiumLocator _readiumForOffsets(
    final Book book,
    final int sectionIndex,
    final int offset, {
    required final List<String> fragments,
  }) {
    return ReadiumLocator(
      href: book.readingOrder[sectionIndex].name,
      type: readiumMediaTypeOf(book, sectionIndex),
      locations: ReadiumLocations(fragments: fragments),
    );
  }

  ReadiumLocator _progressionLocator(final Book book, final TextLocator text) {
    return ReadiumLocator(
      href: book.readingOrder[text.sectionIndex].name,
      type: readiumMediaTypeOf(book, text.sectionIndex),
    );
  }
}

/// A fragment that carries CFI content: `epubcfi(…)` directly, or the
/// `partialcfi(…)` wrapper the Readium position-list example uses.
String? _decodeCfiFragment(final String fragment) {
  if (fragment.startsWith('epubcfi(') && fragment.endsWith(')')) return fragment;
  if (fragment.startsWith('partialcfi(') && fragment.endsWith(')')) {
    return 'epubcfi(${fragment.substring('partialcfi('.length)}';
  }

  return null;
}

/// Wraps a partial CFI (resource-relative steps) with the book-level
/// spine steps of [sectionIndex] so the session resolver can walk it.
String _composePartialCfi(final String partialCfi, final int sectionIndex) {
  final inner = partialCfi.startsWith('epubcfi(')
      ? partialCfi.substring('epubcfi('.length, partialCfi.length - 1)
      : partialCfi;

  return 'epubcfi(/6/${(sectionIndex + 1) * 2}!$inner)';
}
