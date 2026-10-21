// Listens for the OAuth redirect (musicman://callback?code=...) via app_links.

import 'dart:async';

import 'package:app_links/app_links.dart';

/// Waits for the OAuth redirect and extracts the `code` query parameter.
/// Returns null when the user cancels (closes the browser) or on timeout.
class OAuthRedirectListener {
  final AppLinks _appLinks;

  OAuthRedirectListener([AppLinks? appLinks])
      : _appLinks = appLinks ?? AppLinks();

  Future<String?> waitForCode({
    required Future<void> Function() launch,
    required String redirectScheme,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final completer = Completer<String?>();
    late final StreamSubscription sub;
    sub = _appLinks.uriLinkStream.listen((uri) {
      if (uri.scheme == redirectScheme &&
          uri.queryParameters.containsKey('code')) {
        if (!completer.isCompleted) {
          completer.complete(uri.queryParameters['code']);
        }
      }
    }, onError: (_) {
      if (!completer.isCompleted) completer.complete(null);
    });

    await launch();

    try {
      return await completer.future.timeout(timeout, onTimeout: () => null);
    } finally {
      await sub.cancel();
    }
  }
}
