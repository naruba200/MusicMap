// Spotify WebView login (push 2): the user signs in to Spotify in an
// in-app WebView; the sp_dc session cookie is captured and returned to
// the platform, which stores it in secure storage. The cookie is the
// long-lived session — the client re-mints access tokens from it, so
// the user only signs in again when Spotify rejects it.
// No password is ever typed outside spotify.com, and no token or cookie
// is logged.

import 'package:material_ui/material_ui.dart';
import 'package:webview_flutter/webview_flutter.dart';

class SpotifyLoginScreen extends StatefulWidget {
  const SpotifyLoginScreen({super.key});

  @override
  State<SpotifyLoginScreen> createState() => _SpotifyLoginScreenState();
}

class _SpotifyLoginScreenState extends State<SpotifyLoginScreen> {
  late final WebViewController _controller;
  int _progress = 0;
  bool _captured = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageFinished: (_) => _captureSpDc(),
        ),
      )
      // Straight to the sign-in page, not the open.spotify.com web app:
      // the login form is lighter and appears faster. An already-logged-in
      // user bounces straight through to open.spotify.com, where the
      // sp_dc capture below still fires on page finish.
      ..loadRequest(Uri.parse('https://accounts.spotify.com/en/login'));
  }

  /// Reads the sp_dc cookie from the WebView's cookie jar. Called on
  /// every page finish: the login flow bounces through
  /// accounts.spotify.com and lands back on open.spotify.com, and a
  /// previously-logged-in session is captured on the first load.
  Future<void> _captureSpDc() async {
    if (_captured || !mounted) return;
    final cookies = await WebViewCookieManager().getCookies(
      domain: Uri.parse('https://open.spotify.com'),
    );
    for (final cookie in cookies) {
      if (cookie.name == 'sp_dc' && cookie.value.isNotEmpty) {
        _captured = true;
        if (mounted) Navigator.of(context).pop<String>(cookie.value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Spotify')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Sign in with your Spotify account. Your session stays on '
              'this device and is only used to read playlists you paste.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if (_progress < 100)
            LinearProgressIndicator(value: _progress / 100),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
