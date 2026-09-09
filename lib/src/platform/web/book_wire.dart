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
/// (reply of [workerOpCfiBuild]).
const String wireKeyCfi = 'cfi';

/// Op payload key: the reading-order section index.
const String wireKeyContentIndex = 'contentIndex';

/// Op payload key: the offset inside the section's document text.
const String wireKeyOffsetInText = 'offsetInText';

/// Reply key: the encoded EPUB CFI location, JSON null when the CFI
/// resolved nowhere.
const String wireKeyLocation = 'location';
