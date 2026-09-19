import 'package:collection/collection.dart';
import 'package:xml/xml.dart';

/// The Atom namespace OPDS feeds are built on.
const _atomNamespace = 'http://www.w3.org/2005/Atom';

/// Acquisition (download) link relation of the OPDS 1.0 spec.
const opdsAcquisitionRel = 'http://opds-spec.org/acquisition';

/// Cover image link relation of the OPDS 1.0 spec.
const opdsCoverRel = 'http://opds-spec.org/cover';

/// Thumbnail link relation of the OPDS 1.0 spec.
const opdsThumbnailRel = 'http://opds-spec.org/thumbnail';

/// An author of a feed or entry.
final class OpdsAuthor {
  /// Creates an [OpdsAuthor].
  const OpdsAuthor({required this.name, this.uri});

  /// The author name.
  final String name;

  /// An optional external link about the author.
  final String? uri;

  @override
  String toString() => 'OpdsAuthor($name)';
}

/// A link of a feed or entry.
final class OpdsLink {
  /// Creates an [OpdsLink].
  const OpdsLink({required this.href, this.rel, this.type, this.title});

  /// The target URI (relative to the feed URL when relative).
  final String href;

  /// The link relation (`self`, `next`, `http://opds-spec.org/acquisition`, ...).
  final String? rel;

  /// The MIME type of the target (`application/epub+zip`, ...).
  final String? type;

  /// An optional display title.
  final String? title;

  @override
  String toString() => 'OpdsLink($rel -> $href)';
}

/// One `<entry>` of an OPDS feed: either a catalog navigation point or an acquisition-ready
/// publication.
final class OpdsEntry {
  /// Creates an [OpdsEntry].
  const OpdsEntry({
    required this.id,
    required this.title,
    this.summary,
    this.content,
    this.updated,
    this.authors = const <OpdsAuthor>[],
    this.links = const <OpdsLink>[],
  });

  /// The unique identifier of the entry.
  final String id;

  /// The entry title.
  final String title;

  /// A short summary, when present.
  final String? summary;

  /// The longer text content, when present.
  final String? content;

  /// The last update timestamp of the entry.
  final DateTime? updated;

  /// The entry authors.
  final List<OpdsAuthor> authors;

  /// All links of the entry.
  final List<OpdsLink> links;

  /// Links that download the book file (EPUB, MOBI, PDF...).
  List<OpdsLink> get acquisitionLinks {
    return links.where((final link) => link.rel == opdsAcquisitionRel).toList();
  }

  /// The full cover image link, when present.
  OpdsLink? get coverLink => links.firstWhereOrNull((final link) => link.rel == opdsCoverRel);

  /// The thumbnail link, when present.
  OpdsLink? get thumbnailLink {
    return links.firstWhereOrNull((final link) => link.rel == opdsThumbnailRel);
  }

  @override
  String toString() => 'OpdsEntry($title)';
}

/// A parsed OPDS feed: a catalog navigation page or an acquisition page of publications.
///
/// Parsing only — fetching the feed over HTTP is left to the caller, keeping this module
/// dependency-free.
final class OpdsFeed {
  /// Creates an [OpdsFeed].
  const OpdsFeed({
    required this.id,
    required this.title,
    this.updated,
    this.links = const <OpdsLink>[],
    this.entries = const <OpdsEntry>[],
  });

  /// The unique identifier of the feed.
  final String id;

  /// The feed title.
  final String title;

  /// The last update timestamp of the feed.
  final DateTime? updated;

  /// Feed-level links (`self`, `next`, `search`, `up`, ...).
  final List<OpdsLink> links;

  /// The entries of the feed.
  final List<OpdsEntry> entries;

  /// Whether any entry carries acquisition links (an acquisition feed lists downloadable books; a
  /// navigation feed lists catalogs).
  bool get isAcquisition => entries.any((final entry) => entry.acquisitionLinks.isNotEmpty);

  /// The `next` page link, when the feed is paginated.
  OpdsLink? get nextLink => links.firstWhereOrNull((final link) => link.rel == 'next');

  /// The `search` link template, when the catalog advertises one.
  OpdsLink? get searchLink => links.firstWhereOrNull((final link) => link.rel == 'search');

  /// Parses an OPDS (Atom) feed from its XML.
  ///
  /// Throws [FormatException] when the XML cannot be parsed or lacks a feed root element.
  static OpdsFeed parse(final String xml) {
    final document = XmlDocument.parse(xml);
    final feed =
        document.findElements('feed', namespaceUri: _atomNamespace).firstOrNull ??
        document.findElements('feed').firstOrNull;
    if (feed == null) throw const FormatException('OPDS parsing error: no feed element found.');

    final entries = feed
        .findElements('entry', namespaceUri: _atomNamespace)
        .map(_parseEntry)
        .toList();

    return OpdsFeed(
      id: _text(feed, 'id'),
      title: _text(feed, 'title'),
      updated: DateTime.tryParse(_text(feed, 'updated')),
      links: feed.findElements('link', namespaceUri: _atomNamespace).map(_parseLink).toList(),
      entries: entries,
    );
  }

  static OpdsEntry _parseEntry(final XmlElement element) {
    return OpdsEntry(
      id: _text(element, 'id'),
      title: _text(element, 'title'),
      summary: _optionalText(element, 'summary'),
      content: _optionalText(element, 'content'),
      updated: DateTime.tryParse(_text(element, 'updated')),
      authors: element.findElements('author', namespaceUri: _atomNamespace).map((final author) {
        return OpdsAuthor(name: _text(author, 'name'), uri: _optionalText(author, 'uri'));
      }).toList(),
      links: element.findElements('link', namespaceUri: _atomNamespace).map(_parseLink).toList(),
    );
  }

  static OpdsLink _parseLink(final XmlElement element) {
    return OpdsLink(
      href: element.getAttribute('href') ?? '',
      rel: element.getAttribute('rel'),
      type: element.getAttribute('type'),
      title: element.getAttribute('title'),
    );
  }

  static String _text(final XmlElement parent, final String name) {
    return _optionalText(parent, name) ?? '';
  }

  static String? _optionalText(final XmlElement parent, final String name) {
    final element = parent.findElements(name, namespaceUri: _atomNamespace).firstOrNull;

    return element?.innerText.trim();
  }
}
