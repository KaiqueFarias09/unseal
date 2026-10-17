import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:unseal/src/features/annotations/durable/anchor_resolution.dart';
import 'package:unseal/src/features/annotations/durable/durable_annotations.dart';
import 'package:unseal/src/features/djvu/djvu_page_structure.dart';
import 'package:unseal/src/features/djvu/parse_djvu_book.dart';
import 'package:unseal/src/features/search/index/book_search_index.dart';
import 'package:unseal/src/features/search/index/indexed_query_mode.dart';
import 'package:unseal/src/features/search/index/search_index_identity.dart';
import 'package:unseal/src/foundation/spatial/spatial_text_zone.dart';
import 'package:unseal/src/foundation/text/canonical_text_snapshot.dart';
import 'package:unseal/src/foundation/text/publication_revision.dart';

void main() {
  final goody = File('test/resources/djvu/goody-twoshoes.djvu').readAsBytesSync();
  final identity = PublicationRevision(
    publicationId: 'test:goody-spatial',
    sourceRevision: 'sha256:${sha256.convert(goody).toString()}',
    sourceEvidence: SourceEvidence.sha256,
  );

  test('index hits, zones and anchors address one hidden-text space', () async {
    final book = parseDjvuBook(goody);
    final index = await BookSearchIndex.build(book, identity: SearchIndexIdentity());
    expect(index.isComplete, isTrue);
    expect(index.extractionProfileId, djvuHiddenTextProfile.id);

    // A page-2 headline word the corpus comparison pinned.
    final results = index.query('COLLECTION', mode: IndexedQueryMode.exact);
    expect(results.hits, isNotEmpty);
    // The word also sits in page 2's headline; take that occurrence so
    // the zone alignment below is the corpus-compared one.
    final pageTwoHits = results.hits.where((h) => h.sectionIndex == 1).toList();
    expect(pageTwoHits, isNotEmpty, reason: 'page 2 carries the headline word');
    final hit = pageTwoHits.first;

    // The hit's UTF-16 range sits inside a word zone of that page's
    // spatial structure. DjVu word zones carry their trailing separator
    // byte in the stored range, so the token cuts the word itself.
    final structure = book.pageStructureAt(hit.sectionIndex)!;
    final word = structure.lookup!.wordAt(hit.start);
    expect(word, isNotNull);
    expect(word!.kind, SpatialZoneKind.word);
    expect(hit.start, inInclusiveRange(word.textStart, word.textEnd));
    expect(hit.end, inInclusiveRange(word.textStart, word.textEnd));
    expect(structure.canonicalText.substring(hit.start, hit.end), 'COLLECTION');
    final line = structure.lookup!.lineAt(hit.start);
    expect(line, isNotNull);
    expect(line!.kind, SpatialZoneKind.line);

    // The anchor captured from the index hit resolves as verified
    // identity reuse against a fresh parse of the same bytes.
    final anchor = DurableAnnotations.capture(
      snapshot: structure.snapshot(identity: identity),
      start: hit.start,
      end: hit.end,
    );
    final reopened = parseDjvuBook(goody).pageStructureAt(hit.sectionIndex)!;
    final resolution = DurableAnnotations.resolve(
      anchor: anchor,
      targets: <CanonicalTextSnapshot>[reopened.snapshot(identity: identity)],
    );
    expect(resolution, isA<AnchorResolved>());
    final resolved = resolution as AnchorResolved;
    expect(resolved.verified, isTrue);
    expect(resolved.range.start, hit.start);
    expect(resolved.range.end, hit.end);
    expect(
      reopened.canonicalText.substring(resolved.range.start, resolved.range.end),
      'COLLECTION',
    );
  });

  test('the index binds to the hidden-text profile, not the HTML view', () async {
    final book = parseDjvuBook(goody);
    final index = await BookSearchIndex.build(book);
    // The same word the HTML view renders inside its hidden span is
    // indexed in the hidden-text space; its hit range must NOT be
    // interpreted against documentText offsets — the profile differs by
    // construction, and the zone lookup fails for foreign offsets.
    final results = index.query('COLLECTION', mode: IndexedQueryMode.exact);
    final hit = results.hits.first;
    final htmlText = hit.sectionIndex < book.files.html.length
        ? book.files.html[hit.sectionIndex]
        : null;
    expect(htmlText, isNotNull);
    final documentText = htmlText!.plainText;
    final structure = book.pageStructureAt(hit.sectionIndex)!;
    expect(structure.canonicalText.length, isNot(documentText.length));
    // The hit resolves only in its own profile's text space.
    expect(structure.canonicalText.substring(hit.start, hit.end), 'COLLECTION');
  });
}
