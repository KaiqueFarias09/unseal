/// Sony BBeB/LRX DRM detection and plaintext metadata entry points.
library;

export 'src/features/lrf/parse_lrx_metadata.dart' show readLrxMetadata;
export 'src/foundation/entities/entities.dart';
export 'src/foundation/exceptions/unseal_exception.dart' show DrmProtectedException;
