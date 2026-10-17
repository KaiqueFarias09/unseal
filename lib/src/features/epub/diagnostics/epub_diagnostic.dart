/// Severity of an EPUB structural diagnostic.
enum EpubDiagnosticSeverity {
  /// The condition breaks a structural requirement inside the diagnostic
  /// subset. EPUBCheck reports the mapped conditions as ERROR or FATAL.
  error,

  /// The condition is suspicious but does not break the structural subset.
  warning,
}

/// One structural EPUB finding with a stable rule identity.
final class EpubDiagnostic {
  /// Creates a finding. [ruleId] values come from the catalog documented in
  /// `doc/epub-diagnostics.md` and never change meaning between releases.
  const EpubDiagnostic({
    required this.ruleId,
    required this.severity,
    required this.reason,
    this.resource,
    this.location,
  });

  /// Stable rule identifier, such as `epub.manifest.resource-missing`.
  final String ruleId;

  /// Severity of the condition.
  final EpubDiagnosticSeverity severity;

  /// Archive-relative path of the affected resource, when known.
  final String? resource;

  /// Rule-specific pointer to the affected construct, when known, such as
  /// `manifest item "ghost"` or `spine[2]`.
  final String? location;

  /// Deterministic human-readable explanation of the condition.
  final String reason;

  @override
  String toString() =>
      'EpubDiagnostic($ruleId, ${severity.name}, resource: $resource, '
      'location: $location): $reason';
}

/// Bounds applied while collecting diagnostics. They are report bounds, not
/// safety boundaries: crossing one sets `EpubDiagnosticsReport.truncated`
/// and keeps the collected findings. Container-level safety limits stay
/// typed failures exactly as in reading.
final class EpubDiagnosticsOptions {
  /// Creates options with the documented defaults.
  const EpubDiagnosticsOptions({
    this.maxFindings = 400,
    this.maxNavigationLinks = 2000,
    this.maxFragmentResourceBytes = 1 << 20,
    this.maxManifestItems = 20000,
  });

  /// Stop collecting findings after this many and set `truncated`.
  final int maxFindings;

  /// Stop resolving navigation and guide links after this many and set
  /// `truncated`.
  final int maxNavigationLinks;

  /// Skip fragment checks against target documents larger than this many
  /// bytes and set `truncated`.
  final int maxFragmentResourceBytes;

  /// Manifest items beyond this count are not diagnosed individually.
  final int maxManifestItems;
}

/// Deterministic structural report for one EPUB container.
final class EpubDiagnosticsReport {
  /// Creates a report from already ordered findings.
  const EpubDiagnosticsReport({
    required this.findings,
    this.rootFilePath,
    this.packageVersion,
    this.truncated = false,
  });

  /// Package document path selected the same way the reading path selects
  /// it (container rootfile, then `.opf` recovery scan), or `null` when no
  /// usable package was found.
  final String? rootFilePath;

  /// Declared `package/@version` value, when the package document was
  /// well-formed enough to expose it.
  final String? packageVersion;

  /// Findings in the deterministic report order: container, package,
  /// manifest, spine, navigation, guide.
  final List<EpubDiagnostic> findings;

  /// Whether any report bound in [EpubDiagnosticsOptions] stopped collection
  /// early.
  final bool truncated;

  /// Number of `error` findings.
  int get errorCount => findings.where((f) => f.severity == EpubDiagnosticSeverity.error).length;

  /// Number of `warning` findings.
  int get warningCount =>
      findings.where((f) => f.severity == EpubDiagnosticSeverity.warning).length;

  @override
  String toString() =>
      'EpubDiagnosticsReport(root: $rootFilePath, version: $packageVersion, '
      'errors: $errorCount, warnings: $warningCount, truncated: $truncated)';
}
