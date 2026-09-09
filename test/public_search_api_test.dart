import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

final class _PublicSearchBook extends Book {
  _PublicSearchBook()
    : files = Files(
        images: const <BinaryFile>[],
        css: const <TextFile>[],
        html: <TextFile>[
          TextFile(
            name: 'chapter.html',
            type: 'html',
            path: 'chapter.html',
            content: '<p>Needle needle.</p>',
          ),
        ],
        fonts: const <BinaryFile>[],
        others: const <BinaryFile>[],
      ),
      navigation = Navigation(title: 'Contents', navPoints: const <NavPoint>[]),
      super(format: BookFormat.epub);

  @override
  final Files files;

  @override
  final Navigation navigation;

  @override
  BookMetadata get metadata => const BookMetadata(format: BookFormat.epub);
}

void main() {
  test('public entry point closes the BookSearch result contract', () {
    final SearchResults results = _PublicSearchBook().search(
      'Needle',
      mode: SearchMode.wholeWords,
      isCaseSensitive: true,
    );
    final SearchMatch match = results.matches.single;

    expect(match.sectionName, 'chapter.html');
    expect(match.snippet, contains('Needle'));
  });
}
