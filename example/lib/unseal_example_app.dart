import 'package:unseal_example/book_summary_page.dart';
import 'package:unseal_example/example_app_constants.dart';
import 'package:flutter/material.dart';

class UnsealExampleApp extends StatelessWidget {
  const UnsealExampleApp({super.key});

  @override
  Widget build(final BuildContext context) {
    return MaterialApp(
      title: unsealExampleTitle,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: const BookSummaryPage(),
    );
  }
}
