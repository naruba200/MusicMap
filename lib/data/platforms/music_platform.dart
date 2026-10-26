// The platform adapter interface (spec §8). The recommendation engine
// (M2) only ever sees artist+title pairs produced through this interface.

import '../models/music_models.dart';

/// Thrown when a platform call fails in a way the UI should surface.
class PlatformException implements Exception {
  final String message;
  final bool authExpired;

  const PlatformException(this.message, {this.authExpired = false});

  @override
  String toString() => 'PlatformException: $message';
}

/// A page of tracks from a playlist fetch.
class TrackPage {
  final List<Track> tracks;
  final bool hasMore;
  final Object? cursor;

  /// True when the platform knows the playlist continues beyond the
  /// tracks returned so far, but this import stopped early (a dead-end
  /// continuation, or a page cap hit with more pages pending). The UI
  /// surfaces this instead of silently truncating. Defaults to false:
  /// every other platform either pages to the true end or throws.
  final bool truncated;

  const TrackPage({
    required this.tracks,
    required this.hasMore,
    this.cursor,
    this.truncated = false,
  });
}

abstract class MusicPlatform {
  /// Stable id, e.g. 'spotify'. Matches [PlatformIds].
  String get id;

  /// Display name for the platform dropdown.
  String get displayName;

  /// True for experimental integrations (YouTube Music): UI shows a β badge
  /// and isolates failures so they never break the rest of the app.
  bool get isBeta => false;

  /// Whether this platform needs OAuth before the playlist picker works.
  /// Link intake always works without auth for public playlists.
  bool get requiresAuthForLibrary;

  // -- Auth ---------------------------------------------------------------

  /// Starts the OAuth flow. Completes with true when tokens are stored.
  /// Platforms without auth complete immediately with true.
  Future<bool> signIn();

  Future<void> signOut();

  Future<bool> get isSignedIn;

  // -- Intake --------------------------------------------------------------

  /// Parses a pasted/shared URL into a [PlaylistRef], or null when the URL
  /// is not a playlist link for this platform.
  PlaylistRef? parseLink(String url);

  /// The user's own playlists. Requires auth on platforms where
  /// [requiresAuthForLibrary] is true.
  Future<List<PlaylistInfo>> fetchUserPlaylists();

  /// One page of tracks. Call repeatedly while [TrackPage.hasMore] is true
  /// (with the returned cursor) to load 500+ track playlists fully.
  Future<TrackPage> fetchPlaylistTracks(String playlistId, {Object? cursor});

  /// Metadata for a single playlist (used after link parsing).
  Future<PlaylistInfo> fetchPlaylistInfo(String playlistId);

  // -- Outbound ------------------------------------------------------------

  /// Opens a track in the platform's app/website (FR-15).
  Future<void> openTrack(Track track);

  /// Opens a playlist in the platform's app/website.
  Future<void> openPlaylist(String playlistId);
}
