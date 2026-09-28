/// Public interface for the structured-clone wire protocol shared by the web
/// worker and its client.
library;

export 'wire/book_wire_codec.dart' show decodeBookWire, encodeBookWire;
export 'wire/cfi_wire.dart' show decodeCfiLocationWire, encodeCfiLocationWire;
export 'wire/error_wire.dart' show decodeErrorWire;
export 'wire/json_wire.dart' show decodeJson, encodeJson;
export 'wire/metadata_wire.dart' show decodeMetadataWire, encodeMetadataWire;
export 'wire/mobi_wire.dart' show mobiWireRecord0;
export 'wire/search_wire.dart' show decodeSearchResultsWire, encodeSearchResultsWire;
export 'wire/session_header_wire.dart'
    show
        decodePdfPageLinesWire,
        decodeSessionHeaderWire,
        encodePdfPageLinesWire,
        encodeSessionHeaderWire;

/// Wire protocol op: parse a whole book.
const String workerOpParse = 'parse';

/// Wire protocol op: extract metadata only.
const String workerOpMetadata = 'metadata';

/// Wire protocol op: full-text search over the resident book.
const String workerOpSearch = 'search';

/// Wire protocol op: resolve a CFI against the resident book.
const String workerOpCfiResolve = 'cfiResolve';

/// Wire protocol op: build a CFI from a reading position in the
/// resident book.
const String workerOpCfiBuild = 'cfiBuild';

/// Wire protocol op: open a progressive session over the request
/// bytes under its request-scoped session identifier.
const String workerOpSessionOpen = 'sessionOpen';

/// Wire protocol op: inflate one container entry of the resident
/// session.
const String workerOpSessionResource = 'sessionResource';

/// Wire protocol op: inflate several container entries of the resident
/// session in one round trip.
const String workerOpSessionResources = 'sessionResources';

/// Wire protocol op: a raw slice of the resident session's container
/// source.
const String workerOpSessionRange = 'sessionRange';

/// Wire protocol op: raw decoded source (markup included) of one
/// content document of the resident session.
const String workerOpSessionSource = 'sessionSource';

/// Wire protocol op: one PDF page's text with line geometry from the
/// resident session.
const String workerOpSessionPdfLines = 'sessionPdfLines';

/// Wire protocol op: canonical document text of one content document
/// of the resident session.
const String workerOpSessionText = 'sessionText';

/// Wire protocol op: whole-book search inside the resident session.
const String workerOpSessionSearch = 'sessionSearch';

/// Wire protocol op: whole-book reading progression inside the
/// resident session.
const String workerOpSessionProgression = 'sessionProgression';

/// Wire protocol op: whole-book statistics inside the resident
/// session.
const String workerOpSessionStatistics = 'sessionStatistics';

/// Wire protocol op: resolve a CFI against the resident session.
const String workerOpSessionCfiResolve = 'sessionCfiResolve';

/// Wire protocol op: build a CFI from a reading position in the
/// resident session.
const String workerOpSessionCfiBuild = 'sessionCfiBuild';

/// Wire protocol op: end only the session identified by the request
/// payload. Later ops with that ID fail typed; other sessions stay live.
const String workerOpSessionDispose = 'sessionDispose';

/// Wire protocol reply kind: a decoded book.
const String wireReplyBook = 'book';

/// Wire protocol reply kind: decoded book metadata.
const String wireReplyMetadata = 'metadata';

/// Wire protocol reply kind: encoded search results.
const String wireReplySearch = 'search';

/// Wire protocol reply kind: an encoded EPUB CFI location (JSON null
/// when the CFI resolves nowhere).
const String wireReplyCfiLocation = 'cfiLocation';

/// Wire protocol reply kind: an encoded CFI string.
const String wireReplyCfi = 'cfi';

/// Wire protocol reply kind: a parse failure.
const String wireReplyError = 'error';

/// Wire protocol reply kind: a decoded session header book.
const String wireReplySessionOpen = 'sessionOpen';

/// Wire protocol reply kind: one inflated container entry (JSON null
/// in its blob reference when the entry does not exist).
const String wireReplySessionResource = 'sessionResource';

/// Wire protocol reply kind: inflated container entries, the blob list
/// aligned with the paths in the JSON half.
const String wireReplySessionResources = 'sessionResources';

/// Wire protocol reply kind: one raw container-source slice as a blob.
const String wireReplySessionRange = 'sessionRange';

/// Wire protocol reply kind: one raw document source (JSON null in its
/// blob reference when the document does not exist).
const String wireReplySessionSource = 'sessionSource';

/// Wire protocol reply kind: one PDF page's encoded text lines (JSON
/// null page when the session carries none).
const String wireReplySessionPdfLines = 'sessionPdfLines';

/// Wire protocol reply kind: one canonical document text (JSON null in
/// its blob reference when the document does not exist).
const String wireReplySessionText = 'sessionText';

/// Wire protocol reply kind: encoded session search results.
const String wireReplySessionSearch = 'sessionSearch';

/// Wire protocol reply kind: encoded session reading progression.
const String wireReplySessionProgression = 'sessionProgression';

