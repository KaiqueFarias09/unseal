import 'package:unseal/unseal.dart';

/// Builds a canonical snapshot over [text] under a test identity, the
/// same shape the ALTO and durable-anchor tests use.
CanonicalTextSnapshot pageSnapshot(final String text) => CanonicalTextSnapshot(
  identity: PublicationRevision(publicationId: 'test:page-target'),
  occurrence: SectionOccurrence(
    sectionIndex: 0,
    resourcePath: 'page.html',
    readingOrderRevision: 'sha256:${'1' * 64}',
  ),
  profile: TextProfile.of(
    algorithm: 'test.target',
    options: const <String, String>{},
    planRevision: 'sha256:${'0' * 64}',
  ),
  text: text,
);
