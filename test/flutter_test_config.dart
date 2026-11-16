import 'dart:async';

import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file in this directory.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The app loads Archivo / Noto Sans JP from Google Fonts at runtime
  // and caches them on-device; tests must not hit the network, so
  // runtime fetching is off here and text renders with the fallback
  // font. The fontFamily names on the styles are still asserted in
  // appearance_test.dart.
  GoogleFonts.config.allowRuntimeFetching = false;
  await testMain();
}
