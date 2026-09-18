import 'package:e_livre_example/book_summary_page.dart';
import 'package:e_livre_example/example_app_constants.dart';
import 'package:flutter/material.dart';

class ELivreExampleApp extends StatelessWidget {
  const ELivreExampleApp({super.key});

  @override
  Widget build(final BuildContext context) {
    return MaterialApp(
      title: eLivreExampleTitle,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const BookSummaryPage(),
    );
  }
}
