// YouTube Music adapter — EXPERIMENTAL (β).
//
// There is no official YouTube Music API, so this adapter is isolated on
// purpose: it only parses links in M1, and track fetching throws an
// explicit [PlatformException]. The UI shows a β badge and never lets a
// failure here break the other platforms (spec §8, FR-02c).
//
// A future milestone can implement this against the reverse-engineered
// internal API (ytmusicapi-style `browse` calls); the seam is ready.

import 'package:url_launcher/url_launcher.dart';

import '../../core/constants.dart';
import '../models/music_models.dart';
import 'music_platform.dart';

class YouTubeMusicPlatform extends MusicPlatform {
  @override
  String get id => PlatformIds.youTubeMusic;

  @override
  String get displayName => 'YouTube Music';

  @override
  bool get isBeta => true;

  @override
  bool get requiresAuthForLibrary => false;

  @override
  Future<bool> signIn() async => true;

  @override
  Future<void> signOut() async {}

  @override
  Future<bool> get isSignedIn async => true;

  static final _linkPattern = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');

  @override
  PlaylistRef? parseLink(String url) {
    if (!url.contains('music.youtube.com') && !url.contains('youtube.com')) {
      return null;
    }
    final match = _linkPattern.firstMatch(url);
    if (match == null) return null;
    return PlaylistRef(
        platformId: id, playlistId: match.group(1)!, rawUrl: url);
  }

  @override
  Future<List<PlaylistInfo>> fetchUserPlaylists() async => const [];

  @override
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId) async {
    throw const PlatformException(
        'YouTube Music intake is experimental and not implemented yet.');
  }

  @override
  Future<TrackPage> fetchPlaylistTracks(String playlistId,
      {Object? cursor}) async {
    throw const PlatformException(
        'YouTube Music intake is experimental and not implemented yet.');
  }

  @override
  Future<void> openTrack(Track track) async {
    final query = Uri.encodeComponent('${track.artist} ${track.title}');
    await launchUrl(
        Uri.parse('https://music.youtube.com/search?q=$query'),
        mode: LaunchMode.externalApplication);
  }

  @override
  Future<void> openPlaylist(String playlistId) async {
    await launchUrl(
        Uri.parse(
            'https://music.youtube.com/playlist?list=$playlistId'),
        mode: LaunchMode.externalApplication);
  }
}
