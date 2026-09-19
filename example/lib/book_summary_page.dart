import 'package:unseal/unseal.dart';
import 'package:unseal_example/example_app_constants.dart';
import 'package:unseal_example/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class BookSummaryPage extends StatelessWidget {
  const BookSummaryPage({super.key});

  @override
  Widget build(final BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(unsealExampleTitle)),
      body: FutureBuilder<Book>(
        future: _loadExampleBook(),
        builder: (final context, final snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Could not read book: ${snapshot.error}'));
          }

          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final book = snapshot.requireData;

          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    book.metadata.title ?? 'Untitled',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  AppSpacing.vMd,
                  Text('Format: ${book.format.name}'),
                  Text('Content files: ${book.files.html.length}'),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Future<Book> _loadExampleBook() async {
    final assetBytes = await rootBundle.load('assets/Alices Adventures in Wonderland.epub');
    return Unseal.read(Uint8List.sublistView(assetBytes));
  }
}
