// The Spotify login screen must open the sign-in page directly
// (accounts.spotify.com/en/login), not the heavy open.spotify.com web
// app, so the login form appears faster — and the sp_dc capture must
// still fire when the flow lands on open.spotify.com.
//
// No real WebView is constructed: WebViewPlatform.instance is replaced
// with a fake that records the loaded URL and lets the test fire the
// stored page-finished callback (the same seam the platform interface
// documents for unit testing).

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';
import 'package:music_man/presentation/screens/spotify_login_screen.dart';

class _FakePlatform extends WebViewPlatform {
  Uri? lastLoadedUri;
  PageEventCallback? onPageFinished;
  ProgressCallback? onProgress;
  List<WebViewCookie> cookiesToReturn = const [];

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) =>
      _FakeController.implementation(params, this);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) =>
      _FakeDelegate.implementation(params, this);

  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) =>
      _FakeCookieManager.implementation(params, this);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) =>
      _FakeWidget.implementation(params);
}

class _FakeController extends PlatformWebViewController {
  _FakeController.implementation(
    super.params,
    this._platform,
  ) : super.implementation();

  final _FakePlatform _platform;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _platform.lastLoadedUri = params.uri;
  }
}

class _FakeDelegate extends PlatformNavigationDelegate {
  _FakeDelegate.implementation(
    super.params,
    this._platform,
  ) : super.implementation();

  final _FakePlatform _platform;

  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async {
    _platform.onProgress = onProgress;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    _platform.onPageFinished = onPageFinished;
  }
}

class _FakeCookieManager extends PlatformWebViewCookieManager {
  _FakeCookieManager.implementation(
    super.params,
    this._platform,
  ) : super.implementation();

  final _FakePlatform _platform;

  @override
  Future<List<WebViewCookie>> getCookies(Uri url) async =>
      _platform.cookiesToReturn;
}

class _FakeWidget extends PlatformWebViewWidget {
  _FakeWidget.implementation(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  testWidgets('login screen loads the sign-in page directly', (tester) async {
    final platform = _FakePlatform();
    WebViewPlatform.instance = platform;

    await tester.pumpWidget(
      const MaterialApp(home: SpotifyLoginScreen()),
    );
    await tester.pump();

    expect(
      platform.lastLoadedUri,
      Uri.parse('https://accounts.spotify.com/en/login'),
    );
    expect(platform.lastLoadedUri.toString(), isNot(contains('open.spotify')));
  });

  testWidgets('sp_dc capture still fires after the login bounce',
      (tester) async {
    final platform = _FakePlatform();
    WebViewPlatform.instance = platform;
    platform.cookiesToReturn = const [
      WebViewCookie(
          name: 'sp_dc', value: 'test-cookie', domain: 'open.spotify.com'),
    ];

    String? popped;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              popped = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => const SpotifyLoginScreen(),
                ),
              );
            },
            child: const Text('go'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.byType(SpotifyLoginScreen), findsOneWidget);

    // Simulate the login flow landing on open.spotify.com: the page
    // finishes, the screen reads the cookie jar and pops with sp_dc.
    platform.onPageFinished?.call('https://open.spotify.com');
    await tester.pumpAndSettle();

    expect(popped, 'test-cookie');
    expect(find.byType(SpotifyLoginScreen), findsNothing);
  });
}
