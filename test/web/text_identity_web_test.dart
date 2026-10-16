@TestOn('browser')
library;

import 'package:test/test.dart';
import 'package:unseal/src/foundation/text/revision_digest.dart';

import '../support/text_identity_vectors.dart';

/// Runs the fixed P0 digest vectors inside Chrome: the same bytes and
/// hashes the VM suite pins must come out of the browser, where UTF-16
/// strings and SHA-256 run through dart2js.
void main() {
  test('UTF-16LE bytes are identical to the pinned vectors', () {
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

  test('reading order and profile revisions match the pinned digests', () {
    expectRevision(
      RevisionDigest.readingOrderRevision(TextIdentityVectors.readingOrder),
      TextIdentityVectors.readingOrderRevision,
    );
    expectRevision(
      RevisionDigest.readingOrderRevision(TextIdentityVectors.reorderedReadingOrder),
      TextIdentityVectors.reorderedReadingOrderRevision,
    );
    expectRevision(
      RevisionDigest.textProfileRevision(
        algorithm: TextIdentityVectors.profileAlgorithm,
        options: TextIdentityVectors.profileOptions,
        planRevision: TextIdentityVectors.profilePlanRevision,
      ),
      TextIdentityVectors.profileRevision,
    );
  });

  test('compact JSON matches the pinned shape', () {
    expect(
      RevisionDigest.encodeCompactJson(TextIdentityVectors.compactJsonPayload),
      TextIdentityVectors.compactJsonSample,
    );
  });
}
