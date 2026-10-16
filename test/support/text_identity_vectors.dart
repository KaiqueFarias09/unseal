import 'package:unseal/src/foundation/text/publication_revision.dart';
import 'package:unseal/src/foundation/text/section_occurrence.dart';
import 'package:unseal/src/foundation/text/text_profile.dart';

/// The fixed P0 conformance vectors: byte-level UTF-16LE inputs and the
/// exact digests they must produce on the VM and in Chrome.
///
/// These values pin the common text contract. If a change here is
/// intended, every persisted snapshot and reading order minted before
/// it becomes a different revision by definition — that is the contract
/// working, and the changelog entry must say so.
abstract final class TextIdentityVectors {
  const TextIdentityVectors._();

  /// Portuguese text with an em dash, quotes and a backslash.
  static const latin1Text = 'Página 12 — navegação: "aspas", \\barra\\, fim.';

  /// The UTF-16LE bytes of [latin1Text], pinned byte for byte.
  static const latin1Bytes = <int>[
    80, 0, 225, 0, 103, 0, 105, 0, 110, 0, 97, 0, 32, 0, 49, 0, 50, 0, 32, 0, //
    20, 32, 32, 0, 110, 0, 97, 0, 118, 0, 101, 0, 103, 0, 97, 0, 231, 0, 227, 0, //
    111, 0, 58, 0, 32, 0, 34, 0, 97, 0, 115, 0, 112, 0, 97, 0, 115, 0, 34, 0, //
    44, 0, 32, 0, 92, 0, 98, 0, 97, 0, 114, 0, 114, 0, 97, 0, 92, 0, 44, 0, //
    32, 0, 102, 0, 105, 0, 109, 0, 46, 0, //
  ];

  /// The text revision [latin1Text] must produce.
  static const latin1Revision =
      'sha256:c445486d27e839f4578287fc4f2dfef5d82ba036074c41b6594e0fa87d66ca96';

  /// Text with astral characters (surrogate pairs in UTF-16).
  static const astralText = 'livro 📖 e nota 𝄞';

  /// The UTF-16LE bytes of [astralText], pinned byte for byte.
  static const astralBytes = <int>[
    108, 0, 105, 0, 118, 0, 114, 0, 111, 0, 32, 0, //
    61, 216, 214, 220, 32, 0, 101, 0, 32, 0, //
    110, 0, 111, 0, 116, 0, 97, 0, 32, 0, //
    52, 216, 30, 221, //
  ];

  /// The text revision [astralText] must produce.
  static const astralRevision =
      'sha256:c55e6edcddb9a644fcb3d0d6ee480194b46cfd11614838ae160a57799aa5ae4a';

  /// Text carrying an isolated (unpaired) high surrogate, preserved
  /// exactly as the input carries it — no replacement, no error.
  static const isolatedSurrogateText = 'texto \uD800 isolado';

  /// The UTF-16LE bytes of [isolatedSurrogateText], pinned byte for
  /// byte.
  static const isolatedSurrogateBytes = <int>[
    116, 0, 101, 0, 120, 0, 116, 0, 111, 0, 32, 0, //
    0, 216, 32, 0, //
    105, 0, 115, 0, 111, 0, 108, 0, 97, 0, 100, 0, 111, 0, //
  ];

  /// The text revision [isolatedSurrogateText] must produce.
  static const isolatedSurrogateRevision =
      'sha256:e7b719bcc9e5bf7c00c31591338c44ac0244fd0ba96e3c9e8692cde6b8d65034';

  /// Text with the characters the compact JSON serializer escapes.
  static const controlsText = 'a"b\\c\nd\te\u0001f\u2028g\u2029';

  /// The UTF-16LE bytes of [controlsText], pinned byte for byte.
  static const controlsBytes = <int>[
    97, 0, 34, 0, 98, 0, 92, 0, 99, 0, 10, 0, 100, 0, 9, 0, //
    101, 0, 1, 0, 102, 0, 40, 32, 103, 0, 41, 32, //
  ];

