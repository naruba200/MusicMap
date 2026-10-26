// Album enrichment models (Phase 2, steps 2–3). One model covers
// both Discogs and TheAudioDB data: each source fills the fields
// it knows and merges into the same per-album entry, so the card
// shows one honest line per source instead of two competing cards.
// Plain JSON maps, like TrackEnrichment, for history persistence.

/// Key for an album enrichment entry. Same shape the results
/// screen already uses for its album-art cache.
String albumEnrichmentKey(String artist, String album) =>
    '${artist.toLowerCase().trim()}|${album.toLowerCase().trim()}';

/// Discogs and/or TheAudioDB data attached to one album card.
class AlbumEnrichment {
  /// Release year (Discogs release year or TheAudioDB year).
  final int? year;

  /// Discogs styles, e.g. ["Alternative Rock"].
  final List<String> styles;

  /// Discogs genres, e.g. ["Rock"].
  final List<String> genres;

  /// Discogs community rating average (0–5), if any votes exist.
  final double? communityRating;

  /// Discogs community rating vote count.
  final int? ratingCount;

  /// Discogs release ID this data came from, if any.
  final int? discogsReleaseId;

  /// TheAudioDB album artwork URL, used only when the album has no
  /// art from Last.fm yet (never replaces known art).
  final String? artUrl;

  /// TheAudioDB artist thumbnail URL (fallback card art when no
  /// album art exists at all).
  final String? artistThumbUrl;

  /// TheAudioDB discography: album names by this artist, newest
  /// first when the source orders them that way.
  final List<String> discography;

  /// Sources that contributed, e.g. ["Discogs"] or
  /// ["Discogs", "TheAudioDB"]. Shown on the card so enrichment is
  /// never presented as Last.fm data.
  final List<String> sources;

  const AlbumEnrichment({
    this.year,
    this.styles = const [],
    this.genres = const [],
    this.communityRating,
    this.ratingCount,
    this.discogsReleaseId,
    this.artUrl,
    this.artistThumbUrl,
    this.discography = const [],
    this.sources = const [],
  });

  bool get isEmpty =>
      year == null &&
      styles.isEmpty &&
      genres.isEmpty &&
      communityRating == null &&
      artUrl == null &&
      artistThumbUrl == null &&
      discography.isEmpty;

  /// Merges [update] into this entry: non-null / non-empty fields
  /// from [update] win, everything else is kept, sources unioned.
  AlbumEnrichment merge(AlbumEnrichment update) => AlbumEnrichment(
        year: update.year ?? year,
        styles: update.styles.isNotEmpty ? update.styles : styles,
        genres: update.genres.isNotEmpty ? update.genres : genres,
        communityRating: update.communityRating ?? communityRating,
        ratingCount: update.ratingCount ?? ratingCount,
        discogsReleaseId: update.discogsReleaseId ?? discogsReleaseId,
        artUrl: update.artUrl ?? artUrl,
        artistThumbUrl: update.artistThumbUrl ?? artistThumbUrl,
        discography:
            update.discography.isNotEmpty ? update.discography : discography,
        sources: {...sources, ...update.sources}.toList(),
      );

  Map<String, dynamic> toJson() => {
        if (year != null) 'year': year,
        if (styles.isNotEmpty) 'styles': styles,
        if (genres.isNotEmpty) 'genres': genres,
        if (communityRating != null) 'communityRating': communityRating,
        if (ratingCount != null) 'ratingCount': ratingCount,
        if (discogsReleaseId != null)
          'discogsReleaseId': discogsReleaseId,
        if (artUrl != null) 'artUrl': artUrl,
        if (artistThumbUrl != null) 'artistThumbUrl': artistThumbUrl,
        if (discography.isNotEmpty) 'discography': discography,
        if (sources.isNotEmpty) 'sources': sources,
      };

  factory AlbumEnrichment.fromJson(Map<String, dynamic> json) =>
      AlbumEnrichment(
        year: (json['year'] as num?)?.toInt(),
        styles: ((json['styles'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        genres: ((json['genres'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        communityRating:
            (json['communityRating'] as num?)?.toDouble(),
        ratingCount: (json['ratingCount'] as num?)?.toInt(),
        discogsReleaseId: (json['discogsReleaseId'] as num?)?.toInt(),
        artUrl: json['artUrl'] as String?,
        artistThumbUrl: json['artistThumbUrl'] as String?,
        discography: ((json['discography'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        sources: ((json['sources'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}
