import 'dart:convert' as convert;

import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

const String acquisitionFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
  <id>urn:uuid:catalog-main</id>
  <title>eLivre Library</title>
  <updated>2026-01-01T00:00:00Z</updated>
  <link rel="self" href="/catalog.xml" type="application/atom+xml"/>
  <link rel="next" href="/catalog-page2.xml" type="application/atom+xml"/>
  <link rel="search" href="/search.xml" type="application/atom+xml"/>
  <entry>
    <id>urn:uuid:book-1984</id>
    <title>1984</title>
    <updated>2026-01-02T12:00:00Z</updated>
    <summary>A dystopian novel.</summary>
    <author><name>George Orwell</name></author>
    <link rel="http://opds-spec.org/cover" href="/covers/1984.png" type="image/png"/>
    <link rel="http://opds-spec.org/acquisition" href="/download/1984.epub" type="application/epub+zip"/>
    <link rel="http://opds-spec.org/acquisition" href="/download/1984.mobi" type="application/x-mobipocket-ebook"/>
  </entry>
  <entry>
    <id>urn:uuid:book-cortico</id>
    <title>O Cortiço</title>
    <updated>2026-01-03T12:00:00Z</updated>
    <content>Um clássico do naturalismo.</content>
    <link rel="http://opds-spec.org/thumbnail" href="/thumbs/cortico.png" type="image/png"/>
    <link rel="http://opds-spec.org/acquisition" href="/download/cortico.epub" type="application/epub+zip"/>
  </entry>
</feed>
''';

const String navigationFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <id>urn:uuid:catalog-root</id>
  <title>Root catalog</title>
  <entry>
    <id>urn:uuid:by-title</id>
    <title>By title</title>
    <link rel="subsection" href="/by-title.xml" type="application/atom+xml"/>
  </entry>
</feed>
''';

void main() {
  group('OpdsFeed.parse', () {
    final feed = OpdsFeed.parse(convert.utf8.decode(convert.utf8.encode(acquisitionFeed)));

    test('reads feed identity and links', () {
      expect(feed.id, 'urn:uuid:catalog-main');
      expect(feed.title, 'eLivre Library');
      expect(feed.updated, DateTime.parse('2026-01-01T00:00:00Z'));
      expect(feed.nextLink!.href, '/catalog-page2.xml');
      expect(feed.searchLink!.href, '/search.xml');
    });

    test('detects acquisition feeds', () {
      expect(feed.isAcquisition, isTrue);
    });

    test('parses entries with authors and acquisition links', () {
      final book1984 = feed.entries.first;
      expect(book1984.title, '1984');
      expect(book1984.authors.single.name, 'George Orwell');
      expect(book1984.summary, 'A dystopian novel.');
      expect(book1984.acquisitionLinks, hasLength(2));
      expect(book1984.acquisitionLinks.first.type, 'application/epub+zip');
      expect(book1984.coverLink!.href, '/covers/1984.png');
      expect(feed.entries.last.thumbnailLink!.href, '/thumbs/cortico.png');
    });

    test('navigation feeds without acquisitions are flagged', () {
      final feed = OpdsFeed.parse(navigationFeed);
      expect(feed.isAcquisition, isFalse);
      expect(feed.entries.single.links.single.rel, 'subsection');
    });

    test('rejects documents without a feed', () {
      expect(() => OpdsFeed.parse('<html><body/></html>'), throwsFormatException);
    });
  });
}
