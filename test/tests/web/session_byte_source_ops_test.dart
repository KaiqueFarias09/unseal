import 'dart:async';
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:unseal/src/platform/web/book_wire.dart';
import 'package:unseal/src/platform/web/byte_source_bridge.dart';
import 'package:unseal/src/platform/web/worker_ops.dart';
import 'package:unseal/unseal.dart';

Uint8List _utf8(final String value) => Uint8List.fromList(convert.utf8.encode(value));

/// A minimal EPUB with two chapters, built with the archive package
/// directly — the container the byte bridge reads through.
Uint8List _epub(final String title) {
  final archive = Archive();
  archive.addFile(
    ArchiveFile('mimetype', 20, _utf8('application/epub+zip'))..compression = CompressionType.none,
  );
  final container = _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''');
  archive.addFile(ArchiveFile('META-INF/container.xml', container.length, container));
  final package = _utf8('''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    version="3.0" unique-identifier="uid">
  <metadata><dc:identifier id="uid">urn:uuid:$title</dc:identifier><dc:title>$title</dc:title><dc:language>en</dc:language></metadata>
  <manifest>
    <item id="chapter1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="chapter2" href="chapter2.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="chapter1"/><itemref idref="chapter2"/></spine>
</package>''');
  archive.addFile(ArchiveFile('content.opf', package.length, package));
  archive.addFile(
    ArchiveFile(
      'chapter1.xhtml',
      _utf8(
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>alpha content</p></body></html>',
      ).length,
      _utf8('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>alpha content</p></body></html>'),
    ),
  );
  archive.addFile(
    ArchiveFile(
      'chapter2.xhtml',
      _utf8(
        '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>bravo content</p></body></html>',
      ).length,
      _utf8('<html xmlns="http://www.w3.org/1999/xhtml"><body><p>bravo content</p></body></html>'),
    ),
  );

  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// A pure-Dart stand-in for the main thread's gate: the bridge posts
/// requests here, and each one is answered with the exact slice — the
/// same contract the real shell exercises, without browser types.
(WorkerByteBridge, List<({int offset, int count})>) _bridgeOver(
  final Uint8List bytes, {
  final String? revision,
}) {
  final served = <({int offset, int count})>[];
  WorkerByteBridge? sink;
  final bridge = WorkerByteBridge(
    sessionId: 7,
    length: bytes.length,
    revision: revision,
    post: (final message) {
      expect(message['kind'], wireKindByteSourceRequest);
      final requestId = message[wireKeyRequestId]! as int;
      final offset = message['offset']! as int;
      final count = message['count']! as int;
      served.add((offset: offset, count: count));
      scheduleMicrotask(() {
        sink!.handleReply(<String, Object?>{
          'kind': wireKindByteSourceReply,
          wireKeyRequestId: requestId,
          wireKeyBytes: Uint8List.sublistView(bytes, offset, offset + count),
        });
      });
    },
  );
  sink = bridge;

  return (bridge, served);
}

Map<String, Object?> _sourceOpenPayload(final int sessionId) => <String, Object?>{
  wireKeySessionId: sessionId,
  wireKeyByteSource: true,
  wireKeySourceLength: 0, // filled by the caller against its bridge
  ...const SessionPolicy().toWireForTest(),
};

extension on SessionPolicy {
  Map<String, Object?> toWireForTest() => <String, Object?>{
    wireKeyCacheBytes: cacheBytes,
    wireKeyCoverMaxBytes: coverMaxBytes,
    wireKeyRangeMaxBytes: rangeMaxBytes,
    wireKeyRangeRequestsInFlight: rangeRequestsInFlight,
    wireKeyRangeBytesInFlight: rangeBytesInFlight,
    wireKeyRangeRequestBytes: rangeRequestBytes,
  };
}

void main() {
  final bytes = _epub('Bridge book');

  group('sessionOpen over a byte bridge', () {
    test('opens the engine through the bridge and serves content', () async {
      final (bridge, served) = _bridgeOver(bytes, revision: 'etag-7');
      final payload = _sourceOpenPayload(1)..[wireKeySourceLength] = bytes.length;
      final reply = await runWorkerOp(
        op: workerOpSessionOpen,
        payload: payload,
        byteBridge: bridge,
      );

      expect(reply.kind, wireReplySessionOpen);
      final header = reply.session!;
      expect(header.book, isA<EpubBook>());
      expect(served, isNotEmpty, reason: 'the open pulled ranges through the bridge');

      final chapter = await header.resource('chapter1.xhtml');
      expect(convert.utf8.decode(chapter!), contains('alpha content'));
      expect(served, isNotEmpty, reason: 'the content load also rode the bridge');

      header.close();
    });

    test('source sessions fail typed when the bridge answer fails', () async {
      WorkerByteBridge? failing;
      failing = WorkerByteBridge(
        sessionId: 8,
        length: bytes.length,
        revision: null,
        post: (final message) {
          final requestId = message[wireKeyRequestId]! as int;
          scheduleMicrotask(() {
            failing!.handleReply(<String, Object?>{
              'kind': wireKindByteSourceError,
              wireKeyRequestId: requestId,
              wireKeyType: 'ByteSourceReadException',
              wireKeyMessage: 'host transport failure',
            });
          });
        },
      );
      final payload = _sourceOpenPayload(2)..[wireKeySourceLength] = bytes.length;

      await expectLater(
        runWorkerOp(op: workerOpSessionOpen, payload: payload, byteBridge: failing),
        throwsA(isA<UnsealException>()),
      );
    });

    test('late bridge replies to dead requests serve nobody', () async {
      final (bridge, _) = _bridgeOver(bytes);
      // A reply with an id nothing waits on must not throw.
      bridge.handleReply(<String, Object?>{
        'kind': wireKindByteSourceReply,
        wireKeyRequestId: 9999,
        wireKeyBytes: bytes,
      });
      bridge.close();
    });
  });
}
