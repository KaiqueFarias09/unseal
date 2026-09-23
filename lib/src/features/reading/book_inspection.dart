import '../../foundation/entities/book/book.dart';
import '../../foundation/entities/book_format.dart';
import '../../foundation/exceptions/unseal_exception.dart';
import '../detection/entities/detected_format.dart';

/// The outcome of a full opening through `Unseal.inspect`.
///
/// A successful inspection contains the parsed [book], so callers can keep it
/// instead of parsing the same bytes again. A failed inspection contains the
/// original typed [error]. A detected family is only a signature-level hint;
/// it does not prove that a book is valid or identify every zip subtype.
final class BookInspection {
  /// Creates a successful inspection.
  const BookInspection.opened(Book parsedBook, this.detectedFormat)
    : book = parsedBook,
      error = null;

  /// Creates a failed inspection.
  const BookInspection.failed(UnsealException failure, this.detectedFormat)
    : book = null,
      error = failure;

  /// The opened book, or `null` when opening failed.
  final Book? book;

  /// The typed opening failure, or `null` when opening succeeded.
  final UnsealException? error;

  /// The format family inferred from the input signature, when recognizable.
  final DetectedFormat? detectedFormat;

  /// The concrete book format, available only after a successful opening.
  BookFormat? get format => book?.format;

  /// Whether the same bytes opened successfully through `Unseal.read`.
  bool get canOpen => book != null;
}
