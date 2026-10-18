// Recommendation engine — pure Dart, no Flutter imports (spec FR-05…FR-09,
// FR-11, FR-19). All Last.fm I/O is injected; this file only does
// selection, scoring, blending, dedupe and explanation.

import '../lastfm/lastfm_client.dart';
import '../models/music_models.dart';
import '../../core/constants.dart';

/// A recommended track with its score and human-readable reasons (FR-09).
class ScoredTrack {
  final Track track;
  final double score;
  final List<String> reasons; // top-2 contributing seed titles / tags

  const ScoredTrack({
    required this.track,
    required this.score,
    required this.reasons,
  });

  ScoredTrack withScore(double newScore) =>
      ScoredTrack(track: track, score: newScore, reasons: reasons);

  Map<String, dynamic> toJson() => {
        'track': track.toJson(),
        'score': score,
        'reasons': reasons,
      };

  factory ScoredTrack.fromJson(Map<String, dynamic> json) => ScoredTrack(
        track: Track.fromJson(
            (json['track'] as Map).cast<String, dynamic>()),
        score: (json['score'] as num).toDouble(),
        reasons: (json['reasons'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
      );
}

/// An album recommendation derived from recommended songs (FR-11).
class AlbumRec {
  final String name;
  final String artist;
  final String? artUrl;
  final int songCount;
  final double bestScore;
  final List<ScoredTrack> songs;

  const AlbumRec({
    required this.name,
    required this.artist,
    this.artUrl,
    required this.songCount,
    required this.bestScore,
    required this.songs,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'artist': artist,
        if (artUrl != null) 'artUrl': artUrl,
        'songCount': songCount,
        'bestScore': bestScore,
        'songs': [for (final s in songs) s.toJson()],
      };

  factory AlbumRec.fromJson(Map<String, dynamic> json) => AlbumRec(
        name: json['name'] as String? ?? 'Unknown album',
        artist: json['artist'] as String? ?? 'Unknown artist',
        artUrl: json['artUrl'] as String?,
        songCount: (json['songCount'] as num?)?.toInt() ?? 0,
        bestScore: (json['bestScore'] as num?)?.toDouble() ?? 0,
        songs: (json['songs'] as List?)
                ?.whereType<Map>()
                .map((m) => ScoredTrack.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
      );
}

/// Result of seed selection (FR-05 / FR-05b).
class SeedSelection {
  final List<Track> seeds;
  final int usableCount;

  const SeedSelection({required this.seeds, required this.usableCount});

  bool get meetsMinimum => usableCount >= minUsableTracks;
}

class RecommendationEngine {
  /// Normalization for dedupe (FR-08): lowercase, strip " - remastered"-style
  /// suffixes, trim.
  static String normalizeKey(String artist, String title) {
    var t = title.toLowerCase().trim();
    t = t.replaceAll(
        RegExp(r'\s+[\-\–\—]\s+(remaster(ed)?|remix|live|acoustic|demo|'
            r'version|edit|single version|radio edit)\b.*$'),
        '');
    t = t.replaceAll(RegExp(r'\s*[\(\[].*?(remaster|remix|live|acoustic|demo|'
        r'version|edit)[\)\]]\s*$'), '');
    return '${artist.toLowerCase().trim()} - ${t.trim()}';
  }

  /// Primary artist only: "A feat. B" → "A" (FR-06).
  static String primaryArtist(String artist) {
    final m = RegExp(r'^(.*?)\s+(feat\.?|ft\.?|featuring|with)\s+',
            caseSensitive: false)
        .firstMatch(artist);
    if (m != null) return m.group(1)!.trim();
    return artist.trim();
  }

  /// Seed selection (FR-05): drop unusable, dedupe, sample evenly, S formula.
  static SeedSelection selectSeeds(List<Track> tracks) {
    final seen = <String>{};
    final usable = <Track>[];
    for (final t in tracks) {
      if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
      final key = normalizeKey(t.artist, t.title);
      if (seen.add(key)) usable.add(t);
    }
    final n = usable.length;
    final s = n <= 0 ? 0 : (n < 10 ? n : _clampS((n / 15).ceil()));
    final seeds = <Track>[];
    if (s > 0) {
      if (n <= s) {
        seeds.addAll(usable);
      } else {
        // Even sampling across the playlist.
        for (var i = 0; i < s; i++) {
          seeds.add(usable[(i * (n - 1) / (s - 1)).round()]);
        }
      }
    }
    return SeedSelection(seeds: seeds, usableCount: n);
  }

  static int _clampS(int s) => s < 10 ? 10 : (s > 30 ? 30 : s);

  /// Score candidates from per-seed similar-track lists (FR-07 + FR-08 + FR-09).
  /// [similarBySeed] maps a seed index to its Last.fm similar tracks in rank
  /// order. Returns scored, deduped, sorted-desc candidates (not yet cut).
  static List<ScoredTrack> scoreCandidates({
    required List<Track> seeds,
    required Map<int, List<SimilarTrack>> similarBySeed,
  }) {
    final seedKeys = {
      for (final s in seeds) normalizeKey(s.artist, s.title)
    };
    final scores = <String, double>{};
    final tracks = <String, Track>{};
    final contributions = <String, List<MapEntry<String, double>>>{};

    similarBySeed.forEach((seedIndex, similars) {
      final seedTitle = seeds[seedIndex].title;
      for (var rank = 0; rank < similars.length; rank++) {
        final sim = similars[rank];
        if (sim.artist.trim().isEmpty || sim.title.trim().isEmpty) continue;
        final key = normalizeKey(sim.artist, sim.title);
        if (seedKeys.contains(key)) continue; // never recommend a seed (FR-08)
        final w = 1 / (1 + rank); // seedWeight = 1 in v1 (FR-07)
        scores[key] = (scores[key] ?? 0) + w;
        tracks.putIfAbsent(
            key, () => Track(title: sim.title, artist: sim.artist));
        (contributions[key] ??= []).add(MapEntry(seedTitle, w));
      }
    });

    final result = <ScoredTrack>[];
    scores.forEach((key, score) {
      final contribs = contributions[key]!..sort((a, b) => b.value.compareTo(a.value));
      final reasons = contribs.take(2).map((e) => e.key).toList();
      result.add(ScoredTrack(track: tracks[key]!, score: score, reasons: reasons));
    });
    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  /// Discovery-modifier blending (FR-07b): score × (1 + 0.5 × tagHits).
  static List<ScoredTrack> applyModifierBoost(
      List<ScoredTrack> candidates, List<Set<String>> modifierKeySets) {
    if (modifierKeySets.isEmpty) return candidates;
    final boosted = candidates.map((c) {
      final key = normalizeKey(c.track.artist, c.track.title);
      final hits = modifierKeySets.where((s) => s.contains(key)).length;
      return hits == 0 ? c : c.withScore(c.score * (1 + 0.5 * hits));
    }).toList();
    boosted.sort((a, b) => b.score.compareTo(a.score));
    return boosted;
  }

  /// Fresh-finds boost (FR-07c): ×1.3 for candidates in the trending set.
  static List<ScoredTrack> applyFreshBoost(
      List<ScoredTrack> candidates, Set<String> trendingKeys) {
    if (trendingKeys.isEmpty) return candidates;
    return [
      for (final c in candidates)
        trendingKeys.contains(normalizeKey(c.track.artist, c.track.title))
            ? c.withScore(c.score * 1.3)
            : c
    ]..sort((a, b) => b.score.compareTo(a.score));
  }

  /// Take the top N (or fewer if the pool is exhausted).
  static List<ScoredTrack> topN(List<ScoredTrack> candidates, int n) =>
      candidates.take(n).toList();

  /// Derive album recommendations from recommended songs (FR-11):
  /// group by album, rank by (song count desc, best song score desc).
  static List<AlbumRec> deriveAlbums(List<ScoredTrack> songs, int count) {
    final groups = <String, List<ScoredTrack>>{};
    for (final s in songs) {
      final album = s.track.album?.trim();
      if (album == null || album.isEmpty) continue;
      final key = '${s.track.artist.toLowerCase().trim()} - ${album.toLowerCase()}';
      (groups[key] ??= []).add(s);
    }
    final recs = groups.entries.map((e) {
      final songs = e.value..sort((a, b) => b.score.compareTo(a.score));
      final first = songs.first.track;
      return AlbumRec(
        name: first.album!,
        artist: first.artist,
        artUrl: songs
            .map((s) => s.track.imageUrl)
            .firstWhere((u) => u != null && u.isNotEmpty, orElse: () => null),
        songCount: songs.length,
        bestScore: songs.first.score,
        songs: songs,
      );
    }).toList();
    recs.sort((a, b) {
      final c = b.songCount.compareTo(a.songCount);
      return c != 0 ? c : b.bestScore.compareTo(a.bestScore);
    });
    return recs.take(count).toList();
  }

  /// Surprise-me songs (FR-19): merge tag top tracks, dedupe (keep max
  /// listeners), rank by listeners desc. With Fresh finds on, intersect the
  /// trending set first (falling back to the full merge when empty).
  static List<ScoredTrack> surpriseSongs({
    required Map<String, List<TagTrack>> topByTag,
    Set<String>? trendingKeys,
    required int count,
  }) {
    final best = <String, TagTrack>{};
    final tagOf = <String, String>{};
    topByTag.forEach((tag, tracks) {
      for (final t in tracks) {
        if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
        final key = normalizeKey(t.artist, t.title);
        if ((best[key]?.listeners ?? -1) < t.listeners) {
          best[key] = t;
          tagOf[key] = tag;
        }
      }
    });
    var keys = best.keys.toList();
    if (trendingKeys != null && trendingKeys.isNotEmpty) {
      final inter = keys.where(trendingKeys.contains).toList();
      if (inter.isNotEmpty) keys = inter;
    }
    keys.sort((a, b) => best[b]!.listeners.compareTo(best[a]!.listeners));
    return [
      for (final k in keys.take(count))
        ScoredTrack(
          track: Track(title: best[k]!.title, artist: best[k]!.artist),
          score: best[k]!.listeners.toDouble(),
          reasons: ['Popular in ${tagOf[k]}'],
        )
    ];
  }

  /// Surprise-me albums (FR-19): merge tag top albums, dedupe, keep
  /// fetch order (Last.fm returns them ranked), take top [count].
  static List<AlbumRec> surpriseAlbums({
    required Map<String, List<TagAlbum>> topByTag,
    required int count,
  }) {
    final seen = <String>{};
    final recs = <AlbumRec>[];
    for (final albums in topByTag.values) {
      for (final a in albums) {
        if (a.artist.trim().isEmpty || a.name.trim().isEmpty) continue;
        final key = '${a.artist.toLowerCase().trim()} - ${a.name.toLowerCase().trim()}';
        if (seen.add(key)) {
          recs.add(AlbumRec(
            name: a.name,
            artist: a.artist,
            songCount: 0,
            bestScore: 0,
            songs: const [],
          ));
        }
        if (recs.length >= count) return recs;
      }
    }
    return recs;
  }
}
