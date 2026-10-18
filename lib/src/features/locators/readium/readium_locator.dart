/// The Readium Locator model (`readium.org/architecture/models/locators/`)
/// and its interchange semantics, fixed against the executed
/// `@readium/shared` 2.8.0 toolkit; see `doc/readium-locators.md`.
///
/// The model mirrors the toolkit's observed behavior over the pinned
/// corpus: required `href`+`type`, tolerant `#fragment` splitting and the
/// legacy singular `fragment` spelling on import, out-of-range
/// progression/position values dropped on import, unregistered
/// `locations` keys preserved as opaque extensions, and serialization
/// always carrying `locations` (empty `fragments` included). It is
/// deliberately stricter on structure than the toolkit — non-string
/// `href`/`type`/fragment/text values reject instead of flowing through —
/// a documented divergence kept schema-normative.
library;

import 'readium_limits.dart';

/// One Readium Locator: a resource reference plus optional locations and
/// textual context.
final class ReadiumLocator {
  /// Creates a locator; [href] and [type] must be non-empty — the two
  /// fields the Readium model requires.
  ReadiumLocator({
    required this.href,
    required this.type,
    this.title,
    ReadiumLocations? locations,
    this.text,
  }) : assert(href.isNotEmpty),
       assert(type.isNotEmpty),
       locations = locations ?? ReadiumLocations.empty;

  /// The URI of the resource this locator points to — never a fragment.
  final String href;

  /// The media type of the resource this locator points to.
  final String type;

  /// The title of the chapter or section most relevant in context.
  final String? title;

  /// Alternative expressions of the location; never null.
  final ReadiumLocations locations;

  /// Textual context of the locator, when the resource is a document.
  final ReadiumTextContext? text;

  /// Serializes to the Readium JSON shape: `href`, `type`, optional
  /// `title`, always `locations`, and `text` only when it carries fields.
  Map<String, Object?> serialize() {
    return <String, Object?>{
      'href': href,
      'type': type,
      if (title != null) 'title': title,
      'locations': locations.serialize(),
      if (text != null) 'text': text!.serialize(),
    };
  }

  @override
  String toString() => 'ReadiumLocator($href, $type, ${locations.serialize()})';
}

/// The `locations` object: fragments, progressions, position index, and
/// opaque extensions.
final class ReadiumLocations {
  /// Creates a locations object; [progression] and [totalProgression]
  /// must lie in `[0, 1]` and [position] must be `>= 1` — values outside
  /// the contract cannot be constructed.
  ReadiumLocations({
    this.fragments = const <String>[],
    this.progression,
    this.totalProgression,
    this.position,
    this.extensions = const <String, Object?>{},
  }) : assert(progression == null || (progression >= 0 && progression <= 1)),
       assert(totalProgression == null || (totalProgression >= 0 && totalProgression <= 1)),
       assert(position == null || position >= 1);

  /// The canonical empty locations object every locator carries at least.
  static final ReadiumLocations empty = ReadiumLocations();

  /// Fragments of the resource this locator addresses (HTML ids, media
  /// fragments, `page=N`, partial CFIs, …). Never null.
  final List<String> fragments;

  /// Progression in the resource, `0..1`.
  final double? progression;

  /// Progression in the publication, `0..1`.
  final double? totalProgression;

  /// One-based index in the publication.
  final int? position;

  /// Unregistered extension locations, preserved opaquely and bounded by
  /// [ReadiumLocatorLimits]; they gain no local meaning.
  final Map<String, Object?> extensions;

  /// Serializes to the toolkit's observed shape: `fragments` always
  /// present (empty included), then progression, totalProgression,
  /// position, then extensions re-emitted top-level inside the object.
  Map<String, Object?> serialize() {
    return <String, Object?>{
      'fragments': List<String>.of(fragments),
      if (progression != null) 'progression': progression,
      if (totalProgression != null) 'totalProgression': totalProgression,
      if (position != null) 'position': position,
      for (final entry in extensions.entries) entry.key: entry.value,
    };
  }

  @override
  String toString() => 'ReadiumLocations(${serialize()})';
}

/// The `text` object: the quoted context around the located range.
final class ReadiumTextContext {
  /// Creates a text context from its optional fields.
  const ReadiumTextContext({this.before, this.highlight, this.after});

  /// The text immediately before the locator.
  final String? before;

  /// The text at the locator.
  final String? highlight;

  /// The text immediately after the locator.
  final String? after;

  /// Whether no field carries text. A decoded empty context is still
  /// preserved for interchange parity (`"text": {}`); builders should
  /// pass null instead of an empty context.
  bool get isEmpty =>
      (before == null || before!.isEmpty) &&
      (highlight == null || highlight!.isEmpty) &&
      (after == null || after!.isEmpty);

