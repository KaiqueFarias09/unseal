/// Public, format-agnostic eLivre API.
library;

export 'comic.dart';
export 'epub.dart';
export 'fb2.dart';
export 'mobi.dart';
export 'src/features/calibre/calibre_database.dart';
export 'src/features/cfi/epub_cfi.dart';
export 'src/features/cfi/epub_cfi_resolver.dart';
export 'src/features/detection/format_detector.dart';
export 'src/features/opds/opds_feed.dart';
export 'src/features/reading/book.dart';
export 'src/features/reading/book_reader.dart';
export 'src/features/search/book_search.dart';
export 'src/foundation/entities/entities.dart';
export 'src/foundation/exceptions/elivre_exception.dart';
export 'src/foundation/utils/image_size.dart';
export 'src/foundation/utils/image_sniffer.dart';
export 'src/foundation/utils/metadata_utils.dart';
export 'src/foundation/utils/plain_text.dart';
export 'src/foundation/utils/sort_keys.dart';
export 'src/heuristics.dart';
