import 'dart:typed_data';

import '../../../foundation/entities/entities.dart';
import '../session_engine.dart';
import '../session_policy.dart';
import 'session_transport.dart';

/// Opens a session on the web.
///
/// The worker-backed transport arrives with the session worker ops; the
/// inline engine keeps the client contract identical in the meantime.
Future<(SessionTransport, Book)> openSessionTransport({
  required final Uint8List? bytes,
  required final String? path,
  required final SessionPolicy policy,
}) async {
  final engine = SessionEngine.openBytes(bytes!, policy: policy);

  return (InlineSessionTransport(engine), engine.book);
}
