import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Runs before every test file in this directory.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // The app loads Archivo / Noto Sans JP from Google Fonts at runtime
  // and caches them on-device; tests must not hit the network, so
  // runtime fetching is off here and text renders with the fallback
  // font. The fontFamily names on the styles are still asserted in
  // appearance_test.dart.
  GoogleFonts.config.allowRuntimeFetching = false;
  // CachedNetworkImage (via flutter_cache_manager) asks path_provider
  // for its cache directories on the first image load. The test
  // binding has no path_provider implementation, so that call throws
  // a MissingPluginException as an uncaught async error and fails
  // whichever test happens to be running (Group 4 song rows now load
  // album art as a fallback cover, so the first Results test hit
  // it). Point the channel at a real temp dir so the cache manager
  // initializes normally; image downloads themselves still fail
  // with the test binding's 400 HttpClient and fall back to the
  // error widget, exactly as before.
  TestWidgetsFlutterBinding.ensureInitialized();
  final cacheDir =
      await Directory.systemTemp.createTemp('music_man_test_paths');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall call) async {
      switch (call.method) {
        case 'getTemporaryDirectory':
        case 'getApplicationSupportDirectory':
        case 'getApplicationDocumentsDirectory':
        case 'getLibraryDirectory':
        case 'getExternalStorageDirectory':
        case 'getDownloadsDirectory':
          return cacheDir.path;
        case 'getExternalCacheDirectories':
        case 'getExternalStorageDirectories':
          return <String>[cacheDir.path];
        default:
          return null;
      }
    },
  );
  await testMain();
}
