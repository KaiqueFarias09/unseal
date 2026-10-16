import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

import 'book_index_fixture.dart';

void main() {
  group('digest vectors (C02 spec: sha256: over UTF-16LE, no BOM, no normalization)', () {
    test('empty text matches the well-known sha256 of zero bytes', () {
      expect(
        textRevisionOf(''),
        'sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('ascii text is the sha256 of its little-endian code units', () {
      // sha256('61 00 62 00 63 00').
      expect(
        textRevisionOf('abc'),
        'sha256:13e228567e8249fce53337f25d7970de3bd68ab2653424c7b8f9fd05e33caedf',
      );
    });

    test('astral text hashes both surrogate code units', () {
      // 'a\uD83D\uDE00b' as UTF-16LE: 61 00 3D D8 00 DE 62 00.
      expect(
        textRevisionOf('a\u{1F600}b'),
        'sha256:5edeaa328793b227772ee0191c405fa048d89982b6593783a4b20e45822dc0d5',
      );
    });

    test('reading order revision hashes the compact json array', () {
      // Compact json: [["cap1.html",true],["page1.html",false]].
      expect(
        readingOrderRevisionOf([
          const ReadingOrderItem(name: 'cap1.html', isHtml: true),
          const ReadingOrderItem(name: 'page1.html', isHtml: false),
        ]),
        'sha256:c51a9bd78f25cfdc73dd96e1b94abdb62d62179030409e39047a294fcd7f6529',
      );
    });

    test('matches the common text contract fixed vectors (P0 conformance)', () {
      // The vectors A01's P0 pins in test/support/text_identity_vectors.dart;
      // reproducing them here proves the temporary adapter is
      // byte-compatible with the shared implementation.
      expect(
        textRevisionOf('Página 12 — navegação: "aspas", \\barra\\, fim.'),
        'sha256:c445486d27e839f4578287fc4f2dfef5d82ba036074c41b6594e0fa87d66ca96',
      );
      expect(
        textRevisionOf('livro 📖 e nota 𝄞'),
        'sha256:c55e6edcddb9a644fcb3d0d6ee480194b46cfd11614838ae160a57799aa5ae4a',
      );
      expect(
        textRevisionOf('texto \uD800 isolado'),
        'sha256:e7b719bcc9e5bf7c00c31591338c44ac0244fd0ba96e3c9e8692cde6b8d65034',
      );
      expect(
        readingOrderRevisionOf([
          const ReadingOrderItem(name: 'page_1.html', isHtml: true),
          const ReadingOrderItem(name: 'capitulo/um.xhtml', isHtml: true),
          const ReadingOrderItem(name: 'page_1.html', isHtml: true),
          const ReadingOrderItem(name: 'imagens/plate.png', isHtml: false),
        ]),
        'sha256:cc3d1ae341a73f2213de03ec918935457f2b0a27a6649060b0017b0d41067f80',
      );
      // Array position is occurrence identity: reordering changes the
      // revision.
      expect(
        readingOrderRevisionOf([
          const ReadingOrderItem(name: 'capitulo/um.xhtml', isHtml: true),
          const ReadingOrderItem(name: 'page_1.html', isHtml: true),
          const ReadingOrderItem(name: 'page_1.html', isHtml: true),
          const ReadingOrderItem(name: 'imagens/plate.png', isHtml: false),
        ]),
        'sha256:9cd512283c0729adbe3c335bc452cc90b3a630d6328264133a2b50c9b6ae82e8',
      );
    });
  });

  group('serialization and import', () {
    Future<BookSearchIndex> builtIndex() => BookSearchIndex.build(
      buildIndexedBook(<int, String>{0: 'A navegação do leitor.', 1: 'Outro feitiço.'}),
    );

    test('round trip preserves results, ranking and ranges', () async {
      final book = buildIndexedBook(<int, String>{
        0: 'A navegação do leitor.',
        1: 'Outro feitiço.',
      });
      final index = await BookSearchIndex.build(book);
      final before = index.query('navegacao');
      // Structural reload: identical hits and bit-identical scores; the
      // snippet stays empty because no text source was provided.
      final structural = BookSearchIndex.deserialize(index.serialize());
      final after = structural.query('navegacao');
      expect(after.hits, hasLength(before.hits.length));
      expect(after.hits.single.sectionIndex, before.hits.single.sectionIndex);
      expect(after.hits.single.start, before.hits.single.start);
      expect(after.hits.single.end, before.hits.single.end);
      expect(after.hits.single.score, before.hits.single.score);
      expect(after.coverage.isComplete, isTrue);
      // Prefix queries behave identically after the reload.
      final prefixBefore = index.query('nave', mode: IndexedQueryMode.prefix);
      final prefixAfter = structural.query('nave', mode: IndexedQueryMode.prefix);
      expect(prefixAfter.hits, hasLength(prefixBefore.hits.length));
      // Verified reload with the book: snippets come back too.
      final verified = BookSearchIndex.deserialize(index.serialize(), book: book);
      expect(verified.query('navegacao').hits.single.snippet, before.hits.single.snippet);
    });

    test('serialization is deterministic for identical builds', () async {
      final payload = (await builtIndex()).serialize();
      final again = (await builtIndex()).serialize();
      expect(again.toString(), payload.toString());
    });

    test('identity survives the round trip and gates imports', () async {
      const identity = SearchIndexIdentity(
        publicationId: 'ns:fixture',
        sourceRevision: 'sha256:abc',
        sourceEvidence: SearchSourceEvidence.sha256,
      );
      final index = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{0: 'palavra'}),
        identity: identity,
      );
      final restored = BookSearchIndex.deserialize(index.serialize());
      expect(restored.identity.publicationId, 'ns:fixture');
      expect(restored.identity.sourceEvidence, SearchSourceEvidence.sha256);
      // A different identity refuses the payload.
      expect(
        () => BookSearchIndex.deserialize(
          index.serialize(),
          identity: const SearchIndexIdentity(publicationId: 'ns:other'),
        ),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
    });

    test('verification against the book catches text changes', () async {
      final book = buildIndexedBook(<int, String>{0: 'versão original', 1: 'segunda'});
      final index = await BookSearchIndex.build(book);
      // Same structure, one section edited under the same name.
      final edited = buildIndexedBook(<int, String>{0: 'versão editada', 1: 'segunda'});
      expect(
        () => BookSearchIndex.deserialize(index.serialize(), book: edited),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
      // The unmodified book verifies and reloads.
      final restored = BookSearchIndex.deserialize(index.serialize(), book: book);
      expect(restored.query('original').hits, hasLength(1));
    });

    test('verification against the book catches order changes', () async {
      final book = buildIndexedBook(<int, String>{0: 'primeira', 1: 'segunda'});
      final index = await BookSearchIndex.build(book);
      final reordered = buildIndexedBook(<int, String>{0: 'segunda', 1: 'primeira'});
      expect(
        () => BookSearchIndex.deserialize(index.serialize(), book: reordered),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
    });

    test('schema and profile mismatches refuse the payload', () async {
      final index = await builtIndex();
      final payload = index.serialize();
      final wrongSchema = <String, Object?>{...payload, 'schemaVersion': 2};
      expect(
        () => BookSearchIndex.deserialize(wrongSchema),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
      final profile = <String, Object?>{
        ...(payload['profile'] as Map<String, Object?>),
        'tokenizer': 'other-tokenizer/9',
      };
      final wrongProfile = <String, Object?>{...payload, 'profile': profile};
      expect(
        () => BookSearchIndex.deserialize(wrongProfile),
        throwsA(isA<SearchIndexIncompatibleException>()),
      );
    });

    test('hostile payloads fail before allocations', () {
      expect(
        () => BookSearchIndex.deserialize(<String, Object?>{}),
        throwsA(isA<FormatException>()),
      );
      // A section entry with a malformed field.
      expect(
        () => BookSearchIndex.deserialize(<String, Object?>{
          'schemaVersion': 1,
          'profile': <String, Object?>{
            'tokenizer': SearchIndexTokenizer.tokenizerId,
            'normalization': SearchIndexTokenizer.normalizationId,
            'textProfile': SearchIndexTokenizer.textProfileId,
          },
          'readingOrderRevision': null,
          'sections': <Object?>[
            <Object?>[0, 'p0.html', 'many', 5, 'sha256:${'x' * 64}'],
          ],
          'terms': <Object?>[],
        }),
        throwsA(isA<FormatException>()),
      );
      // A range outside the declared section text.
      expect(
        () => BookSearchIndex.deserialize(<String, Object?>{
          'schemaVersion': 1,
          'profile': <String, Object?>{
            'tokenizer': SearchIndexTokenizer.tokenizerId,
            'normalization': SearchIndexTokenizer.normalizationId,
            'textProfile': SearchIndexTokenizer.textProfileId,
          },
          'identity': null,
          'readingOrderRevision': null,
          'sections': <Object?>[
            <Object?>[0, 'a.html', 1, 5, 'sha256:${'x' * 64}'],
          ],
          'terms': <Object?>[
            <Object?>[
              'palavra',
              <Object?>[
                <Object?>[
                  0,
                  <Object?>[0, 999],
                ],
              ],
            ],
          ],
        }),
        throwsA(isA<FormatException>()),
      );
      // Negative offsets and odd range lists fail the same way.
      expect(
        () => BookSearchIndex.deserialize(<String, Object?>{
          'schemaVersion': 1,
          'profile': <String, Object?>{
            'tokenizer': SearchIndexTokenizer.tokenizerId,
            'normalization': SearchIndexTokenizer.normalizationId,
            'textProfile': SearchIndexTokenizer.textProfileId,
          },
          'identity': null,
          'readingOrderRevision': null,
          'sections': <Object?>[
            <Object?>[0, 'a.html', 1, 5, 'sha256:${'x' * 64}'],
          ],
          'terms': <Object?>[
            <Object?>[
              'palavra',
              <Object?>[
                <Object?>[
                  0,
                  <Object?>[-1, 3],
                ],
              ],
            ],
          ],
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('imports above the payload cap refuse before parsing', () async {
      // A wide book keeps the payload above the clamped 1024-unit floor.
      final wide = await BookSearchIndex.build(
        buildIndexedBook(<int, String>{
          for (var i = 0; i < 8; i++)
            i:
                'seção $i com bastante conteúdo textual para inflar o payload '
                'serializado além do teto configurado no teste $i',
        }),
      );
      expect(
        () => BookSearchIndex.deserialize(
          wide.serialize(),
          limits: const SearchIndexLimits(maxSerializedBytes: 1024),
        ),
        throwsA(isA<SearchIndexLimitExceededException>()),
      );
    });

    test('incomplete indexes refuse to serialize', () async {
      final index = BookSearchIndex.empty();
      final pending = index.beginEligible([
        const ReadingOrderItem(name: 'a.html', isHtml: true),
        const ReadingOrderItem(name: 'b.html', isHtml: true),
      ]);
      index.addSection(sectionIndex: pending[0].$1, path: pending[0].$2, text: 'palavra');
      expect(index.serialize, throwsA(isA<SearchIndexException>()));
    });

    test('pdf-sourced indexes build and query but refuse persistence', () async {
      // The adapter marks PDF indexes unpersistable; prove the gate.
      final index = BookSearchIndex.empty(persistable: false);
      final pending = index.beginEligible([
        const ReadingOrderItem(name: 'page_1.html', isHtml: true),
      ]);
      index.addSection(sectionIndex: pending[0].$1, path: pending[0].$2, text: 'texto do pdf');
      expect(index.query('texto').hits, hasLength(1));
      expect(index.serialize, throwsA(isA<SearchIndexUnsupportedException>()));
    });

    test('disposed indexes refuse serialization and import', () async {
      final index = await builtIndex();
      final payload = index.serialize();
      index.dispose();
      expect(index.serialize, throwsA(isA<SearchIndexDisposedException>()));
      final restored = BookSearchIndex.deserialize(payload);
      restored.dispose();
      expect(() => restored.query('navegacao'), throwsA(isA<SearchIndexDisposedException>()));
    });
  });
}
