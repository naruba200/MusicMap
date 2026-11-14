// Spotify adapter: playlist reads through the internal web-player API
// (api-partner GraphQL), live-verified 2026-11-14.
//
// Auth is the user's own Spotify session: sign-in opens open.spotify.com
// in an in-app WebView and captures the sp_dc cookie (stored in secure
// storage by the push-1 client); the access + client tokens are minted
// from it on demand. There is NO developer key, NO OAuth client
// id/secret, and NO anonymous-token route (tested: the token endpoint
// rejects it with 400). The parked OAuth PKCE adapter (official Web API)
// was replaced in 2026-11-14: Spotify's Feb 2026 Dev Mode changes block
// the Web API unless the app owner holds Premium.
//
// Import is link-based: the internal API has no proven "my playlists"
// query, so fetchUserPlaylists returns [] and the home screen says so.
// Restricted/unreadable playlist items are counted by the client, never
// presented as tracks — the review UI shows the honest readable/total
// counts from PlaylistInfo.trackCount.

import '../../core/constants.dart';
import '../models/music_models.dart';
import '../spotify/spotify_client.dart';
import 'music_platform.dart';
import 'open_in_app.dart';

/// Opens the Spotify WebView login and returns the captured sp_dc cookie,
/// or null when the user backs out. Wired by the provider layer (which
/// owns the navigator); the platform stays UI-free and testable.
typedef SpotifyLoginRunner = Future<String?> Function();

class SpotifyPlatform extends MusicPlatform {
  final SpotifyInternalClient _client;
  final SpotifyLoginRunner? _loginRunner;

  SpotifyPlatform(this._client, {SpotifyLoginRunner? loginRunner})
      : _loginRunner = loginRunner;

  @override
  String get id => PlatformIds.spotify;

  @override
  String get displayName => 'Spotify';

  @override
  bool get isBeta => true;

  @override
  bool get requiresAuthForLibrary => true;

  /// Pasted links need the session too: the web-player token is minted
  /// from the user's own sp_dc cookie, and there is no anonymous route.
  @override
  bool get linkNeedsAuth => true;

  @override
  Future<bool> signIn() async {
    if (await isSignedIn) return true;
    final runner = _loginRunner;
    if (runner == null) {
      throw const PlatformException(
          'Spotify sign-in is not available here — connect from the home screen.');
    }
    final spDc = await runner();
    if (spDc == null || spDc.isEmpty) return false; // user backed out
    await _client.saveSpDc(spDc);
    return true;
  }

  @override
  Future<void> signOut() => _client.signOut();

  @override
  Future<bool> get isSignedIn => _client.hasSession;

  static final _linkPattern = RegExp(
      r'(?:open\.spotify\.com/playlist/|spotify:playlist:)([A-Za-z0-9]+)');

  /// Bare playlist ids (Spotify ids are base62, 22 chars).
  static final _bareIdPattern = RegExp(r'^[A-Za-z0-9]{22}$');

  @override
  PlaylistRef? parseLink(String url) {
    final text = url.trim();
    final match = _linkPattern.firstMatch(text);
    if (match != null) {
      return PlaylistRef(
          platformId: id, playlistId: match.group(1)!, rawUrl: url);
    }
    if (_bareIdPattern.hasMatch(text)) {
      return PlaylistRef(platformId: id, playlistId: text, rawUrl: url);
    }
    return null;
  }

  /// Link-based import only (see the file header): the picker stays
  /// empty, and the home screen says so.
  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async => const [];

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    final info = await _client.fetchPlaylistInfo(playlistId);
    if (info.trackCount > 0) return info;
    // The metadata response may omit the total; the first contents
    // page carries the true total, and the review UI needs it for the
    // honest readable/total count.
    final page = await _client.fetchPlaylistTracks(playlistId, offset: 0);
    return PlaylistInfo(
      platformId: info.platformId,
      id: info.id,
      name: info.name,
      description: info.description,
      coverUrl: info.coverUrl,
      owner: info.owner,
      trackCount: page.totalCount,
    );
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    final offset = (cursor as int?) ?? 0;
    final page =
        await _client.fetchPlaylistTracks(playlistId, offset: offset);
    return TrackPage(
      tracks: page.tracks,
      hasMore: page.hasMore,
      cursor: page.nextOffset,
    );
  }

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await openLinkInAppFirst(
        Uri.parse('https://open.spotify.com/search/$query'));
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await openLinkInAppFirst(
        Uri.parse('https://open.spotify.com/playlist/$playlistId'));
  }
}
