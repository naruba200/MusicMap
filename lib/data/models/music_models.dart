// Plain data models for the intake layer (M1).
// Everything serializes to JSON maps so Hive can store them without codegen.

/// A single track. The recommendation engine (M2) only needs artist + title.
class Track {
  final String title;
  final String artist;
  final String? album;
  final String? imageUrl;
  final int? durationMs;
  final String? platformTrackId;
  final String? previewUrl; // 30-second preview (iTunes), nullable

  const Track({
    required this.title,
    required this.artist,
    this.album,
    this.imageUrl,
    this.durationMs,
    this.platformTrackId,
    this.previewUrl,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        if (album != null) 'album': album,
        if (imageUrl != null) 'imageUrl': imageUrl,
        if (durationMs != null) 'durationMs': durationMs,
        if (platformTrackId != null) 'platformTrackId': platformTrackId,
        if (previewUrl != null) 'previewUrl': previewUrl,
      };

  factory Track.fromJson(Map<String, dynamic> json) => Track(
        title: json['title'] as String? ?? 'Unknown title',
        artist: json['artist'] as String? ?? 'Unknown artist',
        album: json['album'] as String?,
        imageUrl: json['imageUrl'] as String?,
        durationMs: (json['durationMs'] as num?)?.toInt(),
        platformTrackId: json['platformTrackId'] as String?,
        previewUrl: json['previewUrl'] as String?,
      );
}

/// Result of parsing a pasted/shared playlist link: enough to fetch it.
class PlaylistRef {
  final String platformId;
  final String playlistId;
  final String? rawUrl;

  const PlaylistRef({
    required this.platformId,
    required this.playlistId,
    this.rawUrl,
  });
}

/// Playlist metadata (list view / picker rows).
class PlaylistInfo {
  final String platformId;
  final String id;
  final String name;
  final String? description;
  final String? coverUrl;
  final String? owner;
  final int trackCount;

  const PlaylistInfo({
    required this.platformId,
    required this.id,
    required this.name,
    this.description,
    this.coverUrl,
    this.owner,
    this.trackCount = 0,
  });

  Map<String, dynamic> toJson() => {
        'platformId': platformId,
        'id': id,
        'name': name,
        if (description != null) 'description': description,
        if (coverUrl != null) 'coverUrl': coverUrl,
        if (owner != null) 'owner': owner,
        'trackCount': trackCount,
      };

  factory PlaylistInfo.fromJson(Map<String, dynamic> json) => PlaylistInfo(
        platformId: json['platformId'] as String? ?? '',
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? 'Untitled playlist',
        description: json['description'] as String?,
        coverUrl: json['coverUrl'] as String?,
        owner: json['owner'] as String?,
        trackCount: (json['trackCount'] as num?)?.toInt() ?? 0,
      );
}

/// Per-playlist discovery settings (persisted with the saved playlist).
class DiscoverySettings {
  final int songCount;
  final int albumCount;
  final Set<String> moods;
  final Set<String> genres;
  final bool freshFinds;

  const DiscoverySettings({
    required this.songCount,
    required this.albumCount,
    this.moods = const {},
    this.genres = const {},
    this.freshFinds = false,
  });

  DiscoverySettings copyWith({
    int? songCount,
    int? albumCount,
    Set<String>? moods,
    Set<String>? genres,
    bool? freshFinds,
  }) =>
      DiscoverySettings(
        songCount: songCount ?? this.songCount,
        albumCount: albumCount ?? this.albumCount,
        moods: moods ?? this.moods,
        genres: genres ?? this.genres,
        freshFinds: freshFinds ?? this.freshFinds,
      );

  Map<String, dynamic> toJson() => {
        'songCount': songCount,
        'albumCount': albumCount,
        'moods': moods.toList(),
        'genres': genres.toList(),
        'freshFinds': freshFinds,
      };

  factory DiscoverySettings.fromJson(Map<String, dynamic> json) =>
      DiscoverySettings(
        songCount: (json['songCount'] as num?)?.toInt() ?? 30,
        albumCount: (json['albumCount'] as num?)?.toInt() ?? 10,
        moods: ((json['moods'] as List?) ?? []).map((e) => e.toString()).toSet(),
        genres:
            ((json['genres'] as List?) ?? []).map((e) => e.toString()).toSet(),
        freshFinds: json['freshFinds'] as bool? ?? false,
      );
}

/// A playlist the user imported, with its track snapshot and settings (FR-15).
class SavedPlaylist {
  final PlaylistInfo info;
  final List<Track> tracks;
  final DiscoverySettings settings;
  final DateTime importedAt;
  final DateTime lastScannedAt;

  const SavedPlaylist({
    required this.info,
    required this.tracks,
    required this.settings,
    required this.importedAt,
    required this.lastScannedAt,
  });

  Map<String, dynamic> toJson() => {
        'info': info.toJson(),
        'tracks': tracks.map((t) => t.toJson()).toList(),
        'settings': settings.toJson(),
        'importedAt': importedAt.toIso8601String(),
        'lastScannedAt': lastScannedAt.toIso8601String(),
      };

  factory SavedPlaylist.fromJson(Map<String, dynamic> json) => SavedPlaylist(
        info: PlaylistInfo.fromJson(
            Map<String, dynamic>.from(json['info'] as Map? ?? {})),
        tracks: ((json['tracks'] as List?) ?? [])
            .map((e) => Track.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        settings: DiscoverySettings.fromJson(
            Map<String, dynamic>.from(json['settings'] as Map? ?? {})),
        importedAt: DateTime.tryParse(json['importedAt'] as String? ?? '') ??
            DateTime.now(),
        lastScannedAt:
            DateTime.tryParse(json['lastScannedAt'] as String? ?? '') ??
                DateTime.now(),
      );
}
