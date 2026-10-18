import 'package:unseal/unseal.dart';

/// Builds a canonical snapshot over [text] under a test identity, the
/// same shape the ALTO and PAGE tests use.
CanonicalTextSnapshot hocrSnapshot(final String text) => CanonicalTextSnapshot(
  identity: PublicationRevision(publicationId: 'test:hocr-target'),
  occurrence: SectionOccurrence(
    sectionIndex: 0,
    resourcePath: 'hocr.html',
    readingOrderRevision: 'sha256:${'1' * 64}',
  ),
  profile: TextProfile.of(
    algorithm: 'test.target',
    options: const <String, String>{},
    planRevision: 'sha256:${'0' * 64}',
  ),
  text: text,
);
