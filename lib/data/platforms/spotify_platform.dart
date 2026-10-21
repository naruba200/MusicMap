// Spotify adapter: OAuth PKCE intake + Web API (spec §8, US-01–US-03).
//
// Setup: create an app at https://developer.spotify.com/dashboard, set
// spotifyClientId in lib/core/constants.dart, and register the redirect URI
// `musicman://callback` (plus the AndroidManifest intent-filter — see
// docs/android-share-intent.md).

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../auth/token_store.dart';
import '../models/music_models.dart';
import 'music_platform.dart';
import 'platform_oauth.dart';

class SpotifyPlatform extends MusicPlatform {
  final Dio _dio;
  final TokenStore _tokens;
  final OAuthRedirectListener _redirectListener;

  SpotifyPlatform(this._dio, this._tokens, this._redirectListener);

  @override
  String get id => PlatformIds.spotify;

  @override
  String get displayName => 'Spotify';

  @override
  bool get requiresAuthForLibrary => true;

  // -- Auth ---------------------------------------------------------------

  /// Builds the Spotify authorize URL with strict percent-encoding.
  /// NOTE: do NOT use Uri.https(..., queryParameters: {...}) here — Dart
  /// encodes the space in `scope` as `+`, which Spotify does not decode as
  /// a space. The token is then granted with no scopes and every playlist
  /// call fails with 403 "Insufficient client scope".
  Uri _authorizeUri({required String redirectUri, required String challenge}) {
    final q = [
      'client_id=${Uri.encodeComponent(spotifyClientId)}',
      'response_type=code',
      'redirect_uri=${Uri.encodeComponent(redirectUri)}',
      'code_challenge_method=S256',
      'code_challenge=${Uri.encodeComponent(challenge)}',
      'scope=${Uri.encodeComponent('playlist-read-private playlist-read-collaborative')}',
    ].join('&');
    return Uri.parse('https://accounts.spotify.com/authorize?$q');
  }

  @override
  Future<bool> signIn() async {
    if (await isSignedIn) return true;
    if (spotifyClientId == 'YOUR_SPOTIFY_CLIENT_ID') {
      throw const PlatformException(
          'Set your Spotify client ID in lib/core/constants.dart first (see README).');
    }

    final verifier = _codeVerifier();
    final challenge = _codeChallenge(verifier);
    final authUri =
        _authorizeUri(redirectUri: oauthRedirectUri, challenge: challenge);

    final code = await _redirectListener.waitForCode(
      launch: () => launchUrl(authUri, mode: LaunchMode.externalApplication),
      redirectScheme: 'musicman',
    );
    if (code == null) return false; // user cancelled

    await _exchangeCode(code, verifier);
    return true;
  }