  /// Serializes the toolkit's field order; absent fields stay absent.
  Map<String, Object?> serialize() {
    return <String, Object?>{
      if (after != null) 'after': after,
      if (before != null) 'before': before,
      if (highlight != null) 'highlight': highlight,
    };
  }

  @override
  String toString() => 'ReadiumTextContext(${serialize()})';
}

/// Decodes a Readium Locator from an already-parsed JSON [json] map,
/// returning null when the payload is structurally invalid — missing or
/// empty `href`/`type`, wrong value types, or an extension payload above
/// the [limits]. Mirrors the toolkit's `undefined` refusal for
/// forward-compatibility: a broken payload never throws here.
///
/// Semantic tolerance follows the toolkit: an `href` carrying a
/// `#fragment` splits into resource href plus fragment, the legacy
/// singular `fragment` folds into `fragments`, and progression or
/// position values outside their contract are dropped while the locator
/// stays.
ReadiumLocator? tryDecodeReadiumLocator(
  final Map<Object?, Object?> json, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
}) {
  try {
    return _decodeLocator(json, limits);
  } on ReadiumStructuralRejection {
    return null;
  }
}

/// Decodes a Readium Locator from an already-parsed JSON map under the
/// strict contract: structural malformations and bound breaches surface
/// as [ReadiumStructuralRejection] for the string codec to classify.
/// Feature internal; hosts use [tryDecodeReadiumLocator] or the codec.
ReadiumLocator decodeReadiumLocatorStrict(
  final Map<Object?, Object?> json, {
  final ReadiumLocatorLimits limits = const ReadiumLocatorLimits(),
}) {
  final locator = _decodeLocator(json, limits);
  if (locator == null) {
    throw const ReadiumStructuralRejection(false);
  }

  return locator;
}

ReadiumLocator? _decodeLocator(
  final Map<Object?, Object?> json,
  final ReadiumLocatorLimits limits,
) {
  final rawHref = json['href'];
  final type = json['type'];
  if (rawHref is! String || rawHref.isEmpty || type is! String || type.isEmpty) return null;

  // Toolkit parity: an href carrying a fragment splits — the resource
  // part stays the href and the fragment moves into `locations.fragments`
  // when no fragments are present. Normatively hrefs never carry one
  // (doc/readium-locators.md); imports stay tolerant, exports never
  // produce this shape.
  var href = rawHref;
  String? hrefFragment;
  final hash = rawHref.indexOf('#');
  if (hash >= 0) {
    href = rawHref.substring(0, hash);
    hrefFragment = rawHref.substring(hash + 1);
  }

  final titleValue = json['title'];
  if (titleValue != null && titleValue is! String) return null;

  final locationsValue = json['locations'];
  Map<Object?, Object?>? locationsJson;
  if (locationsValue != null) {
    if (locationsValue is! Map<Object?, Object?>) return null;
    locationsJson = locationsValue;
  }

  final textValue = json['text'];
  Map<Object?, Object?>? textJson;
  if (textValue != null) {
    if (textValue is! Map<Object?, Object?>) return null;
    textJson = textValue;
  }

  final locations = locationsJson == null
      ? ReadiumLocations.empty
      : _decodeLocations(locationsJson, limits);
  if (locations == null) return null;

  final text = textJson == null ? null : _decodeText(textJson, limits);
  if (textJson != null && text == null) return null;

  // The split applies only when the locations object carries no
  // fragments of its own; a non-empty fragments list wins and the href
  // fragment is dropped (toolkit parity).
  final splitLocations =
      hrefFragment != null && hrefFragment.isNotEmpty && locations.fragments.isEmpty
      ? ReadiumLocations(
          fragments: [hrefFragment],
          progression: locations.progression,
          totalProgression: locations.totalProgression,
          position: locations.position,
          extensions: locations.extensions,
        )
      : locations;

  // A present-but-empty text object stays: the toolkit serializes it as
  // `"text": {}`, and interchange parity wins over prettiness.
  return ReadiumLocator(
    href: href,
    type: type,
    title: titleValue as String?,
    locations: splitLocations,
    text: text,
  );
}

