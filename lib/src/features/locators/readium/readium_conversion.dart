/// Conversions between the Readium Locator model and Unseal's
/// [BookLocator] union, with exactly one outcome per conversion —
/// exact, approximate, ambiguous, or unsupported — per
/// `doc/readium-locators.md`.
///
/// The readium interchange feature is the one place the locator feature
/// reaches into EPUB CFI resolution and the EPUB/PDF/comic book entities;
/// the generic `BookLocator` union and its codec stay CFI-free.
library;

import '../../../foundation/entities/entities.dart';
import '../../../foundation/text/canonical_document_text.dart';
import '../../../foundation/text/canonical_text_snapshot.dart';
import '../../../foundation/text/publication_revision.dart';
import '../../../foundation/text/section_occurrence.dart';
import '../../../foundation/text/text_profile.dart';
import '../../cfi/epub_cfi.dart';
import '../../cfi/epub_cfi_resolver.dart';
import '../../comic/entities/comic_book.dart';
import '../../epub/entities/entities.dart';
import '../../pdf/entities/pdf_book.dart';
import '../book_locator.dart';
import 'readium_limits.dart';
import 'readium_locator.dart';
import 'readium_media_type.dart';

/// Why a conversion produced no target.
enum ReadiumUnsupportedReason {
  /// The locator's href matches no resource of the target book.
  foreignResource,

  /// The fragment (CFI or page) cannot resolve against the book.
  unresolvedFragment,

  /// A `page=N` fragment is below 1 or past the page count.
  pageOutOfRange,

  /// The book exposes no position model the conversion can address.
  noPositionModel,

  /// A PDF locator needs the host-confirmed document URI and none was
  /// supplied.
  missingDocumentUri,
}

/// Base of the conversion outcome union, parameterized by the locator
/// type the conversion produces: [BookLocator] for Readium→Unseal,
/// [ReadiumLocator] for Unseal→Readium.
sealed class ReadiumConversion<T> {
  const ReadiumConversion();
}

/// Every target field was derivable without guessing.
final class ReadiumExact<T> extends ReadiumConversion<T> {
  /// Creates an exact outcome.
  const ReadiumExact(this.locator, {required this.evidence});

  /// The converted locator.
  final T locator;

  /// What made the conversion verifiable (a confirming CFI resolution, a
  /// matching page, a resolved resource).
  final String evidence;
}

/// A usable but lossy target; [note] names what was lost.
final class ReadiumApproximate<T> extends ReadiumConversion<T> {
  /// Creates an approximate outcome.
  const ReadiumApproximate(this.locator, {required this.note});

  /// The converted locator.
  final T locator;

  /// The loss that keeps this from being exact.
  final String note;
}

/// The evidence matches more than one target; no candidate is chosen.
final class ReadiumAmbiguous<T> extends ReadiumConversion<T> {
  /// Creates an ambiguous outcome.
  const ReadiumAmbiguous(this.candidates, {required this.reason});

  /// The equally-ranked candidates, at most 8.
  final List<T> candidates;

  /// Why the evidence cannot pick one.
  final String reason;
}

/// The locator cannot address this book; nothing is guessed.
final class ReadiumUnsupported<T> extends ReadiumConversion<T> {
  /// Creates an unsupported outcome.
  const ReadiumUnsupported(this.reason, {required this.detail});

  /// Why nothing was converted.
  final ReadiumUnsupportedReason reason;

  /// The human-readable refusal detail.
  final String detail;
}

/// The publication context verified locator reuse requires: revision,
/// reading-order occurrence, and text profile. A locator alone never
/// certifies it still addresses a book.
final class ReadiumLocatorContext {
  /// Creates a context.
  const ReadiumLocatorContext({
    required this.identity,
    required this.occurrence,
    required this.profile,
  });

  /// The publication identity and source revision the locator was
  /// captured against.
  final PublicationRevision identity;

  /// The reading-order occurrence (index, exact path, order revision).
  final SectionOccurrence occurrence;

  /// The extraction profile of the canonical text the offsets address.
  final TextProfile profile;

  /// Whether the context carries the verified evidence reuse requires:
  /// a source revision and a known reading-order revision. In-memory
  /// contexts answer false and reuse reports `unverified`.
  bool get isExportable =>
      identity.sourceRevision != null && occurrence.readingOrderRevision != null;
}