  Future<void> _exchangeCode(String code, String verifier) async {
    final res = await _dio.post(
      'https://accounts.spotify.com/api/token',
      data: {
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': oauthRedirectUri,
        'client_id': spotifyClientId,
        'code_verifier': verifier,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = res.data as Map<String, dynamic>;
    await _tokens.saveTokens(
      id,
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String?,
      expiresInSeconds: (data['expires_in'] as num?)?.toInt(),
    );
  }

  Future<String> _accessToken() async {
    if (await _tokens.hasValidToken(id)) {
      return (await _tokens.accessToken(id))!;
    }
    final refresh = await _tokens.refreshToken(id);
    if (refresh == null) {
      throw const PlatformException('Spotify session expired — sign in again.',
          authExpired: true);
    }
    final res = await _dio.post(
      'https://accounts.spotify.com/api/token',
      data: {
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
        'client_id': spotifyClientId,
      },
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = res.data as Map<String, dynamic>;
    await _tokens.saveTokens(
      id,
      accessToken: data['access_token'] as String,
      refreshToken: data['refresh_token'] as String? ?? refresh,
      expiresInSeconds: (data['expires_in'] as num?)?.toInt(),
    );
    return data['access_token'] as String;
  }

  @override
  Future<void> signOut() => _tokens.clear(id);

  @override
  Future<bool> get isSignedIn => _tokens.hasValidToken(id);

  // -- Intake --------------------------------------------------------------

  static final _linkPattern = RegExp(
      r'(?:open\.spotify\.com/playlist/|spotify:playlist:)([A-Za-z0-9]+)');

  @override
  PlaylistRef? parseLink(String url) {
    final match = _linkPattern.firstMatch(url);
    if (match == null) return null;
    return PlaylistRef(
        platformId: id, playlistId: match.group(1)!, rawUrl: url);
  }

  Future<Map<String, String>> _authHeaders() async =>
      {'Authorization': 'Bearer ${await _accessToken()}'};

  /// Converts a Dio failure into a user-readable PlatformException,
  /// including Spotify's own error message when present.
  PlatformException _asPlatformException(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    // NOTE: do not collapse this into a one-liner like
    //   data is Map ? (data['error'] as Map?)?['message'] : null
    // The `?` right after the ternary's `?` gets parsed as a nested
    // ternary instead of a null-aware subscript, and compilation fails.
    String? spotifyMsg;
    if (data is Map) {
      final err = data['error'];
      if (err is Map && err['message'] is String) {
        spotifyMsg = err['message'] as String;
      }
    }
    if (status == 401) {
      return const PlatformException(
          'Spotify session expired — sign in again.',
          authExpired: true);
    }
    return PlatformException(
        'Spotify request failed${status != null ? ' ($status)' : ''}'
        '${spotifyMsg != null ? ': $spotifyMsg' : ''}.');
  }

  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async {
    final headers = await _authHeaders();
    final out = <PlaylistInfo>[];
    var url = 'https://api.spotify.com/v1/me/playlists?limit=50';
    try {
      while (url.isNotEmpty) {
        final res = await _dio.get(url, options: Options(headers: headers));
        final data = res.data as Map<String, dynamic>;
        for (final item in (data['items'] as List? ?? [])) {
          final m = item as Map<String, dynamic>;
          final images = (m['images'] as List?) ?? [];
          out.add(PlaylistInfo(
            platformId: id,
            id: m['id'] as String,
            name: m['name'] as String? ?? 'Untitled playlist',
            description: m['description'] as String?,
            coverUrl:
                images.isNotEmpty ? images.first['url'] as String? : null,
            owner: (m['owner'] as Map?)?['display_name'] as String?,
            trackCount:
                ((m['tracks'] as Map?)?['total'] as num?)?.toInt() ?? 0,
          ));
        }
        url = (data['next'] as String?) ?? '';
      }
    } on DioException catch (e) {
      throw _asPlatformException(e);
    }
    return out;
  }

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final headers = await _authHeaders();
    try {
      final res = await _dio.get('https://api.spotify.com/v1/playlists/$playlistId',
          queryParameters: {'fields': 'id,name,description,images,owner,tracks.total'},
          options: Options(headers: headers));
      return _playlistFromJson(res.data as Map<String, dynamic>);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        throw const PlatformException('Spotify session expired — sign in again.',
            authExpired: true);
      }
      rethrow;
    }
  }

  PlaylistInfo _playlistFromJson(Map<String, dynamic> m) {
    final images = (m['images'] as List?) ?? [];
    return PlaylistInfo(
      platformId: id,
      id: m['id'] as String,
      name: m['name'] as String? ?? 'Untitled playlist',
      description: m['description'] as String?,
      coverUrl: images.isNotEmpty ? images.first['url'] as String? : null,
      owner: (m['owner'] as Map?)?['display_name'] as String?,
      trackCount: ((m['tracks'] as Map?)?['total'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    final headers = await _authHeaders();
    final offset = (cursor as int?) ?? 0;
    final res = await _dio.get(
      'https://api.spotify.com/v1/playlists/$playlistId/tracks',
      queryParameters: {
        'limit': 100,
        'offset': offset,
        'fields':
            'items(track(id,name,artists(name),album(name,images))),next,total',
      },
      options: Options(headers: headers),
    );
    final data = res.data as Map<String, dynamic>;
    final tracks = <Track>[];
    for (final item in (data['items'] as List? ?? [])) {
      final t = (item as Map<String, dynamic>)['track'] as Map?;
      if (t == null) continue;
      final artists = ((t['artists'] as List?) ?? [])
          .map((a) => (a as Map)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .join(', ');
      final images = ((t['album'] as Map?)?['images'] as List?) ?? [];
      tracks.add(Track(
        title: t['name'] as String? ?? 'Unknown title',
        artist: artists.isEmpty ? 'Unknown artist' : artists,
        album: (t['album'] as Map?)?['name'] as String?,
        imageUrl: images.isNotEmpty ? images.first['url'] as String? : null,
        platformTrackId: t['id'] as String?,
      ));
    }
    final total = (data['total'] as num?)?.toInt() ?? offset + tracks.length;
    final nextOffset = offset + tracks.length;
    return TrackPage(
      tracks: tracks,
      hasMore: nextOffset < total && (data['next'] as String?) != null,
      cursor: nextOffset,
    );
  }

  // -- Outbound ------------------------------------------------------------

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await launchUrl(
        Uri.parse('https://open.spotify.com/search/$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await launchUrl(Uri.parse('https://open.spotify.com/playlist/$playlistId'),
        mode: LaunchMode.externalApplication);
  }

  // -- PKCE helpers --------------------------------------------------------

  String _codeVerifier() {
    final rand = Random.secure();
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    return List.generate(
        64, (_) => chars[rand.nextInt(chars.length)]).join();
  }

  String _codeChallenge(String verifier) {
    final digest = sha256.convert(utf8.encode(verifier));
    return base64Url.encode(digest.bytes).replaceAll('=', '');
  }
}
