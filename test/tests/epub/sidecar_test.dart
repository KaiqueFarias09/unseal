import 'package:e_livre/e_livre.dart';
import 'package:test/test.dart';

void main() {
  group('Calibre sidecar OPF', () {
    test('metadata.opf merges over the book metadata', () async {
      // test/resources/sidecar/sample1.epub ships with metadata.opf.
      final metadata = await BookReader.readMetadataFromPath('test/resources/sidecar/sample1.epub');
      expect(metadata.title, 'Sidecar Title Wins');
      expect(metadata.authors, ['Sidecar Author']);
      expect(metadata.series, 'The Sidecar Series');
      expect(metadata.seriesIndex, 3.5);
      // The cover still comes from the book itself.
      expect(metadata.cover, isNotNull);
    });

    test('basename sidecar is preferred over metadata.opf', () async {
      final metadata = await BookReader.readMetadataFromPath(
        'test/resources/sidecar_named/renamed-book.epub',
      );
      expect(metadata.title, 'Named Sidecar');
    });

    test('books without sidecars keep their own metadata', () async {
      final metadata = await BookReader.readMetadataFromPath('test/resources/epub/sample1.epub');
      expect(
        metadata.title,
        "The Geography of Bliss: One Grump's Search for the Happiest "
        'Places in the World',
      );
      expect(metadata.series, isNull);
    });
  });
}