/// How a stored locator's context compares against a target snapshot.
enum ReadiumReuseVerdict {
  /// Every context field matches; offsets may be reused as verified.
  verified,

  /// The publication revision differs; reuse would be unverified.
  incompatibleRevision,

  /// The text profile differs (e.g. another PDF reading mode).
  incompatibleProfile,

  /// The reading-order occurrence differs (index, path, or order
  /// revision).
  incompatibleOccurrence,

  /// The context or target carries no exportable evidence, so nothing
  /// can be verified either way.
  unverified,
}

/// The excerpt window cut for `text.before`/`text.after` context.
const int readiumContextExcerptChars = 128;

/// Conversions over an eagerly parsed [Book].
extension ReadiumBookConversions on Book {
  /// Whether [href] names a reading-order resource of this book.
  bool hasResourceHref(final String href) => readingOrder.any((final item) => item.name == href);

  /// Converts this book's [locator] into a Readium Locator.
  ///
  /// [documentUri] is the host-confirmed document URI for PDF books; PDF
  /// conversions fail [ReadiumUnsupported] with
  /// [ReadiumUnsupportedReason.missingDocumentUri] when it is absent.
  ReadiumConversion<ReadiumLocator> toReadiumLocator(
    final BookLocator locator, {
    final String? documentUri,
    final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
  }) {
    switch (locator) {
      case final TextLocator text:
        return _textToReadium(text, limits);
      case final PageLocator page:
        return _pageToReadium(page, documentUri);
      case final CfiLocator cfi:
        return _cfiToReadium(cfi);
    }
  }

