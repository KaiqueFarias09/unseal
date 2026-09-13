import 'dart:convert';
import 'dart:typed_data';

import 'seeded_random.dart';

/// Grammar-adjacent EPUB CFI string generation.
///
/// Produces canonical fragment identifiers over a synthetic book shape
/// plus deterministic near-miss variants (one grammar rule broken at a
/// time). The corpus keeps both so harnesses can assert resolution
/// success and rejection behavior side by side. Syntax follows the
/// EPUB CFI canonical grammar (`/even` element steps, `/odd:offset`
/// text steps, `!/` indirections, `[...]` assertions, `,` ranges,
/// `^`-escaped assertion characters).
final class CfiCase {
  const CfiCase({required this.cfi, required this.expectValid, required this.note});

  /// The fragment identifier string, including the `epubcfi(...)` wrapper.
  final String cfi;

  /// Whether a conformant parser should resolve this CFI.
  final bool expectValid;

  /// Why the case exists (grammar feature or the broken rule).
  final String note;

  Map<String, Object?> toJson() => <String, Object?>{
    'cfi': cfi,
    'expectValid': expectValid,
    'note': note,
  };
}

/// Generates valid CFIs over a synthetic spine of [spineCount] documents,
/// driven by [random].
List<CfiCase> validCfiCases(
  final SeededRandom random, {
  final int spineCount = 4,
  final int paragraphsPerDoc = 6,
}) {
  final spineEven = random.between(1, spineCount) * 2;
  final spineStep = '/6/$spineEven';
  final elementEven = random.between(1, paragraphsPerDoc) * 2;
  final otherElementEven = elementEven == 2 ? 4 : elementEven - 2;
  final charOffset = random.between(0, 40);
  final paraId = 'p$elementEven';
  final otherSpineEven = spineEven == 2 ? spineEven + 2 : spineEven - 2;
  final deep = List<String>.generate(random.between(3, 8), (final i) => '/${(i + 1) * 2}').join();

  return [
    // Bare element path without offset.
    CfiCase(
      cfi: 'epubcfi($spineStep!/4)',
      expectValid: true,
      note: 'indirection to bare element path',
    ),
    // Element + text offset.
    CfiCase(
      cfi: 'epubcfi($spineStep!/4/$elementEven/1:$charOffset)',
      expectValid: true,
      note: 'element step then odd text-offset step',
    ),
    // Zero offsets.
    CfiCase(
      cfi: 'epubcfi($spineStep!/4/$elementEven/1:0)',
      expectValid: true,
      note: 'zero character offset',
    ),
    // Id assertions at the spine step, an element and the paragraph.
    CfiCase(
      cfi: 'epubcfi(/6/$spineEven[spine$spineEven]!/4[body]/$elementEven[$paraId]/1:$charOffset)',
      expectValid: true,
      note: 'id assertions on multiple steps',
    ),
    // Escaped assertion characters (circumflex escapes ^ [ ] ;).
    CfiCase(
      cfi: 'epubcfi($spineStep!/4/$elementEven[we^^ird^[$paraId^]^;]/1:$charOffset)',
      expectValid: true,
      note: 'escaped ^ [ ] ; characters inside an id assertion',
    ),
    // Three-part range: shared ancestor, start, end.
    CfiCase(
      cfi:
          'epubcfi($spineStep!/4,$spineStep!/4/$elementEven/1:1,$spineStep!/4/$elementEven/1:$charOffset)',
      expectValid: true,
      note: 'three-part range with shared ancestor',
    ),
    // Two-part range across spine documents.
    CfiCase(
      cfi: 'epubcfi($spineStep!/4/$elementEven/1:0,/6/$otherSpineEven!/4/$otherElementEven/1:5)',
      expectValid: true,
      note: 'two-part range spanning two spine documents',
    ),
    // Range collapsing to a point (start equals end).
    CfiCase(
      cfi:
          'epubcfi($spineStep!/4,$spineStep!/4/$elementEven/1:$charOffset,$spineStep!/4/$elementEven/1:$charOffset)',
      expectValid: true,
      note: 'range whose start and end collapse to a point',
    ),
    // Deep path.
    CfiCase(
      cfi: 'epubcfi($spineStep!/4$deep/1:$charOffset)',
      expectValid: true,
      note: 'deeply nested element path',
    ),
  ];
}

/// Deterministic near-miss variants: each breaks ONE grammar rule.
List<CfiCase> malformedCfiCases(final List<CfiCase> validSeeds) {
  final base = validSeeds.first.cfi; // bare element path case
  final offsetCase = validSeeds[1].cfi; // ends with ".../1:<offset>)"
  final assertionCase = validSeeds[3].cfi; // contains "![" and escaped id
  return [
    CfiCase(cfi: base.substring(1), expectValid: false, note: 'missing opening wrapper character'),
    CfiCase(cfi: '$base)', expectValid: false, note: 'unbalanced closing parenthesis'),
    CfiCase(
      cfi: base.replaceFirst('epubcfi', 'epubCfi'),
      expectValid: false,
      note: 'scheme is case-sensitive',
    ),
    CfiCase(
      cfi: offsetCase.replaceFirst(RegExp(r'/1:\d+\)$'), ')'),
      expectValid: false,
      note: 'odd step missing its colon and offset',
    ),
    CfiCase(cfi: 'epubcfi()', expectValid: false, note: 'empty path'),
    CfiCase(
      cfi: 'epubcfi(/6/3!/4)',
      expectValid: false,
      note: 'odd step addressing a spine document',
    ),
    CfiCase(
      cfi: assertionCase.replaceFirst('![', '['),
      expectValid: false,
      note: 'indirection marker replaced by assertion',
    ),
    CfiCase(
      cfi: assertionCase.replaceFirst('^]', ']'),
      expectValid: false,
      note: 'unescaped closing bracket inside assertion',
    ),
    CfiCase(
      cfi: base.replaceAll('/', ''),
      expectValid: false,
      note: 'steps without leading slashes',
    ),
  ];
}

/// Builds the committed `cfi-cases.json` corpus payload.
Uint8List buildCfiCaseJson(final int seed) {
  final random = SeededRandom(seed);
  final valid = validCfiCases(random);
  final payload = <String, Object?>{
    'schemaVersion': 1,
    'seed': seed,
    'valid': [for (final c in valid) c.toJson()],
    'malformed': [for (final c in malformedCfiCases(valid)) c.toJson()],
  };
  return Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)));
}
