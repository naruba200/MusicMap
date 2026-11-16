// Spotify playlist reads through the internal web-player API
// (api-partner GraphQL), live-verified 2026-11-14.
//
// Auth: the user's own Spotify session via the sp_dc cookie (stored by
// the WebView login, push 2). From it, a WEB-PLAYER access token is
// minted on demand (TOTP + the Spotube plugin's nuance file) and a
// client token from clienttoken.spotify.com — api-partner 403s without
// the client token. There is NO developer key, NO OAuth client
// id/secret, and NO anonymous-token route (tested: the token endpoint
// rejects it with 400).
//
// Failure contract (plan §0): a rejected/expired session throws
// PlatformException with authExpired: true and clears the stored
// session, so the next attempt re-logs-in — never a silent failure,
// never a silent re-pair loop. Other HTTP errors become a readable
// PlatformException; connection failures propagate as DioException to
// the provider layer, which turns them into an empty load + error
// label. Non-Track playlist items (RestrictedContent, Episode, ...) are
// counted, never presented as tracks, and never silently dropped from
// the total — the UI shows the honest readable/total counts.

import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';

import '../models/music_models.dart';
import '../platforms/music_platform.dart';
import 'spotify_session.dart';
import 'spotify_totp.dart';

/// One page of a Spotify playlist read.
class SpotifyTrackPage {
  final List<Track> tracks;
  final int totalCount;

  /// Items on this page Spotify returned as something other than a
  /// Track (RestrictedContent, Episode, ...): counted, never presented
  /// as tracks.
  final int restrictedCount;
  final bool hasMore;

  /// Offset of the next page (counts ALL items consumed, including
  /// restricted ones — the API pages by item position).
  final int nextOffset;

  const SpotifyTrackPage({
    required this.tracks,
    required this.totalCount,
    this.restrictedCount = 0,
    required this.hasMore,
    required this.nextOffset,
  });
}

/// A fully-read playlist: metadata + every readable track, in order.
class SpotifyPlaylistData {
  final PlaylistInfo info;
  final List<Track> tracks;

  /// Total restricted/unreadable items across all pages.
  final int restrictedCount;

  const SpotifyPlaylistData({
    required this.info,
    required this.tracks,
    this.restrictedCount = 0,
  });

  int get readableCount => tracks.length;
}

/// The TOTP secret + version, fetched live from the Spotube plugin's
/// nuance file (a public gist). The version goes into the token call
/// as totpVer; on failure the file is re-fetched uncached once and the
/// token call retried once.
typedef SpotifyNuance = ({String secret, int version});

class SpotifyInternalClient {
  final Dio _dio;
  final SpotifySession _session;

  SpotifyInternalClient(this._dio, this._session);

  /// Spotify's own public web client id (used by the web player itself).
  static const String webPlayerClientId =
      'd8a5ed958d274c2e8ee717e6a4b0971d';

  /// open.spotify.com no longer publishes an app version in its HTML,
  /// so the last known one is the default (matches Echo's fallback).
  static const String appVersion = '1.2.88.248.g539a4816';

  static const String _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

  /// Both playlist operations share this persisted-query hash.
  static const String _persistedQueryHash =
      '19ff1327c29e99c208c86d7a9d8f1929cfdf3d3202a0ff4253c821f1901aa94d';

  /// The track-search operation needs a DIFFERENT persisted-query hash
  /// (read live 2026-11-15 from sonic-liberation/spotube-plugin-spotify
  /// SearchClient.kt — never guessed). It is passed to [_graphQl]
  /// explicitly; the playlist hash above stays the default.
  static const String _searchPersistedQueryHash =
      'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428';

  static const String _nuanceUrl =
      'https://gist.githubusercontent.com/raw/22ed9c6ba463899e933427f7de1f0eef/nuances.json';

  /// Tracks per contents page (the API's page size in the spike).
  static const int pageSize = 25;

