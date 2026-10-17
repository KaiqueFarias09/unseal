import 'package:test/test.dart';
import 'package:unseal/src/foundation/text/canonical_text_range.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/publication_revision.dart';
import 'package:unseal/src/foundation/text/revision_digest.dart';
import 'package:unseal/src/foundation/text/section_occurrence.dart';
import 'package:unseal/src/foundation/text/snapshot_codec.dart';
import 'package:unseal/src/foundation/text/text_profile.dart';

import '../../support/text_identity_vectors.dart';

void main() {
  group('revision digests (fixed vectors)', () {
    test('UTF-16LE bytes match the pinned vectors', () {
      expectUtf16leBytes(
        RevisionDigest.utf16leBytes(TextIdentityVectors.latin1Text),
        TextIdentityVectors.latin1Bytes,
      );
      expectUtf16leBytes(
        RevisionDigest.utf16leBytes(TextIdentityVectors.astralText),
        TextIdentityVectors.astralBytes,
      );
      expectUtf16leBytes(
        RevisionDigest.utf16leBytes(TextIdentityVectors.isolatedSurrogateText),
        TextIdentityVectors.isolatedSurrogateBytes,
      );
      expectUtf16leBytes(
        RevisionDigest.utf16leBytes(TextIdentityVectors.controlsText),
        TextIdentityVectors.controlsBytes,
      );
    });

    test('text revisions match the pinned digests', () {
      expectRevision(
        RevisionDigest.textRevision(TextIdentityVectors.latin1Text),
        TextIdentityVectors.latin1Revision,
      );
      expectRevision(
        RevisionDigest.textRevision(TextIdentityVectors.astralText),
        TextIdentityVectors.astralRevision,
      );
      expectRevision(
        RevisionDigest.textRevision(TextIdentityVectors.isolatedSurrogateText),
        TextIdentityVectors.isolatedSurrogateRevision,
      );
      expectRevision(
        RevisionDigest.textRevision(TextIdentityVectors.controlsText),
        TextIdentityVectors.controlsRevision,
      );
    });

    test('isolated surrogates survive byte for byte', () {
      final bytes = RevisionDigest.utf16leBytes(TextIdentityVectors.isolatedSurrogateText);
      // "texto " is 12 bytes, then the lone surrogate D800 little-endian.
      expect(bytes[12], 0x00);
      expect(bytes[13], 0xD8);
    });

    test('reading order revisions match, and order changes them', () {
      expectRevision(
        RevisionDigest.readingOrderRevision(TextIdentityVectors.readingOrder),
        TextIdentityVectors.readingOrderRevision,
      );
      expectRevision(
        RevisionDigest.readingOrderRevision(TextIdentityVectors.reorderedReadingOrder),
        TextIdentityVectors.reorderedReadingOrderRevision,
      );
      expect(
        TextIdentityVectors.readingOrderRevision,
        isNot(TextIdentityVectors.reorderedReadingOrderRevision),
      );
    });

    test('repeated paths stay in the digest input as distinct positions', () {
      final single = RevisionDigest.readingOrderRevision(const [('page_1.html', true)]);
      final twice = RevisionDigest.readingOrderRevision(const [
        ('page_1.html', true),
        ('page_1.html', true),
      ]);
      expect(single, isNot(twice));
    });

    test('profile ids match the pinned digest and follow their parts', () {
      final profile = TextProfile.of(
        algorithm: TextIdentityVectors.profileAlgorithm,
        options: TextIdentityVectors.profileOptions,
        planRevision: TextIdentityVectors.profilePlanRevision,
      );
      expectRevision(profile.id, TextIdentityVectors.profileRevision);

      final otherPlan = TextProfile.of(
        algorithm: TextIdentityVectors.profileAlgorithm,
        options: TextIdentityVectors.profileOptions,
        planRevision: 'sha256:${'11' * 32}',
      );
      expect(profile.sameProfile(otherPlan), isFalse);
    });

    test('profile options cannot change after their identity is computed', () {
      final options = <String, String>{'mode': 'reflow'};
      final profile = TextProfile.of(
        algorithm: 'pdf',
        options: options,
        planRevision: TextIdentityVectors.profilePlanRevision,
      );
      final originalId = profile.id;
      options['mode'] = 'facsimile';
      expect(profile.options, {'mode': 'reflow'});
      expect(() => profile.options['mode'] = 'facsimile', throwsUnsupportedError);
      expect(profile.id, originalId);
    });

    test('equal profiles have equal hashes regardless of option insertion order', () {
      final first = TextProfile.of(
        algorithm: 'pdf',
        options: {'mode': 'reflow', 'columns': 'two'},
        planRevision: TextIdentityVectors.profilePlanRevision,
      );
      final second = TextProfile.of(
        algorithm: 'pdf',
        options: {'columns': 'two', 'mode': 'reflow'},
        planRevision: TextIdentityVectors.profilePlanRevision,
      );
      expect(first, second);
      expect(first.id, second.id);
      expect(first.hashCode, second.hashCode);
      expect({first}.contains(second), isTrue);
      expect(first.options.keys, ['columns', 'mode']);
    });

    test('compact JSON matches the pinned shape (sorted keys, escapes)', () {
      expect(
        RevisionDigest.encodeCompactJson(TextIdentityVectors.compactJsonPayload),
        TextIdentityVectors.compactJsonSample,
      );
    });
  });

  group('identity validation', () {
    test('publication ids must be namespaced and whitespace-free', () {
      expect(() => PublicationRevision(publicationId: 'no-namespace'), throwsArgumentError);
      expect(() => PublicationRevision(publicationId: ':empty-prefix'), throwsArgumentError);
      expect(() => PublicationRevision(publicationId: 'ns:has space'), throwsArgumentError);
      expect(
        () => PublicationRevision(publicationId: 'library:alices-adventures'),
        returnsNormally,
      );
    });

    test('evidence kinds are mutually exclusive with the revision shape', () {
      expect(
        () => PublicationRevision(publicationId: 'a:b', sourceRevision: 'sha256:${'ab' * 32}'),
        throwsArgumentError,
      );
      expect(
        () => PublicationRevision(
          publicationId: 'a:b',
          sourceRevision: 'sha256:NOTHEX',
          sourceEvidence: SourceEvidence.sha256,
        ),
        throwsArgumentError,
      );
      expect(
        () => PublicationRevision(
          publicationId: 'a:b',
          sourceRevision: 'sha256:${'ab' * 32}',
          sourceEvidence: SourceEvidence.host,
        ),
        throwsArgumentError,
      );
      final host = PublicationRevision(
        publicationId: 'a:b',
        sourceRevision: 'sync:v7-cache-key',
        sourceEvidence: SourceEvidence.host,
      );
      expect(host.sourceEvidence, SourceEvidence.host);
    });

    test('occurrences reject negative indexes and malformed digests', () {
      expect(
        () =>
            SectionOccurrence(sectionIndex: -1, resourcePath: 'p.html', readingOrderRevision: null),
        throwsArgumentError,
      );
      expect(
        () => SectionOccurrence(sectionIndex: 0, resourcePath: '', readingOrderRevision: null),
        throwsArgumentError,
      );
      expect(
        () => SectionOccurrence(
          sectionIndex: 0,
          resourcePath: 'p.html',
          readingOrderRevision: 'sha256:short',
        ),
        throwsArgumentError,
      );
    });

    test('the same path repeated yields distinct occurrences', () {
      final first = TextIdentityVectors.occurrence();
      final second = SectionOccurrence(
        sectionIndex: 4,
        resourcePath: first.resourcePath,
        readingOrderRevision: first.readingOrderRevision,
      );
      expect(first, isNot(second));
      expect(first.sameOccurrence(second), isFalse);
    });
  });

  group('snapshots and ranges', () {
    CanonicalTextSnapshot snapshot() => CanonicalTextSnapshot(
      identity: TextIdentityVectors.verifiedIdentity(),
      occurrence: TextIdentityVectors.occurrence(),
      profile: TextIdentityVectors.profile(),
      text: 'Trecho 📖 duplicado e mais.',
    );

    test('capture computes the text revision and derived length', () {
      final captured = snapshot();
      expect(captured.schemaVersion, 1);
      expect(captured.textRevision, RevisionDigest.textRevision(captured.text));
      expect(captured.utf16Length, captured.text.length);
      expect(captured.isExportable, isTrue);
    });

    test('identity compares every field including explicit nulls', () {
      final captured = snapshot();
      final same = CanonicalTextSnapshot(
        identity: TextIdentityVectors.verifiedIdentity(),
        occurrence: TextIdentityVectors.occurrence(),
        profile: TextIdentityVectors.profile(),
        text: captured.text,
      );
      expect(captured.sameIdentity(same), isTrue);
      expect(captured.identityKey, same.identityKey);

      final otherSection = CanonicalTextSnapshot(
        identity: TextIdentityVectors.verifiedIdentity(),
        occurrence: SectionOccurrence(
          sectionIndex: 4,
          resourcePath: 'page_4.html',
          readingOrderRevision: TextIdentityVectors.readingOrderRevision,
        ),
        profile: TextIdentityVectors.profile(),
        text: captured.text,
      );
      expect(captured.sameIdentity(otherSection), isFalse);

      final unknownSource = CanonicalTextSnapshot(
        identity: PublicationRevision(publicationId: 'library:alices-adventures'),
        occurrence: captured.occurrence,
        profile: captured.profile,
        text: captured.text,
      );
      expect(captured.sameIdentity(unknownSource), isFalse);
      expect(unknownSource.isExportable, isFalse);
    });

    test('ranges validate bounds and a point uses start == end', () {
      final captured = snapshot();
      expect(() => CanonicalTextRange(snapshot: captured, start: -1, end: 2), throwsArgumentError);
      expect(() => CanonicalTextRange(snapshot: captured, start: 4, end: 3), throwsArgumentError);
      expect(
        () => CanonicalTextRange(snapshot: captured, start: 0, end: captured.utf16Length + 1),
        throwsArgumentError,
      );

      final range = CanonicalTextRange(snapshot: captured, start: 2, end: 6);
      expect(range.text, captured.text.substring(2, 6));
      final point = CanonicalTextRange.point(snapshot: captured, offset: 2);
      expect(point.isPoint, isTrue);
      expect(point.text, '');
    });

    test('astral offsets count code units, not runes', () {
      const text = 'a\u{1F4D6}b';
      final captured = CanonicalTextSnapshot(
        identity: TextIdentityVectors.verifiedIdentity(),
        occurrence: TextIdentityVectors.occurrence(),
        profile: TextIdentityVectors.profile(),
        text: text,
      );
      expect(captured.utf16Length, 4);
      expect(text.runes.length, 3);
      final whole = CanonicalTextRange(snapshot: captured, start: 0, end: 4);
      expect(whole.text, text);
      // Splitting between the surrogate pair is representable —
      // validity never certifies a grapheme boundary.
      final midPair = CanonicalTextRange(snapshot: captured, start: 1, end: 2);
      expect(midPair.text, isA<String>());
    });
  });

  group('codec', () {
    CanonicalTextSnapshot snapshot() => CanonicalTextSnapshot(
      identity: TextIdentityVectors.verifiedIdentity(),
      occurrence: TextIdentityVectors.occurrence(),
      profile: TextIdentityVectors.profile(),
      text: 'Trecho 📖 para o codec, com "aspas" e \\barra.',
    );

    test('round trip preserves the full tuple', () {
      final captured = snapshot();
      final decoded = CanonicalTextCodec.decode(CanonicalTextCodec.encode(captured));
      expect(captured.sameIdentity(decoded), isTrue);
      expect(decoded.text, captured.text);
      CanonicalTextCodec.verifyCompatible(decoded, captured);
    });

    test('range round trip preserves bounds', () {
      final captured = snapshot();
      final range = CanonicalTextRange(snapshot: captured, start: 3, end: 9);
      final decoded = CanonicalTextCodec.decodeRange(CanonicalTextCodec.encodeRange(range));
      expect(decoded.start, 3);
      expect(decoded.end, 9);
      expect(decoded.text, range.text);
      expect(decoded.snapshot.sameIdentity(captured), isTrue);
    });

    test('export refuses an in-memory-only identity explicitly', () {
      final captured = CanonicalTextSnapshot(
        identity: PublicationRevision(publicationId: 'library:unverified'),
        occurrence: SectionOccurrence(
          sectionIndex: 0,
          resourcePath: 'page_1.html',
          readingOrderRevision: null,
        ),
        profile: TextIdentityVectors.profile(),
        text: 'Trabalho em memória.',
      );
      expect(captured.isExportable, isFalse);
      expect(
        () => CanonicalTextCodec.encode(captured),
        throwsA(isA<CanonicalTextCodecException>()),
      );
    });

    test('hostile payloads normalize to the codec exception', () {
      expect(() => CanonicalTextCodec.decode(null), throwsA(isA<CanonicalTextCodecException>()));
      expect(
        () => CanonicalTextCodec.decode('string'),
        throwsA(isA<CanonicalTextCodecException>()),
      );
      expect(
        () => CanonicalTextCodec.decode(<String, Object?>{}),
        throwsA(isA<CanonicalTextCodecException>()),
      );
      expect(
        () => CanonicalTextCodec.decode(<String, Object?>{'schemaVersion': 2}),
        throwsA(isA<CanonicalTextCodecException>()),
      );

      final encoded = CanonicalTextCodec.encode(snapshot());
      final swappedText = <String, Object?>{...encoded, 'text': 'outro texto'};
      expect(
        () => CanonicalTextCodec.decode(swappedText),
        throwsA(isA<CanonicalTextCodecException>()),
      );

      final swappedProfile = <String, Object?>{
        ...encoded,
        'profile': <String, Object?>{
          ...(encoded['profile'] as Map<String, Object?>),
          'planRevision': 'sha256:${'22' * 32}',
        },
      };
      expect(
        () => CanonicalTextCodec.decode(swappedProfile),
        throwsA(isA<CanonicalTextCodecException>()),
      );

      final badEvidence = <String, Object?>{
        ...encoded,
        'publication': <String, Object?>{
          ...(encoded['publication'] as Map<String, Object?>),
          'sourceEvidence': 'quantum',
        },
      };
      expect(
        () => CanonicalTextCodec.decode(badEvidence),
        throwsA(isA<CanonicalTextCodecException>()),
      );
    });

    test('a destination confirms imported claims or the reuse fails typed', () {
      final captured = snapshot();
      final decoded = CanonicalTextCodec.decode(CanonicalTextCodec.encode(captured));

      final otherEdition = CanonicalTextSnapshot(
        identity: PublicationRevision(
          publicationId: captured.identity.publicationId,
          editionId: 'outra-edicao',
          sourceRevision: captured.identity.sourceRevision,
          sourceEvidence: SourceEvidence.sha256,
        ),
        occurrence: captured.occurrence,
        profile: captured.profile,
        text: captured.text,
      );
      expect(
        () => CanonicalTextCodec.verifyCompatible(decoded, otherEdition),
        throwsA(isA<IncompatibleRevisionException>()),
      );

      final otherText = CanonicalTextSnapshot(
        identity: captured.identity,
        occurrence: captured.occurrence,
        profile: captured.profile,
        text: '${captured.text} revisado',
      );
      expect(
        () => CanonicalTextCodec.verifyCompatible(decoded, otherText),
        throwsA(isA<IncompatibleRevisionException>()),
      );
    });
  });
}
