part of '../parse_fb2_book.dart';

/// Decoded binary resources and resolved cover of an FB2 document.
final class _Fb2Resources {
  const _Fb2Resources._(this.binaries, this.coverId, this.cover);

  /// Decodes all valid `<binary>` elements under [root].
  factory _Fb2Resources.fromRoot(final XmlElement root) {
    final binaries = <String, BinaryFile>{};
    for (final element in root.findElements('binary')) {
      final id = element.getAttribute('id');
      if (id == null || id.isEmpty) continue;

      final binary = _decodeFb2Binary(
        id,
        element.getAttribute('content-type') ?? 'image/jpeg',
        element.innerText,
      );
      if (binary != null) binaries[id] = binary;
    }

    return _Fb2Resources.fromBinaries(root, binaries);
  }

  /// Resolves resource semantics for an already decoded binary subset.
  factory _Fb2Resources.fromBinaries(
    final XmlElement root,
    final Map<String, BinaryFile> binaries,
  ) {
    final coverId = _fb2CoverId(root);

    return _Fb2Resources._(
      binaries,
      coverId,
      coverId == null ? BinaryFile.empty() : binaries[coverId] ?? BinaryFile.empty(),
    );
  }

  /// Decoded binaries keyed by their FB2 id.
  final Map<String, BinaryFile> binaries;

  /// Binary id referenced by the book cover page.
  final String? coverId;

  /// Resolved cover binary, or an empty file when it is absent or invalid.
  final BinaryFile cover;

  /// Decoded images in document order.
  List<BinaryFile> get images => binaries.values.toList();

  /// Maps FB2 binary ids to the generated resource file names.
  Map<String, String> get extensionMap {
    return <String, String>{for (final entry in binaries.entries) entry.key: entry.value.name};
  }

  /// Cover metadata derived from the resolved cover image.
  BookCover? get metadataCover {
    if (cover.isEmpty) return null;

    final type = sniffImageType(cover.content);
    if (type == null) return null;

    final size = imageSize(cover.content);

    return BookCover(bytes: cover.content, type: type, width: size?.width, height: size?.height);
  }
}

/// Decodes one base64 FB2 binary, returning `null` for malformed data.
BinaryFile? _decodeFb2Binary(final String id, final String contentType, final String base64Text) {
  final Uint8List data;
  try {
    data = Uint8List.fromList(convert.base64.decode(base64Text.replaceAll(_whitespacePattern, '')));
  } on FormatException {
    return null;
  }
  final sniffed = sniffImageType(data);
  final extension = sniffed?.fileExtension ?? _extensionFromMime(contentType);
  final fileName = id.contains('.') ? id : '$id.$extension';

  return BinaryFile(content: data, name: fileName, type: extension, path: fileName);
}

/// Resolves the binary id referenced by the first FB2 cover page.
String? _fb2CoverId(final XmlElement root) {
  for (final titleInfo in root.findAllElements('title-info')) {
    for (final coverpage in titleInfo.findElements('coverpage')) {
      for (final image in coverpage.findElements('image')) {
        final href = _xlinkHref(image) ?? '';
        if (href.startsWith('#') && href.length > 1) return href.substring(1);
      }
    }
  }

  return null;
}

/// Reads the reference of a coverpage `<image>` element.
///
/// Per the FB2 specification the reference is an xlink reference: the
/// namespace URI is fixed while the prefix is arbitrary (`xlink:href`,
/// `l:href`, ...). Prefer the resolved xlink namespace; when the
/// binding is unavailable — the `<description>` metadata slice does
/// not inherit the root-level prefix declarations — fall back to the
/// `href` local name in any namespace.
String? _xlinkHref(final XmlElement element) {
  return element.getAttribute('href', namespace: _xlinkNamespace) ??
      element.getAttribute('href', namespace: '*') ??
      element.getAttribute('href');
}

String _extensionFromMime(final String mime) {
  switch (mime) {
    case 'image/png':
      return 'png';
    case 'image/gif':
      return 'gif';
    case 'image/bmp':
      return 'bmp';
    case 'image/webp':
      return 'webp';
    default:
      return 'jpg';
  }
}

/// Namespace of the FB2 coverpage reference: fixed URI, arbitrary prefix.
const _xlinkNamespace = 'http://www.w3.org/1999/xlink';

final RegExp _whitespacePattern = RegExp(r'\s');
