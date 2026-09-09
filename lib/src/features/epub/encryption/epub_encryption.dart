import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:e_livre/src/features/epub/codec/epub_xml.dart';
import 'package:e_livre/src/features/epub/entities/entities.dart';
import 'package:e_livre/src/features/epub/exceptions/exceptions.dart';
import 'package:e_livre/src/foundation/utils/archive_utils.dart';
import 'package:pointycastle/export.dart';
import 'package:xml/xml.dart';

/// Path to the EPUB encryption description.
const _encryptionFilepath = 'META-INF/encryption.xml';

/// The two EPUB font obfuscation algorithms defined by IDPF and Adobe.
abstract final class EpubFontObfuscationAlgorithm {
  /// IDPF's 1040-byte font obfuscation algorithm.
  static const idpf = 'http://www.idpf.org/2008/embedding';

  /// Adobe's 1024-byte font obfuscation algorithm.
  static const adobe = 'http://ns.adobe.com/pdf/enc#RC';
}

/// Resolves supported font obfuscation entries from `META-INF/encryption.xml`.
///
/// Unknown encryption algorithms are rejected as DRM. Known IDPF and Adobe
/// font obfuscation entries are decoded only when the package identifier
/// provides the key required by that algorithm.
final class EpubEncryption {
  EpubEncryption._(this._obfuscations);

  /// Builds an encryption map from an EPUB archive and its parsed package.
  ///
  /// Unknown algorithms are rejected as DRM instead of returning encrypted
  /// resources as if they were ordinary book content.
  factory EpubEncryption.fromArchive(final Archive archive, final EpubPackage package) {
    final encryptionFile = findArchiveFile(archive, _encryptionFilepath);
    if (encryptionFile == null) return EpubEncryption._(<String, _FontObfuscation>{});

    final document = parseEpubXml(encryptionFile.content as List<int>);
    final encryptedData = document.descendants.whereType<XmlElement>().where(
      (final element) => element.name.local == 'EncryptedData',
    );
    if (encryptedData.isEmpty) {
      throw EpubException('EPUB encryption error: no encrypted data entries found.');
    }

    final obfuscations = <String, _FontObfuscation>{};
    for (final encrypted in encryptedData) {
      final method = encrypted.descendants.whereType<XmlElement>().firstWhereOrNull(
        (final element) => element.name.local == 'EncryptionMethod',
      );
      final algorithm = method?.getAttribute('Algorithm')?.trim();
      if (algorithm != EpubFontObfuscationAlgorithm.idpf &&
          algorithm != EpubFontObfuscationAlgorithm.adobe) {
        throw EpubException('EPUB encryption is not supported; the book may be DRM-protected.');
      }

      final reference = encrypted.descendants.whereType<XmlElement>().firstWhereOrNull(
        (final element) => element.name.local == 'CipherReference',
      );
      final uri = reference?.getAttribute('URI');
      if (uri == null || uri.trim().isEmpty) {
        throw EpubException('EPUB encryption error: encrypted resource URI is missing.');
      }

      final path = _resourcePath(uri);
      if (findArchiveFile(archive, path) == null) {
        throw EpubException('EPUB encryption error: encrypted resource $path not found.');
      }

      final key = algorithm == EpubFontObfuscationAlgorithm.idpf
          ? _idpfKey(package)
          : _adobeKey(package);
      obfuscations[path.toLowerCase()] = _FontObfuscation(
        key: key,
        length: algorithm == EpubFontObfuscationAlgorithm.adobe ? 1024 : 1040,
      );
    }

    return EpubEncryption._(obfuscations);
  }

  final Map<String, _FontObfuscation> _obfuscations;

  /// Returns decoded bytes for [entry] when it is a declared obfuscated font.
  Uint8List decodeFont(final ArchiveFile entry) {
    final obfuscation = _obfuscations[normalizeZipPath(entry.name).toLowerCase()];
    if (obfuscation == null) return contentBytes(entry);

    return obfuscation.decode(contentBytes(entry));
  }
}

Uint8List _idpfKey(final EpubPackage package) {
  final identifier = package.metadata.uniqueIdentifierValue.replaceAll(RegExp(r'[ \t\r\n]'), '');
  if (identifier.isEmpty) {
    throw EpubException('EPUB encryption error: package identifier is missing.');
  }

  return SHA1Digest().process(Uint8List.fromList(convert.utf8.encode(identifier)));
}

Uint8List _adobeKey(final EpubPackage package) {
  for (final identifier in <String>[
    package.metadata.uniqueIdentifierValue,
    ...package.metadata.identifiers,
  ]) {
    final uuid = _uuidBytes(identifier);
    if (uuid != null) return uuid;
  }

  throw EpubException('EPUB encryption error: Adobe font UUID is missing.');
}

Uint8List? _uuidBytes(final String value) {
  final normalized = value.trim();
  final candidate = normalized.toLowerCase().startsWith('urn:uuid:')
      ? normalized.substring('urn:uuid:'.length)
      : normalized;
  final hex = candidate.replaceAll('-', '').replaceAll('{', '').replaceAll('}', '');
  if (hex.length != 32 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(hex)) return null;

  return Uint8List.fromList([
    for (var index = 0; index < hex.length; index += 2)
      int.parse(hex.substring(index, index + 2), radix: 16),
  ]);
}

String _resourcePath(final String uri) {
  final withoutFragment = uri.split('#').first.trim();
  try {
    return normalizeZipPath(Uri.decodeComponent(withoutFragment));
  } on FormatException {
    throw EpubException('EPUB encryption error: invalid encrypted resource URI.');
  }
}

final class _FontObfuscation {
  const _FontObfuscation({required this.key, required this.length});

  final Uint8List key;
  final int length;

  Uint8List decode(final Uint8List data) {
    if (key.isEmpty) return data;

    final decoded = Uint8List.fromList(data);
    final limit = decoded.length < length ? decoded.length : length;
    for (var index = 0; index < limit; index++) {
      decoded[index] ^= key[index % key.length];
    }

    return decoded;
  }
}

extension on Iterable<XmlElement> {
  XmlElement? firstWhereOrNull(final bool Function(XmlElement element) test) {
    for (final element in this) {
      if (test(element)) return element;
    }

    return null;
  }
}