  /// The text revision [controlsText] must produce.
  static const controlsRevision =
      'sha256:dd4447e083a8be4badf6f0684c11ddfea096312213a60a4476c8a620bd042d12';

  /// A reading order with a repeated path (two occurrences of
  /// `page_1.html`) and a non-HTML entry.
  static const readingOrder = <(String, bool)>[
    ('page_1.html', true),
    ('capitulo/um.xhtml', true),
    ('page_1.html', true),
    ('imagens/plate.png', false),
  ];

  /// The digest [readingOrder] must produce.
  static const readingOrderRevision =
      'sha256:cc3d1ae341a73f2213de03ec918935457f2b0a27a6649060b0017b0d41067f80';

  /// The same entries in a different order — a different revision,
  /// because array position is occurrence identity.
  static const reorderedReadingOrder = <(String, bool)>[
    ('capitulo/um.xhtml', true),
    ('page_1.html', true),
    ('page_1.html', true),
    ('imagens/plate.png', false),
  ];

  /// The digest [reorderedReadingOrder] must produce.
  static const reorderedReadingOrderRevision =
      'sha256:9cd512283c0729adbe3c335bc452cc90b3a630d6328264133a2b50c9b6ae82e8';

  /// Profile parts whose digest is pinned.
  static const profileAlgorithm = 'pdf.reflow';
  static const profileOptions = <String, String>{'preferHtml': 'true', 'samplePages': '20'};
  static const profilePlanRevision =
      'sha256:0000000000000000000000000000000000000000000000000000000000000000';

  /// The profile id the parts above must produce.
  static const profileRevision =
      'sha256:d8afbfd76068b534bb59a99f7ebac652c3da070b55f02b3f936307eef6242aa8';

  /// The compact JSON shape the serializer emits for a mixed payload:
  /// object keys sorted, string escapes applied, no whitespace.
  static const compactJsonSample = '["a\\"b",true,{"a":null,"z":1}]';

  /// The sample payload [compactJsonSample] encodes.
  static Object get compactJsonPayload => <Object?>[
    'a"b',
    true,
    <String, Object?>{'z': 1, 'a': null},
  ];

  /// A snapshot identity fixture the tests reuse: verified sha256
  /// source, known reading order.
  static PublicationRevision verifiedIdentity() => PublicationRevision(
    publicationId: 'library:alices-adventures',
    editionId: 'gutenberg-11',
    sourceRevision: 'sha256:0f343b0931126a20f133d67c2b018a3b20b21d1e0b0a2d923f0f3b93a3b0f2c1',
    sourceEvidence: SourceEvidence.sha256,
  );

  /// The occurrence fixture paired with [verifiedIdentity].
  static SectionOccurrence occurrence() => SectionOccurrence(
    sectionIndex: 3,
    resourcePath: 'page_4.html',
    readingOrderRevision: readingOrderRevision,
  );

  /// The profile fixture paired with [verifiedIdentity].
  static TextProfile profile() => TextProfile.of(
    algorithm: profileAlgorithm,
    options: profileOptions,
    planRevision: profilePlanRevision,
  );
}

/// Whether [actual] matches the pinned [expected] revision, with a
/// failure message naming both.
void expectRevision(final String actual, final String expected) {
  if (actual != expected) {
    throw StateError('Revision mismatch: got $actual, expected $expected');
  }
}

/// Whether [actual] matches the pinned [expected] UTF-16LE bytes.
void expectUtf16leBytes(final List<int> actual, final List<int> expected) {
  if (actual.length != expected.length) {
    throw StateError('Byte length mismatch: ${actual.length} vs ${expected.length}');
  }
  for (var i = 0; i < expected.length; i++) {
    if (actual[i] != expected[i]) {
      throw StateError('Byte mismatch at $i: ${actual[i]} vs ${expected[i]}');
    }
  }
}
