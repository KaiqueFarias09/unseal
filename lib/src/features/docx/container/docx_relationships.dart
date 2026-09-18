part of '../parse_docx_book.dart';

/// A relationship from the main WordprocessingML document part.
final class _DocxRelationship {
  /// Creates a resolved DOCX relationship.
  const _DocxRelationship({required this.target, required this.isExternal});

  /// The external URI or normalized internal package path.
  final String target;

  /// Whether [target] points outside the package.
  final bool isExternal;
}

/// Reads relationships and resolves internal targets to package paths.
Map<String, _DocxRelationship> _readDocxRelationships(
  final XmlDocument? document,
  final String documentPath,
) {
  if (document == null) return const <String, _DocxRelationship>{};

  final result = <String, _DocxRelationship>{};
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'Relationship') continue;

    final id = _docxAttribute(element, 'Id');
    final target = _docxAttribute(element, 'Target');
    if (id == null || target == null || id.isEmpty || target.isEmpty) continue;

    final isExternal = (_docxAttribute(element, 'TargetMode') ?? '').toLowerCase() == 'external';
    result[id] = _DocxRelationship(
      target: isExternal ? target : _resolveDocxRelationshipTarget(documentPath, target),
      isExternal: isExternal,
    );
  }

  return result;
}