  ReadiumConversion<ReadiumLocator> _textToReadium(
    final TextLocator locator,
    final ReadiumLocatorLimits limits,
  ) {
    final epub = this is EpubBook ? this as EpubBook : null;
    if (epub != null) {
      final cfi = _confirmedEpubCfi(epub, locator);
      if (cfi != null) {
        return ReadiumExact(
          ReadiumLocator(
            href: readingOrder[locator.sectionIndex].name,
            type: readiumMediaTypeOf(this, locator.sectionIndex),
            locations: ReadiumLocations(
              fragments: [cfi],
              progression: _localProgression(locator.sectionIndex, locator.start),
              totalProgression: _totalProgression(locator.sectionIndex, locator.start),
            ),
            text: _textContext(locator, limits),
          ),
          evidence:
              'EpubCfiResolver confirmed $cfi back to section '
              '${locator.sectionIndex} at ${locator.start}',
        );
      }
    }

    if (locator.sectionIndex < 0 || locator.sectionIndex >= readingOrder.length) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.foreignResource,
        detail: 'sectionIndex ${locator.sectionIndex} is outside the reading order',
      );
    }

    // No confirmable CFI (non-EPUB book, or an EPUB section the resolver
    // could not confirm): href + progression stays usable but lossy.
    return ReadiumApproximate(
      ReadiumLocator(
        href: readingOrder[locator.sectionIndex].name,
        type: readiumMediaTypeOf(this, locator.sectionIndex),
        locations: ReadiumLocations(
          progression: _localProgression(locator.sectionIndex, locator.start),
          totalProgression: _totalProgression(locator.sectionIndex, locator.start),
        ),
        text: _textContext(locator, limits),
      ),
      note: epub == null
          ? 'book exposes no CFI resolver; the offset travels as progression only'
          : 'the existing resolver could not confirm a CFI for this offset',
    );
  }

  ReadiumConversion<ReadiumLocator> _pageToReadium(
    final PageLocator locator,
    final String? documentUri,
  ) {
    final comic = this is ComicBook ? this as ComicBook : null;
    if (comic != null) {
      if (locator.pageIndex < 0 || locator.pageIndex >= comic.pages.length) {
        return ReadiumUnsupported(
          ReadiumUnsupportedReason.pageOutOfRange,
          detail: 'pageIndex ${locator.pageIndex} is outside ${comic.pages.length} pages',
        );
      }

      return ReadiumExact(
        ReadiumLocator(
          href: comic.pages[locator.pageIndex].path,
          type: mediaTypeForName(comic.pages[locator.pageIndex].name),
        ),
        evidence: 'page index ${locator.pageIndex} resolves to the comic page resource',
      );
    }

    final pdf = this is PdfBook ? this as PdfBook : null;
    if (pdf != null) {
      if (documentUri == null || documentUri.isEmpty) {
        return ReadiumUnsupported(
          ReadiumUnsupportedReason.missingDocumentUri,
          detail: 'PDF locators need the host-confirmed document URI',
        );
      }
      if (locator.pageIndex < 0 || locator.pageIndex >= pdf.pages.length) {
        return ReadiumUnsupported(
          ReadiumUnsupportedReason.pageOutOfRange,
          detail: 'pageIndex ${locator.pageIndex} is outside ${pdf.pages.length} pages',
        );
      }

      return ReadiumExact(
        ReadiumLocator(
          href: documentUri,
          type: 'application/pdf',
          locations: ReadiumLocations(
            fragments: ['page=${locator.pageIndex + 1}'],
            totalProgression: locator.pageIndex / pdf.pages.length,
          ),
        ),
        evidence:
            'native zero-based page ${locator.pageIndex} -> one-based fragment '
            'page=${locator.pageIndex + 1}',
      );
    }

    return ReadiumUnsupported(
      ReadiumUnsupportedReason.noPositionModel,
      detail: '$runtimeType exposes no page model',
    );
  }

  ReadiumConversion<ReadiumLocator> _cfiToReadium(final CfiLocator locator) {
    final epub = this is EpubBook ? this as EpubBook : null;
    if (epub == null) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.noPositionModel,
        detail: 'CFI locators address EPUB books only',
      );
    }

    final parsed = EpubCfi.tryParse(locator.cfi);
    if (parsed == null) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.unresolvedFragment,
        detail: 'the CFI does not parse',
      );
    }
    final resolved = epub.resolveCfi(parsed);
    if (resolved == null) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.unresolvedFragment,
        detail: 'the CFI does not resolve against this book',
      );
    }

    final length = _sectionTextLength(resolved.contentIndex);
    final charOffset = resolved.charOffset ?? 0;

    return ReadiumExact(
      ReadiumLocator(
        href: resolved.contentPath,
        type: readiumMediaTypeOf(this, resolved.contentIndex),
        locations: ReadiumLocations(
          fragments: [locator.cfi],
          progression: length == null || length == 0 ? null : charOffset / length,
          totalProgression: _totalProgression(resolved.contentIndex, charOffset),
        ),
      ),
      evidence:
          'EpubCfiResolver resolved the CFI to section ${resolved.contentIndex} '
          'at ${resolved.charOffset}',
    );
  }

  /// Converts a Readium [locator] against this book. [occurrenceHint]
  /// selects the reading-order occurrence when a repeated href alone
  /// would stay ambiguous.
  ReadiumConversion<BookLocator> toBookLocator(
    final ReadiumLocator locator, {
    final int? occurrenceHint,
  }) {
    // PDF hrefs are the host-confirmed document URI, never a
    // reading-order path; route before the href match.
    final pdf = this is PdfBook ? this as PdfBook : null;
    if (pdf != null) {
      return _pdfToBookLocator(locator, pdf);
    }

    final matches = <int>[
      for (var index = 0; index < readingOrder.length; index++)
        if (readingOrder[index].name == locator.href) index,
    ];
    if (matches.isEmpty) {
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.foreignResource,
        detail: 'href ${locator.href} matches no reading-order resource',
      );
    }

    final comic = this is ComicBook ? this as ComicBook : null;
    if (comic != null) {
      if (matches.length > 1 && occurrenceHint == null) {
        return ReadiumAmbiguous(
          [
            for (final match in matches.take(8))
              PageLocator(pageIndex: match, total: comic.pageCount),
          ],
          reason:
              'href repeats ${matches.length} times in the reading order and no '
              'occurrence hint was supplied',
        );
      }
      final index = occurrenceHint ?? matches.first;
      if (!matches.contains(index)) {
        return ReadiumUnsupported(
          ReadiumUnsupportedReason.foreignResource,
          detail: 'occurrence $index does not address ${locator.href}',
        );
      }

      return ReadiumExact(
        PageLocator(pageIndex: index, total: comic.pageCount),
        evidence: 'href resolved to occurrence $index of ${comic.pageCount} pages',
      );
    }

    return _reflowableToBookLocator(locator, matches, occurrenceHint);
  }

  ReadiumConversion<BookLocator> _pdfToBookLocator(
    final ReadiumLocator locator,
    final PdfBook pdf,
  ) {
    for (final fragment in locator.locations.fragments) {
      final page = _parsePageFragment(fragment);
      if (page != null) {
        if (page < 1 || page > pdf.pages.length) {
          return ReadiumUnsupported(
            ReadiumUnsupportedReason.pageOutOfRange,
            detail: 'fragment $fragment names page $page of ${pdf.pages.length}',
          );
        }

        return ReadiumExact(
          PageLocator(pageIndex: page - 1, total: pdf.pageCount),
          evidence: 'one-based fragment $fragment -> native zero-based page ${page - 1}',
        );
      }
    }

    final progression = locator.locations.progression;
    if (progression != null) {
      final index = (progression * (pdf.pages.length - 1)).round();
      return ReadiumApproximate(
        PageLocator(pageIndex: index.clamp(0, pdf.pages.length - 1), total: pdf.pageCount),
        note: 'isolated progression never proves an exact page',
      );
    }

    return ReadiumUnsupported(
      ReadiumUnsupportedReason.unresolvedFragment,
      detail: 'no page fragment or progression to address',
    );
  }

  ReadiumConversion<BookLocator> _reflowableToBookLocator(
    final ReadiumLocator locator,
    final List<int> matches,
    final int? occurrenceHint,
  ) {
    final epub = this is EpubBook ? this as EpubBook : null;

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
      return ReadiumUnsupported(
        ReadiumUnsupportedReason.foreignResource,
        detail: 'occurrence $targetIndex does not address ${locator.href}',
      );
    }

    for (final fragment in locator.locations.fragments) {
      final cfi = _decodeCfiFragment(fragment);
      if (cfi == null) continue;

      final parsed = EpubCfi.tryParse(cfi);
      if (parsed == null) continue;
      final resolved = epub?.resolveCfi(parsed);
      if (resolved != null) {
        return ReadiumExact(
          TextLocator(
            sectionIndex: resolved.contentIndex,
            start: resolved.charOffset ?? 0,
            end: resolved.endCharOffset ?? resolved.charOffset ?? 0,
          ),
          evidence:
              'CFI fragment resolved to section ${resolved.contentIndex} '
              'at ${resolved.charOffset}',
        );
      }

      // A partial CFI: address it through the href's confirmed
      // occurrence.
      final sectionIndex = targetIndex;
      final composed = EpubCfi.tryParse(_composePartialCfi(cfi, sectionIndex));
      final partialResolved = composed == null ? null : epub?.resolveCfi(composed);
      if (partialResolved != null) {
        return ReadiumExact(
          TextLocator(
            sectionIndex: partialResolved.contentIndex,
            start: partialResolved.charOffset ?? 0,
            end: partialResolved.endCharOffset ?? partialResolved.charOffset ?? 0,
          ),
          evidence:
              'partial CFI resolved against occurrence $sectionIndex to offset '
              '${partialResolved.charOffset}',
        );
      }

      return ReadiumApproximate(
        TextLocator(sectionIndex: sectionIndex, start: 0, end: 0),
        note: 'the CFI fragment does not resolve; the resource is known, the position is not',
      );
    }

    // No resolvable fragment: fall back to progression, which never
    // proves an exact range.
    final progression = locator.locations.progression;
    if (progression != null) {
      final length = _sectionTextLength(targetIndex) ?? 0;
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

  int? _sectionTextLength(final int sectionIndex) {
    final order = readingOrder;
    if (sectionIndex < 0 || sectionIndex >= order.length) return null;
    if (!order[sectionIndex].isHtml) return null;
    for (final file in files.html) {
      if (file.path == order[sectionIndex].name) return documentTextOf(file).length;
    }

    return null;
  }

  double? _localProgression(final int sectionIndex, final int offset) {
    final length = _sectionTextLength(sectionIndex);
    if (length == null || length == 0) return null;

    return offset.clamp(0, length) / length;
  }

  double? _totalProgression(final int sectionIndex, final int offset) {
    final order = readingOrder;
    if (sectionIndex < 0 || sectionIndex >= order.length) return null;
    var before = 0.0;
    var total = 0.0;
    for (var index = 0; index < order.length; index++) {
      final length = order[index].isHtml ? (_sectionTextLength(index) ?? 0) : 0;
      if (index < sectionIndex) before += length;
      total += length;
    }
    if (total == 0) return null;

    return (before + offset.clamp(0, _sectionTextLength(sectionIndex) ?? 0)) / total;
  }

  ReadiumTextContext? _textContext(final TextLocator locator, final ReadiumLocatorLimits limits) {
    final order = readingOrder;
    if (locator.sectionIndex < 0 || locator.sectionIndex >= order.length) return null;
    if (!order[locator.sectionIndex].isHtml) return null;
    for (final file in files.html) {
      if (file.path != order[locator.sectionIndex].name) continue;
      final text = documentTextOf(file);
      if (locator.end > text.length) return null;

      final highlight = text.substring(locator.start, locator.end);
      if (highlight.length > limits.maxTextContextLength) return null;

      return ReadiumTextContext(
        before: _excerptBefore(text, locator.start),
        highlight: highlight,
        after: _excerptAfter(text, locator.end),
      );
    }

    return null;
  }

  String? _confirmedEpubCfi(final EpubBook epub, final TextLocator locator) {
    try {
      final cfi = locator.isPoint
          ? epub.buildEpubCfi(contentIndex: locator.sectionIndex, offsetInText: locator.start)
          : epub.buildEpubCfiRange(
              contentIndex: locator.sectionIndex,
              startOffset: locator.start,
              endOffset: locator.end,
            );
      final parsed = EpubCfi.tryParse(cfi);
      final resolved = parsed == null ? null : epub.resolveCfi(parsed);
      if (resolved == null) return null;
      final resolvedStart = resolved.charOffset ?? 0;
      final resolvedEnd = resolved.endCharOffset ?? resolvedStart;
      if (resolved.contentIndex != locator.sectionIndex ||
          resolvedStart != locator.start ||
          resolvedEnd != locator.end) {
        return null;
      }

      return cfi;
    } on RangeError {
      return null;
    } on ArgumentError {
      return null;
    } on StateError {
      return null;
    }
  }
}

