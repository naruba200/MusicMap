// App-wide constants for Music Man (spec §8, §10).
// API keys / client IDs ship as placeholders — see README "Setup".

/// Spotify app client ID. Create one at https://developer.spotify.com/dashboard
/// and set the redirect URI to `musicman://callback`.
const String spotifyClientId = 'YOUR_SPOTIFY_CLIENT_ID';

/// Custom scheme used for the Spotify OAuth redirect (must match the
/// AndroidManifest intent-filter — see docs/android-share-intent.md).
const String oauthRedirectUri = 'musicman://callback';

/// SoundCloud API client ID (register an app at https://developers.soundcloud.com).
const String soundCloudClientId = 'YOUR_SOUNDCLOUD_CLIENT_ID';

/// Last.fm API key (https://www.last.fm/api/account/create). Used by the
/// recommendation engine in M2.
const String lastFmApiKey = 'afe16fee1f96d0177b7d691f4b7bc89c';

/// Jamendo API client_id (https://devportal.jamendo.com — free reads).
/// Placeholder in the repo: replace locally with your own id, never commit
/// a real one. Until it is set, the Jamendo Discover tab shows a setup
/// hint instead of making calls.
const String jamendoClientId = 'YOUR_JAMENDO_CLIENT_ID';

/// Bandsintown API app ID (Phase 5, dormant code path only).
/// Bandsintown issues app IDs only with its written consent for the
/// intended use (accept terms at corp.bandsintown.com/dataapplicationsterms,
/// then contact Bandsintown via help.bandsintown.com). Placeholder in
/// the repo: replace locally with an issued id, never commit a real
/// one. Until it is set, the events screen shows a setup hint and
/// makes NO network calls at all.
const String bandsintownAppId = 'YOUR_BANDSINTOWN_APP_ID';

/// Supported platform IDs.
class PlatformIds {
  static const String spotify = 'spotify';
  static const String deezer = 'deezer';
  static const String soundCloud = 'soundcloud';
  static const String youTubeMusic = 'youtubemusic';
}

/// Recommendation-count presets (FR-04d).
const List<int> songCountPresets = [30, 50, 75, 100, 150];
const List<int> albumCountPresets = [5, 10, 20, 30];
const int defaultSongCount = 30;
const int defaultAlbumCount = 10;

/// Minimum usable tracks to run the engine (FR-05).
const int minUsableTracks = 5;

/// Discovery modifier chips (FR-04e).
const List<String> moodChips = [
  'Energetic',
  'Chill',
  'Happy',
  'Melancholic',
  'Focus',
  'Workout',
  'Party',
];

const List<String> genreChips = [
  'Rock',
  'Pop',
  'Hip-Hop',
  'Electronic',
  'Jazz',
  'Classical',
  'R&B',
  'Metal',
  'Indie',
  'K-Pop',
  'J-Pop',
  'J-Rock',
  'Anime',
  'City Pop',
  'Country',
  'Latin',
  // Rhythm-game staples (added 2026-10-18).
  'Drum and Bass',
  'Chiptune',
  'Hardcore Techno',
  'Happy Hardcore',
  'Trance',
  'Eurobeat',
  'Vocaloid',
  'Touhou',
  'Artcore',
  'Breakcore',
  'Hardstyle',
  'Dubstep',
];

/// Display name → Last.fm tag for genres whose tag differs from the label.
/// Genres absent here map 1:1 via lowercase.
const Map<String, String> genreTagMapping = {
  'Hip-Hop': 'hip-hop',
  'R&B': 'rnb',
  'K-Pop': 'k-pop',
  'J-Pop': 'j-pop',
  'J-Rock': 'j-rock',
  'City Pop': 'city pop',
  'Drum and Bass': 'drum and bass',
  'Hardcore Techno': 'hardcore techno',
  'Happy Hardcore': 'happy hardcore',
};

/// How many genre chips are visible before the "Show more" expander.
const int visibleGenreCount = 8;

/// Static fallback for the "Related genres" row (FR-04e). M2 replaces this
/// with live Last.fm `tag.getSimilar` results.
const Map<String, List<String>> staticRelatedGenres = {
  'Rock': ['J-Rock', 'Metal', 'Indie', 'Punk'],
  'J-Rock': ['Visual Kei', 'Metal', 'Punk', 'Math Rock'],
  'J-Pop': ['City Pop', 'Anime', 'K-Pop'],
  'Electronic': ['Synthwave', 'House', 'Techno'],
  'Hip-Hop': ['R&B', 'Trap', 'Rap'],
  'Metal': ['J-Rock', 'Metalcore', 'Rock'],
  'Jazz': ['City Pop', 'Classical', 'Funk'],
  'Anime': ['J-Pop', 'J-Rock', 'City Pop'],
  'City Pop': ['J-Pop', 'Jazz', 'Funk'],
  'Hardcore Techno': ['Hardstyle', 'Happy Hardcore', 'Breakcore'],
  'Chiptune': ['Vocaloid', 'Touhou', 'Artcore'],
  'Vocaloid': ['Chiptune', 'J-Pop', 'Touhou'],
  'Drum and Bass': ['Breakcore', 'Dubstep', 'Electronic'],
};
