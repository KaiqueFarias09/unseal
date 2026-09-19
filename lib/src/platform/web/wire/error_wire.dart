import '../../../features/azw4/exceptions/azw4_exception.dart';
import '../../../features/comic/exceptions/comic_exception.dart';
import '../../../features/comic7/exceptions/comic7_exception.dart';
import '../../../features/docx/exceptions/docx_exception.dart';
import '../../../features/epub/exceptions/empty_bytes_exception.dart';
import '../../../features/epub/exceptions/epub_exception.dart';
import '../../../features/fb2/exceptions/fb2_exception.dart';
import '../../../features/html/exceptions/html_exception.dart';
import '../../../features/mobi/exceptions/mobi_exception.dart';
import '../../../features/odt/exceptions/odt_exception.dart';
import '../../../features/pdf/exceptions/pdf_exception.dart';
import '../../../foundation/exceptions/unseal_exception.dart';

/// Rebuilds the exception hierarchy behind a worker error reply:
/// known [UnsealException] subtypes come back with their own type,
/// [FormatException] (a bad regex query) keeps its own type, unknown
/// ones degrade to the base exception with the original text
/// preserved.
Exception decodeErrorWire(final String type, final String message) {
  switch (type) {
    case 'EmptyBytesException':
      return EmptyBytesException();
    case 'FormatException':
      return FormatException(message);
    case 'FormatNotSupportedException':
      return FormatNotSupportedException(message);
    case 'DrmProtectedException':
      return DrmProtectedException(message);
    case 'InvalidBookException':
      return InvalidBookException(message);
    case 'EpubException':
      return EpubException(message);
    case 'MobiException':
      return MobiException(message);
    case 'Fb2Exception':
      return Fb2Exception(message);
    case 'ComicException':
      return ComicException(message);
    case 'Azw4Exception':
    case 'Azw4InvalidContainerException':
    case 'Azw4PdfNotFoundException':
      return Azw4Exception(message);
    case 'Azw4DrmProtectedException':
      return DrmProtectedException(message);
    case 'Comic7Exception':
    case 'Comic7PagesNotFoundException':
    case 'InvalidCbcCollectionException':
      return Comic7Exception(message);
    case 'DocxException':
    case 'InvalidDocxPackageException':
    case 'MissingDocxPartException':
    case 'InvalidDocxXmlException':
      return DocxException(message);
    case 'HtmlException':
      return HtmlException(message);
    case 'OdtException':
    case 'InvalidOdtPackageException':
    case 'MissingOdtPartException':
    case 'InvalidOdtXmlException':
      return OdtException(message);
    case 'PdfException':
      return PdfException(message);
    case 'PdfEncryptedException':
      return const PdfEncryptedException();
    default:
      return UnsealException(message);
  }
}
