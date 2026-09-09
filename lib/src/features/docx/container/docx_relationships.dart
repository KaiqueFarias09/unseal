import 'package:e_livre/src/features/docx/container/docx_package.dart';
import 'package:xml/xml.dart';

/// A relationship from the main WordprocessingML document part.
final class DocxRelationship {
  /// Creates a resolved DOCX relationship.
  const DocxRelationship({required this.target, required this.external});

  /// The external URI or normalized internal package path.
  final String target;

  /// Whether [target] points outside the package.
  final bool external;
}

/// Reads relationships and resolves internal targets to package paths.
Map<String, DocxRelationship> readDocxRelationships(
  final XmlDocument? document,
  final String documentPath,
) {
  if (document == null) return const <String, DocxRelationship>{};

  final result = <String, DocxRelationship>{};
  for (final element in document.rootElement.children.whereType<XmlElement>()) {
    if (element.name.local != 'Relationship') continue;
    final id = docxAttribute(element, 'Id');
    final target = docxAttribute(element, 'Target');
    if (id == null || target == null || id.isEmpty || target.isEmpty) continue;
    final external = (docxAttribute(element, 'TargetMode') ?? '').toLowerCase() == 'external';
    result[id] = DocxRelationship(
      target: external ? target : resolveDocxRelationshipTarget(documentPath, target),
      external: external,
    );
  }

  return result;
}
