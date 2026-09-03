import 'package:e_livre/e_livre.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<Book> loadExampleBook() async {
  final data = await rootBundle.load(
    'assets/Alices Adventures in Wonderland.epub',
  );
  return BookReader.openFromBytes(Uint8List.sublistView(data));
}

void main() {
  runApp(const ELivreExampleApp());
}

class ELivreExampleApp extends StatelessWidget {
  const ELivreExampleApp({super.key});

  @override
  Widget build(final BuildContext context) {
    return MaterialApp(
      title: 'eLivre example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const BookSummaryPage(),
    );
  }
}

class BookSummaryPage extends StatelessWidget {
  const BookSummaryPage({super.key});

  @override
  Widget build(final BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('eLivre example')),
      body: FutureBuilder<Book>(
        future: loadExampleBook(),
        builder: (final context, final snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text('Could not read book: ${snapshot.error}'),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

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
                  const SizedBox(height: 12),
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
}