/// Wire protocol reply kind: encoded session statistics.
const String wireReplySessionStatistics = 'sessionStatistics';

/// Wire protocol reply kind: an encoded EPUB CFI location resolved in
/// the session (JSON null when the CFI resolves nowhere).
const String wireReplySessionCfiLocation = 'sessionCfiLocation';

/// Wire protocol reply kind: an encoded CFI string built in the
/// session.
const String wireReplySessionCfi = 'sessionCfi';

/// Wire protocol reply kind: the resident session ended.
const String wireReplySessionDispose = 'sessionDispose';

/// Wire protocol key: request id echoed back on every reply.
const String wireKeyId = 'id';

/// Wire protocol key: requested operation.
const String wireKeyOp = 'op';

/// Wire protocol key: the book bytes sent by the main thread.
const String wireKeyBytes = 'bytes';

/// Wire protocol key: the JSON-encoded op payload the stateful ops
/// read their arguments from; carried next to [wireKeyBytes], either
/// side may be absent.
const String wireKeyPayload = 'payload';

/// Session op payload key: identifies the independent progressive
/// session addressed by this request.
const String wireKeySessionId = 'sessionId';

/// Wire protocol key: reply discriminator.
const String wireKeyKind = 'kind';

/// Wire protocol key: the JSON half of a wire payload.
const String wireKeyJson = 'json';

/// Wire protocol key: the blob half of a wire payload — the flat list
/// of payloads the JSON map references by index. Entries are binary
/// byte lists or strings; structured clone carries both natively, so
/// text crosses without a UTF-8 round-trip.
const String wireKeyBlobs = 'blobs';

/// Wire protocol key: exception type name on error replies.
const String wireKeyType = 'type';

/// Wire protocol key: exception message on error replies.
const String wireKeyMessage = 'message';

/// Op payload key: the search query.
const String wireKeyQuery = 'query';

/// Op payload key: the search mode enum name.
const String wireKeyMode = 'mode';

/// Op payload key: whether the search folds case.
const String wireKeyCaseSensitive = 'caseSensitive';

/// Op payload key: whether the search tolerates typesetting noise.
const String wireKeyTolerant = 'tolerant';

/// Op payload key: the proximity interval in characters.
const String wireKeyNearChars = 'nearChars';

/// Op payload key: the snippet context radius in characters.
const String wireKeyContextChars = 'contextChars';

/// Op payload key: the match cap.
const String wireKeyMaxMatches = 'maxMatches';

/// Op payload key: the CFI string (request) or the built CFI string
/// (reply of [workerOpCfiBuild] and [workerOpSessionCfiBuild]).
const String wireKeyCfi = 'cfi';

/// Op payload key: the reading-order section index.
const String wireKeyContentIndex = 'contentIndex';

/// Op payload key: the offset inside the section's document text.
const String wireKeyOffsetInText = 'offsetInText';

/// Op payload key: the container entry path the session ops address.
const String wireKeyPath = 'path';

/// Op payload key: the container entry paths of a batched session
/// load.
const String wireKeyPaths = 'paths';

/// Op payload key: the start offset of a session range request.
const String wireKeyOffset = 'offset';

/// Op payload key: the requested byte count of a session range
/// request.
const String wireKeyCount = 'count';

/// Op payload key: the 0-based page index a `sessionPdfLines` request
/// addresses.
const String wireKeyPageIndex = 'pageIndex';

/// Reply key: the encoded PDF page text (lines, image placements,
/// page geometry) of a `sessionPdfLines` reply, JSON null when the
/// session carries no such page.
const String wireKeyPage = 'page';

/// Op payload key: the worker-side LRU budget of the session, in
/// bytes.
const String wireKeyCacheBytes = 'cacheBytes';

/// Op payload key: the cover cap of the session header, in bytes.
const String wireKeyCoverMaxBytes = 'coverMaxBytes';

/// Op payload key: the password a session open authenticates with
/// (PDF documents), empty when the book needs none.
const String wireKeyPassword = 'password';

/// Op payload key: the raw-slice cap of the session, in bytes.
const String wireKeyRangeMaxBytes = 'rangeMaxBytes';

/// Reply key: the total byte length of the session's container
/// source.
const String wireKeyByteLength = 'byteLength';

/// Op payload key / reply key: whether the opened session serves its
/// content entry by entry.
const String wireKeyProgressive = 'progressive';

/// Reply key: the per-section canonical-text lengths of a session
/// progression, aligned with the reading order.
const String wireKeySectionLengths = 'sectionLengths';

/// Reply key: the total canonical-text character count of a session
/// progression.
const String wireKeyTotalCharacters = 'totalCharacters';

/// Reply key: the word count of session statistics.
const String wireKeyWordCount = 'wordCount';

/// Reply key: the character count of session statistics.
const String wireKeyCharacterCount = 'characterCount';

/// Reply key: the encoded EPUB CFI location, JSON null when the CFI
/// resolved nowhere.
const String wireKeyLocation = 'location';

/// Reply key inside the blob-referencing session replies: the index of
/// the payload in the blob list, JSON null when the requested entry
/// does not exist.
const String wireKeyBlobIndex = 'blob';
