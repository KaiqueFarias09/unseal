import 'package:test/test.dart';
import 'package:unseal/unseal.dart';

void main() {
  group('Calibre sidecar OPF', () {
    test('metadata.opf merges over the book metadata', () async {
      // test/resources/sidecar/alice.epub ships with metadata.opf.
      final metadata = await Unseal.readMetadataFile('test/resources/sidecar/alice.epub');
      expect(metadata.title, 'Sidecar Title Wins');
      expect(metadata.authors, ['Sidecar Author']);
      expect(metadata.series, 'The Sidecar Series');
      expect(metadata.seriesIndex, 3.5);
      // The cover still comes from the book itself.
      expect(metadata.cover, isNotNull);
    });

    test('basename sidecar is preferred over metadata.opf', () async {
      final metadata = await Unseal.readMetadataFile('test/resources/sidecar_named/alice.epub');
      expect(metadata.title, 'Named Sidecar');
    });

    test('books without sidecars keep their own metadata', () async {
      final metadata = await Unseal.readMetadataFile(
        'test/resources/epub/Alices Adventures in Wonderland.epub',
      );
      expect(metadata.title, "Alice's Adventures in Wonderland");
      expect(metadata.series, isNull);
    });
  });
}