/// Conversions that need a live session's CFI transport live in
/// `readium_session_conversion.dart`; they are async and keep this
/// extension synchronous.

/// Whether [fragment] is a `page=N` fragment, and its [int] value.
int? _parsePageFragment(final String fragment) {
  if (!fragment.startsWith('page=')) return null;
  final value = int.tryParse(fragment.substring(5));

  return value;
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
/// spine steps of [sectionIndex] so the existing resolver can walk it.
String _composePartialCfi(final String partialCfi, final int sectionIndex) {
  final inner = partialCfi.startsWith('epubcfi(')
      ? partialCfi.substring('epubcfi('.length, partialCfi.length - 1)
      : partialCfi;

  return 'epubcfi(/6/${(sectionIndex + 1) * 2}!$inner)';
}

String _excerptBefore(final String text, final int offset) {
  final from = (offset - readiumContextExcerptChars).clamp(0, offset);

  return text.substring(from, offset);
}

String _excerptAfter(final String text, final int offset) {
  final to = (offset + readiumContextExcerptChars).clamp(offset, text.length);

  return text.substring(offset, to);
}

/// Verifies a stored locator's [context] against a target [snapshot]
/// before its offsets are reused. Every context field must match — a
/// revision, profile, or occurrence change refuses verified reuse
/// instead of resolving "by proximity".
ReadiumReuseVerdict verifyReadiumReuse({
  required final ReadiumLocatorContext context,
  required final CanonicalTextSnapshot snapshot,
}) {
  if (!context.isExportable || !snapshot.isExportable) {
    return ReadiumReuseVerdict.unverified;
  }
  if (!context.identity.sameRevision(snapshot.identity)) {
    return ReadiumReuseVerdict.incompatibleRevision;
  }
  if (!context.profile.sameProfile(snapshot.profile)) {
    return ReadiumReuseVerdict.incompatibleProfile;
  }
  if (!context.occurrence.sameOccurrence(snapshot.occurrence)) {
    return ReadiumReuseVerdict.incompatibleOccurrence;
  }

  return ReadiumReuseVerdict.verified;
}