ReadiumLocations? _decodeLocations(
  final Map<Object?, Object?> json,
  final ReadiumLocatorLimits limits,
) {
  final fragments = <String>[];
  final fragmentsValue = json['fragments'];
  final legacyValue = json['fragment'];
  if (fragmentsValue != null) {
    if (fragmentsValue is! List<Object?>) return null;
    if (fragmentsValue.length > limits.maxFragments) {
      throw const ReadiumStructuralRejection(true);
    }
    for (final fragment in fragmentsValue) {
      if (fragment is! String) return null;
      if (fragment.length > limits.maxFragmentLength) {
        throw const ReadiumStructuralRejection(true);
      }
      fragments.add(fragment);
    }
  } else if (legacyValue != null) {
    // The legacy singular spelling the official position-list example
    // uses; the toolkit folds it in only when `fragments` is absent.
    if (legacyValue is! String) return null;
    if (legacyValue.length > limits.maxFragmentLength) {
      throw const ReadiumStructuralRejection(true);
    }
    fragments.add(legacyValue);
  }

  // Absent → null; structurally wrong type → rejection; outside `0..1` →
  // dropped (the toolkit's drop-and-keep semantics).
  double? decodeUnitInterval(final Object? value) {
    if (value == null) return null;
    if (value is! num || value.isNaN) throw const ReadiumStructuralRejection(false);

    return (value >= 0 && value <= 1) ? value.toDouble() : null;
  }

  final progression = decodeUnitInterval(json['progression']);
  final totalProgression = decodeUnitInterval(json['totalProgression']);

  final positionValue = json['position'];
  int? position;
  if (positionValue != null) {
    if (positionValue is! num || positionValue.isNaN) return null;
    // The schema normatively requires an integer; the toolkit accepts
    // any positive number and Unseal drops non-integers (a documented,
    // stricter divergence).
    if (positionValue > 0 && _isInteger(positionValue)) {
      position = positionValue.toInt();
    }
  }

  final knownKeys = const <String>{
    'fragments',
    'fragment',
    'progression',
    'totalProgression',
    'position',
  };
  final extensions = <String, Object?>{};
  for (final entry in json.entries) {
    final key = entry.key;
    if (key is! String || knownKeys.contains(key)) continue;
    if (extensions.length >= limits.maxExtensions) {
      throw const ReadiumStructuralRejection(true);
    }
    if (key.isEmpty || key.length > limits.maxExtensionKeyLength) {
      throw const ReadiumStructuralRejection(true);
    }
    final value = entry.value;
    if (!_isBoundedJsonValue(value, limits)) {
      throw const ReadiumStructuralRejection(true);
    }
    extensions[key] = value;
  }

  return ReadiumLocations(
    fragments: fragments,
    progression: progression,
    totalProgression: totalProgression,
    position: position,
    extensions: extensions,
  );
}

/// Signals a rejected payload: a structurally wrong value type, or a
/// bound breach the caller surfaces as a typed limit failure. Feature
/// internal: the map-level decode turns it into `null`, the strict string
/// codec turns it into the typed limit/format failures.
final class ReadiumStructuralRejection implements Exception {
  /// Creates the rejection.
  const ReadiumStructuralRejection(this.isLimit);

  /// Whether the rejection was a resource bound (true) or a value-type
  /// malformation (false).
  final bool isLimit;
}

bool _isInteger(final num value) => value.isFinite && value == value.truncate();

/// Whether [value] is a JSON-shaped value inside the extension bounds.
/// Extension payloads stay opaque: they are bounded, never interpreted.
bool _isBoundedJsonValue(final Object? value, final ReadiumLocatorLimits limits) {
  var budget = limits.maxExtensionValueBytes;

  bool walk(final Object? node, final int depth) {
    if (depth > limits.maxExtensionDepth) return false;
    if (node == null || node is bool) return true;
    if (node is num) return node.isFinite;
    if (node is String) {
      final overhead = node.length + 2;
      if (overhead > budget) return false;
      budget -= overhead;

      return true;
    }
    if (node is List<Object?>) return node.every((entry) => walk(entry, depth + 1));
    if (node is Map<Object?, Object?>) {
      return node.entries.every(
        (entry) =>
            entry.key is String &&
            (entry.key as String).length <= limits.maxExtensionKeyLength &&
            walk(entry.key, depth + 1) &&
            walk(entry.value, depth + 1),
      );
    }

    return false;
  }

  return walk(value, 0);
}

ReadiumTextContext? _decodeText(
  final Map<Object?, Object?> json,
  final ReadiumLocatorLimits limits,
) {
  String? field(final Object? value) {
    if (value == null) return null;
    if (value is! String) return null;
    if (value.length > limits.maxTextContextLength) {
      throw const ReadiumStructuralRejection(true);
    }

    return value;
  }

  final before = field(json['before']);
  final highlight = field(json['highlight']);
  final after = field(json['after']);
  if ((json['before'] != null && before == null) ||
      (json['highlight'] != null && highlight == null) ||
      (json['after'] != null && after == null)) {
    return null;
  }
  if (before == null && highlight == null && after == null) {
    return const ReadiumTextContext();
  }

  return ReadiumTextContext(before: before, highlight: highlight, after: after);
}