  /// Short timeouts: a dead Spotify never stalls a run (plan §0).
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 15);

  /// In-memory token caches (mirrored to secure storage; cleared on
  /// sign-out or session rejection).
  String? _accessToken;
  int _accessTokenExpiresAtMs = 0;
  String? _clientToken;
  int _clientTokenExpiresAtMs = 0;

  /// True when a sp_dc cookie is stored (the login is remembered).
  Future<bool> get hasSession async =>
      (await _session.spDc)?.isNotEmpty == true;

  /// Stores the sp_dc cookie captured by the WebView login.
  Future<void> saveSpDc(String spDc) async {
    _accessToken = null;
    _accessTokenExpiresAtMs = 0;
    _clientToken = null;
    _clientTokenExpiresAtMs = 0;
    await _session.saveSpDc(spDc);
  }

  /// Clears the session + in-memory tokens.
  Future<void> signOut() async {
    _accessToken = null;
    _accessTokenExpiresAtMs = 0;
    _clientToken = null;
    _clientTokenExpiresAtMs = 0;
    await _session.clear();
  }

  // -- Tokens -------------------------------------------------------------

  /// Web-player access token, minted on demand from the stored sp_dc
  /// and cached (in memory + storage) until shortly before expiry.
  Future<String> accessToken() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && _accessTokenExpiresAtMs > nowMs + 60000) {
      return _accessToken!;
    }
    final stored = await _session.accessToken;
    final storedExp = await _session.accessTokenExpiresAtMs;
    if (stored != null &&
        stored.isNotEmpty &&
        storedExp != null &&
        storedExp > nowMs + 60000) {
      _accessToken = stored;
      _accessTokenExpiresAtMs = storedExp;
      return stored;
    }
    return _mintAccessToken();
  }

  Future<String> _mintAccessToken() async {
    final spDc = await _session.spDc;
    if (spDc == null || spDc.isEmpty) {
      throw const PlatformException(
          'Spotify is not signed in — sign in to Spotify again.',
          authExpired: true);
    }
    // Two attempts: the second re-fetches the nuance file uncached
    // (the Spotube plugin's retry), then a repeated rejection means
    // the cookie itself is dead.
    for (var attempt = 0; attempt < 2; attempt++) {
      final nuance = await _fetchNuance(uncached: attempt > 0);
      final otp =
          generateTotp(nuance.secret, unixSeconds: await _serverTime());
      try {
        final res = await _dio.get(
          'https://open.spotify.com/api/token',
          queryParameters: {
            'reason': 'transport',
            'productType': 'web-player',
            'totp': otp,
            'totpServer': otp,
            'totpVer': nuance.version,
          },
          options: Options(
            headers: {'User-Agent': _userAgent, 'Cookie': 'sp_dc=$spDc;'},
            connectTimeout: _connectTimeout,
            receiveTimeout: _receiveTimeout,
          ),
        );
        final data = _asJsonMap(res.data);
        final token = data['accessToken'] as String?;
        final expiresAtMs =
            (data['accessTokenExpirationTimestampMs'] as num?)?.toInt();
        if (token == null || token.isEmpty || expiresAtMs == null) {
          throw const PlatformException(
              'Spotify sign-in failed — sign in to Spotify again.',
              authExpired: true);
        }
        _accessToken = token;
        _accessTokenExpiresAtMs = expiresAtMs;
        await _session.saveAccessToken(token, expiresAtMs);
        return token;
      } on DioException catch (e) {
        final status = e.response?.statusCode;
        if ((status == 400 || status == 401) && attempt == 0) continue;
        if (status == 400 || status == 401) {
          await signOut();
          throw const PlatformException(
              'Spotify session expired — sign in to Spotify again.',
              authExpired: true);
        }
        rethrow;
      }
    }
    // Unreachable: every path above returns or throws.
    throw const PlatformException(
        'Spotify session expired — sign in to Spotify again.',
        authExpired: true);
  }

  /// Client token (required on every api-partner call), cached until
  /// shortly before expiry.
  Future<String> clientToken() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_clientToken != null &&
        _clientTokenExpiresAtMs > nowMs + 3600000) {
      return _clientToken!;
    }
    final stored = await _session.clientToken;
    final storedExp = await _session.clientTokenExpiresAtMs;
    if (stored != null &&
        stored.isNotEmpty &&
        storedExp != null &&
        storedExp > nowMs + 3600000) {
      _clientToken = stored;
      _clientTokenExpiresAtMs = storedExp;
      return stored;
    }
    final res = await _dio.post(
      'https://clienttoken.spotify.com/v1/clienttoken',
      data: {
        'client_data': {
          'client_version': appVersion,
          'client_id': webPlayerClientId,
          'js_sdk_data': {
            'device_brand': 'unknown',
            'device_id': _randomHex(32),
            'device_model': 'unknown',
            'device_type': 'computer',
            'os': 'windows',
            'os_version': 'NT 10.0',
          },
        },
      },
      options: Options(
        headers: {
          'User-Agent': _userAgent,
          'Accept': 'application/json',
          'Accept-Language': 'en-US,en;q=0.9',
          'Content-Type': 'application/json',
          'Origin': 'https://open.spotify.com',
          'Referer': 'https://open.spotify.com/',
          'Sec-Fetch-Dest': 'empty',
          'Sec-Fetch-Mode': 'cors',
          'Sec-Fetch-Site': 'same-site',
        },
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
      ),
    );
    final granted = _asJsonMap(res.data)['granted_token'] as Map?;
    final token = granted?['token'] as String?;
    final expiresIn = (granted?['expires_after_seconds'] as num?)?.toInt();
    if (token == null || token.isEmpty || expiresIn == null) {
      throw const PlatformException(
          'Could not reach Spotify — try again.');
    }
    final expiresAtMs =
        DateTime.now().millisecondsSinceEpoch + expiresIn * 1000;
    _clientToken = token;
    _clientTokenExpiresAtMs = expiresAtMs;
    await _session.saveClientToken(token, expiresAtMs);
    return token;
  }

  Future<SpotifyNuance> _fetchNuance({required bool uncached}) async {
    final url = uncached
        ? '$_nuanceUrl?t=${DateTime.now().millisecondsSinceEpoch}'
        : _nuanceUrl;
    final res = await _dio.get(
      url,
      options: Options(
        headers: {'User-Agent': _userAgent},
        connectTimeout: _connectTimeout,
        receiveTimeout: _receiveTimeout,
      ),
    );
    final list = _asJsonList(res.data);
    Map? best;
    for (final entry in list) {
      if (entry is Map && entry['s'] is String && entry['v'] is num) {
        if (best == null || (entry['v'] as num) > (best['v'] as num)) {
          best = entry;
        }
      }
    }
    if (best == null) {
      throw const PlatformException(
          'Could not load Spotify login data — try again.');
    }
    return (secret: best['s'] as String, version: (best['v'] as num).toInt());
  }

  /// Spotify's own clock for the TOTP; the local clock on failure.
  Future<int> _serverTime() async {
    try {
      final res = await _dio.get(
        'https://open.spotify.com/api/server-time',
        options: Options(
          headers: {'User-Agent': _userAgent},
          connectTimeout: _connectTimeout,
          receiveTimeout: _receiveTimeout,
        ),
      );
      final serverTime = _asJsonMap(res.data)['serverTime'];
      if (serverTime is num) return serverTime.toInt();
    } catch (_) {
      // Fall through to the local clock below.
    }
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }

  // -- Playlist reads ------------------------------------------------------

  /// Playlist metadata (name/description/cover/owner/total). The
  /// contents query does not return the name, so this is a separate
  /// call — the review UI shows the real title, not a bare id.
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final data = await _graphQl(
      'fetchPlaylistWithGatedEntityRelations',
      {'uri': 'spotify:playlist:$playlistId'},
    );
    final playlist = (data['data'] as Map?)?['playlistV2'] as Map?;
    if (playlist == null) {
      throw const PlatformException('Spotify playlist not found.');
    }
    return _playlistInfoFromJson(playlistId, playlist);
  }

  /// One page of tracks, starting at [offset] (item position, 25/page).
  /// Restricted/unreadable items are counted in [SpotifyTrackPage.restrictedCount],
  /// never returned as tracks.
  Future<SpotifyTrackPage> fetchPlaylistTracks(String playlistId,
      {int offset = 0}) async {
    final data = await _graphQl(
      'fetchPlaylistContentsWithGatedEntityRelations',
      {
        'uri': 'spotify:playlist:$playlistId',
        'offset': offset,
        'limit': pageSize,
      },
    );
    final content =
        ((data['data'] as Map?)?['playlistV2'] as Map?)?['content'] as Map?;
    if (content == null) {
      throw const PlatformException('Spotify playlist not found.');
    }
    final items = (content['items'] as List?) ?? [];
    final total = (content['totalCount'] as num?)?.toInt() ?? offset;
    final tracks = <Track>[];
    var restricted = 0;
    for (final item in items) {
      final itemData = ((item as Map?)?['itemV2'] as Map?)?['data'] as Map?;
      if (itemData == null || itemData['__typename'] != 'Track') {
        restricted++;
        continue;
      }
      final track = _trackFromJson(itemData);
      if (track == null) {
        restricted++;
        continue;
      }
      tracks.add(track);
    }
    final nextOffset = offset + items.length;
    return SpotifyTrackPage(
      tracks: tracks,
      totalCount: total,
      restrictedCount: restricted,
      hasMore: nextOffset < total,
      nextOffset: nextOffset,
    );
  }

  /// Metadata + every readable track, in playlist order. The guard on
  /// a non-advancing offset stops a pathological page loop.
  Future<SpotifyPlaylistData> fetchPlaylist(String playlistId) async {
    final info = await fetchPlaylistInfo(playlistId);
    final tracks = <Track>[];
    var restricted = 0;
    var total = info.trackCount;
    var offset = 0;
    var hasMore = true;
    while (hasMore) {
      final page =
          await fetchPlaylistTracks(playlistId, offset: offset);
      tracks.addAll(page.tracks);
      restricted += page.restrictedCount;
      total = page.totalCount;
      hasMore = page.hasMore && page.nextOffset > offset;
      offset = page.nextOffset;
    }
    return SpotifyPlaylistData(
      info: PlaylistInfo(
        platformId: info.platformId,
        id: info.id,
        name: info.name,
        description: info.description,
        coverUrl: info.coverUrl,
        owner: info.owner,
        trackCount: total,
      ),
      tracks: tracks,
      restrictedCount: restricted,
    );
  }

  // -- Track search (metadata only) -----------------------------------------

  /// Search Spotify for tracks by free text, using the verified
  /// `searchTracks` persisted query. This is METADATA only: Spotify's
  /// web streams are Widevine-DRM and cannot play in-app, so the
  /// caller uses the returned canonical title/artist to re-resolve
  /// the track through Audius / YouTube Music instead. Returns the
  /// matching tracks in Spotify's order (best first); an empty list
  /// when nothing matches. A rejected session throws PlatformException
  /// with authExpired, per the existing client contract — the caller
  /// logs it and continues without Spotify, never failing the whole
  /// resolve.
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    final data = await _graphQl(
      'searchTracks',
      {
        'searchTerm': query,
        'offset': 0,
        'limit': limit,
        'includePreReleases': false,
        'numberOfTopResults': limit,
        'includeAudiobooks': true,
        'includeAuthors': false,
      },
      persistedQueryHash: _searchPersistedQueryHash,
    );
    final searchV2 = (data['data'] as Map?)?['searchV2'] as Map?;
    final tracksV2 = searchV2?['tracksV2'] as Map?;
    final items = tracksV2?['items'] as List?;
    if (items == null) return const [];
    final tracks = <Track>[];
    for (final item in items) {
      // NOTE: search items nest the track under `item`, NOT the
      // playlist's `itemV2` key.
      final itemData = ((item as Map?)?['item'] as Map?)?['data'] as Map?;
      if (itemData == null || itemData['__typename'] != 'Track') continue;
      final track = _trackFromJson(itemData);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  // -- GraphQL -------------------------------------------------------------

  /// One persisted-query call with Echo's exact web-player headers.
  /// A 401/403 means the session is rejected: clear it and ask the
  /// user to sign in again (never retry silently). [persistedQueryHash]
  /// overrides the default playlist hash for operations (like search)
  /// that need their own.
  Future<Map<String, dynamic>> _graphQl(
    String operation,
    Map<String, dynamic> variables, {
    String? persistedQueryHash,
  }) async {
    final token = await accessToken();
    final ct = await clientToken();
    try {
      final res = await _dio.post(
        'https://api-partner.spotify.com/pathfinder/v2/query',
        data: {
          'operationName': operation,
          'variables': variables,
          'extensions': {
            'persistedQuery': {
              'version': 1,
              'sha256Hash': persistedQueryHash ?? _persistedQueryHash,
            },
          },
        },
        options: Options(
          headers: {
            'User-Agent': _userAgent,
            'sec-ch-ua-mobile': '?0',
            'Content-Type': 'application/json',
            'Accept': 'application/json',
            'Accept-Language': 'en-US,en;q=0.9',
            'Authorization': 'Bearer $token',
            'client-token': ct,
            'spotify-app-version': appVersion,
            'Origin': 'https://open.spotify.com',
            'Referer': 'https://open.spotify.com/',
            'Sec-Fetch-Dest': 'empty',
            'Sec-Fetch-Mode': 'cors',
            'Sec-Fetch-Site': 'same-site',
            'App-Platform': 'WebPlayer',
          },
          // A read-only query over POST: safe for the connection
          // retry interceptor, like the youtubei calls.
          extra: const {'retryReadOnly': true},
          connectTimeout: _connectTimeout,
          receiveTimeout: _receiveTimeout,
        ),
      );
      final data = _asJsonMap(res.data);
      final errors = data['errors'];
      if (errors is List && errors.isNotEmpty) {
        final message = (errors.first as Map?)?['message'] as String?;
        throw PlatformException(
            'Spotify request failed${message != null ? ': $message' : ''}.');
      }
      return data;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        await signOut();
        throw const PlatformException(
            'Spotify session expired — sign in to Spotify again.',
            authExpired: true);
      }
      throw _asPlatformException(e);
    }
  }

  /// Converts a Dio failure into a user-readable PlatformException,
  /// including Spotify's own error message when present.
  PlatformException _asPlatformException(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? spotifyMsg;
    if (data is Map) {
      final err = data['error'];
      if (err is Map && err['message'] is String) {
        spotifyMsg = err['message'] as String;
      }
    }
    return PlatformException(
        'Spotify request failed${status != null ? ' ($status)' : ''}'
        '${spotifyMsg != null ? ': $spotifyMsg' : ''}.');
  }

  // -- Parsing --------------------------------------------------------------

  PlaylistInfo _playlistInfoFromJson(String playlistId, Map playlist) {
    String? cover;
    final images = (playlist['images'] as Map?)?['items'] as List?;
    if (images != null && images.isNotEmpty) {
      final sources = (images.first as Map?)?['sources'] as List?;
      if (sources != null && sources.isNotEmpty) {
        cover = (sources.first as Map?)?['url'] as String?;
      }
    }
    // The metadata response may omit the total; the contents pages
    // carry the true total, and fetchPlaylist prefers that.
    final total = ((playlist['content'] as Map?)?['totalCount'] as num?)
            ?.toInt() ??
        0;
    return PlaylistInfo(
      platformId: 'spotify',
      id: playlistId,
      name: playlist['name'] as String? ?? 'Untitled playlist',
      description: _stripHtml(playlist['description'] as String?),
      coverUrl: cover,
      owner: ((playlist['ownerV2'] as Map?)?['data'] as Map?)?['name']
          as String?,
      trackCount: total,
    );
  }

  /// One contents item into a [Track], or null when the shape is not
  /// a usable track (the caller counts it as restricted instead).
  static Track? _trackFromJson(Map data) {
    final name = data['name'] as String?;
    if (name == null || name.isEmpty) return null;
    final artists = ((data['artists'] as Map?)?['items'] as List?) ?? [];
    final names = <String>[];
    for (final artist in artists) {
      final artistName =
          ((artist as Map?)?['profile'] as Map?)?['name'] as String?;
      if (artistName != null && artistName.isNotEmpty) names.add(artistName);
    }
    final album = (data['albumOfTrack'] as Map?)?['name'] as String?;
    String? imageUrl;
    final coverSources =
        ((data['albumOfTrack'] as Map?)?['coverArt'] as Map?)?['sources']
            as List?;
    if (coverSources != null && coverSources.isNotEmpty) {
      imageUrl = (coverSources.first as Map?)?['url'] as String?;
    }
    final durationMs =
        ((data['trackDuration'] as Map?)?['totalMilliseconds'] as num?)
                ?.toInt() ??
            ((data['duration'] as Map?)?['totalMilliseconds'] as num?)
                ?.toInt();
    return Track(
      title: name,
      artist: names.isEmpty ? 'Unknown artist' : names.join(', '),
      album: album,
      imageUrl: imageUrl,
      durationMs: durationMs,
      platformTrackId: data['uri'] as String? ?? data['id'] as String?,
    );
  }

  /// Spotify descriptions may contain HTML; the UI shows plain text.
  static String? _stripHtml(String? html) {
    if (html == null) return null;
    final text = html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
    return text.isEmpty ? null : text;
  }

  static String _randomHex(int length) {
    final rand = Random.secure();
    const chars = '0123456789abcdef';
    return List.generate(length, (_) => chars[rand.nextInt(chars.length)])
        .join();
  }

  // -- JSON helpers ----------------------------------------------------------

  /// Dio decodes JSON only when the content-type says so (the nuance
  /// gist serves text/plain); accept a decoded map or a raw string.
  static Map<String, dynamic> _asJsonMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return decoded.cast<String, dynamic>();
    }
    throw const PlatformException(
        'Spotify returned an unexpected response.');
  }

  static List _asJsonList(dynamic data) {
    if (data is List) return data;
    if (data is String) {
      final decoded = jsonDecode(data);
      if (decoded is List) return decoded;
    }
    throw const PlatformException(
        'Spotify returned an unexpected response.');
  }
}
