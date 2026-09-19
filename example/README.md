# Unseal example

This Flutter app loads the bundled EPUB through `Unseal.read` and displays its
title, detected format, and content-file count. It demonstrates the public
package entry point without adding reader UI or application architecture.

From this directory, run:

```sh
flutter pub get
flutter run
```

The parsing call is in `lib/book_summary_page.dart`.
