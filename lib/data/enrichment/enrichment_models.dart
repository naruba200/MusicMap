// Enrichment models (Phase 2). Enrichment annotates results AFTER
// scoring — never scores, order, or pool. Plain JSON maps so
// GenerationResult can persist them to history without codegen.

/// MusicBrainz data attached to one recommended track.
class TrackEnrichment {
  /// Canonical MusicBrainz recording ID (for ISRC matching / dedupe).
  final String? recordingMbid;

  /// Canonical MusicBrainz artist ID (later: TheAudioDB artist-mb).
  final String? artistMbid;

  /// Tags from MusicBrainz, most-voted first, capped at parse time.
  final List<String> tags;

  /// First release title seen for this recording, if any.
  final String? releaseTitle;

  /// MusicBrainz release ID for [releaseTitle] (Discogs step 2).
  final String? releaseMbid;

  /// First release date seen, e.g. "2020-05-01" (may be year-only).
  final String? releaseDate;

  /// ISRC codes for this recording, for same-recording matching.
  final List<String> isrcs;

  const TrackEnrichment({
    this.recordingMbid,
    this.artistMbid,
    this.tags = const [],
    this.releaseTitle,
    this.releaseMbid,
    this.releaseDate,
    this.isrcs = const [],
  });

  /// Four-digit year from [releaseDate], or null when unparseable.
  String? get releaseYear {
    final d = releaseDate;
    if (d == null || d.length < 4) return null;
    final year = d.substring(0, 4);
    return int.tryParse(year) == null ? null : year;
  }

  bool get isEmpty =>
      recordingMbid == null &&
      artistMbid == null &&
      tags.isEmpty &&
      releaseTitle == null &&
      releaseDate == null &&
      isrcs.isEmpty;

  Map<String, dynamic> toJson() => {
        if (recordingMbid != null) 'recordingMbid': recordingMbid,
        if (artistMbid != null) 'artistMbid': artistMbid,
        if (tags.isNotEmpty) 'tags': tags,
        if (releaseTitle != null) 'releaseTitle': releaseTitle,
        if (releaseMbid != null) 'releaseMbid': releaseMbid,
        if (releaseDate != null) 'releaseDate': releaseDate,
        if (isrcs.isNotEmpty) 'isrcs': isrcs,
      };

  factory TrackEnrichment.fromJson(Map<String, dynamic> json) =>
      TrackEnrichment(
        recordingMbid: json['recordingMbid'] as String?,
        artistMbid: json['artistMbid'] as String?,
        tags: ((json['tags'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
        releaseTitle: json['releaseTitle'] as String?,
        releaseMbid: json['releaseMbid'] as String?,
        releaseDate: json['releaseDate'] as String?,
        isrcs: ((json['isrcs'] as List?) ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}
