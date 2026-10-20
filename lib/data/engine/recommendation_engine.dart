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

  /// Slot-based injection (FR-07b/07c as amended 2026-10-20, §28):
  /// merge [core] with tracks injected from the discovery modifiers and
  /// the Fresh-finds chart, by quota instead of by score — seed scores
  /// (similarity ranks) and tag listener counts are incommensurable,
  /// and the old overlap-boost changed nothing when the overlap was
  /// empty, which was nearly always.
  ///
  /// - Modifier pool: round-robin across [modifierByTag] in map order,
  ///   each tag's rank order preserved; quota ≈ total/3.
  /// - Fresh pool: [chartTracks] in rank order; quota ≈ total/5.
  /// - Combined injected quota is capped at total/2; fresh yields
  ///   first when the cap binds.
  /// - Injected tracks never repeat the seed playlist ([seedKeys]),
  ///   the core list, or each other. If a pool runs dry the others
  ///   backfill; core always keeps the remaining slots.
  /// - Sources interleave by quota progress (taken/desired, core wins
  ///   ties) so injections spread evenly through the list.
  /// - An injected track's score sits just under the previously
  ///   emitted track's, so album derivation (FR-11) ranks it by its
  ///   list position; reasons are "Popular in {tag}" / "Trending now".
  static List<ScoredTrack> blendWithInjections({
    required List<ScoredTrack> core,
    required Map<String, List<TagTrack>> modifierByTag,
    required List<TagTrack> chartTracks,
    required int total,
    required Set<String> seedKeys,
  }) {
    if (total <= 0) return const [];
    final coreKeys = {
      for (final c in core) normalizeKey(c.track.artist, c.track.title)
    };
    final blocked = {...seedKeys, ...coreKeys};
    final seen = <String>{};

    // Modifier pool: round-robin by rank across tags.
    final modPool = <(TagTrack, String)>[]; // (track, tag)
    if (modifierByTag.isNotEmpty) {
      final tags = modifierByTag.keys.toList();
      final maxLen = modifierByTag.values
          .fold(0, (m, l) => l.length > m ? l.length : m);
      for (var rank = 0; rank < maxLen; rank++) {
        for (final tag in tags) {
          final list = modifierByTag[tag]!;
          if (rank >= list.length) continue;
          final t = list[rank];
          if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
          final key = normalizeKey(t.artist, t.title);
          if (blocked.contains(key) || !seen.add(key)) continue;
          modPool.add((t, tag));
        }
      }
    }

    // Fresh pool: chart order.
    final freshPool = <TagTrack>[];
    for (final t in chartTracks) {
      if (t.artist.trim().isEmpty || t.title.trim().isEmpty) continue;
      final key = normalizeKey(t.artist, t.title);
      if (blocked.contains(key) || !seen.add(key)) continue;
      freshPool.add(t);
    }

    // Quotas (spec §28): modifiers ~1/3, fresh ~1/5, combined ≤ 1/2.
    var modQuota = modifierByTag.isEmpty ? 0 : (total / 3).round();
    var freshQuota = chartTracks.isEmpty ? 0 : (total / 5).round();
    final cap = total ~/ 2;
    if (modQuota + freshQuota > cap) {
      freshQuota = freshQuota > cap - modQuota ? cap - modQuota : freshQuota;
      if (freshQuota < 0) freshQuota = 0;
      if (modQuota > cap) modQuota = cap;
    }

    // Desired takes, with backfill when a source runs dry.
    var mTake = modQuota < modPool.length ? modQuota : modPool.length;
    var fTake = freshQuota < freshPool.length ? freshQuota : freshPool.length;
    var cTake = total - mTake - fTake;
    if (cTake > core.length) cTake = core.length;
    var leftover = total - cTake - mTake - fTake;
    if (leftover > 0) {
      final mExtra = modPool.length - mTake;
      final addM = mExtra < leftover ? mExtra : leftover;
      mTake += addM;
      leftover -= addM;
    }
    if (leftover > 0) {
      final fExtra = freshPool.length - fTake;
      final addF = fExtra < leftover ? fExtra : leftover;
      fTake += addF;
      leftover -= addF;
    }
    if (leftover > 0) {
      final cExtra = core.length - cTake;
      final addC = cExtra < leftover ? cExtra : leftover;
      cTake += addC;
    }

    // Fair interleave by quota progress; priority core → modifier →
    // fresh breaks ties (including the opening slot).
    final result = <ScoredTrack>[];
    var ci = 0, mi = 0, fi = 0;
    var prevScore = core.isNotEmpty ? core.first.score : 1.0;
    double progress(int taken, int want) =>
        want <= 0 ? double.infinity : taken / want;
    while (result.length < total) {
      final canCore = ci < cTake;
      final canMod = mi < mTake;
      final canFresh = fi < fTake;
      if (!canCore && !canMod && !canFresh) break;
      var pick = -1; // 0 core, 1 modifier, 2 fresh
      var best = double.infinity;
      if (canCore) {
        final p = progress(ci, cTake);
        if (p < best) {
          best = p;
          pick = 0;
        }
      }
      if (canMod) {
        final p = progress(mi, mTake);
        if (p < best) {
          best = p;
          pick = 1;
        }
      }
      if (canFresh) {
        final p = progress(fi, fTake);
        if (p < best) {
          best = p;
          pick = 2;
        }
      }
      if (pick == 0) {
        final c = core[ci++];
        prevScore = c.score;
        result.add(c);
      } else if (pick == 1) {
        final (t, tag) = modPool[mi++];
        prevScore = prevScore * 0.99;
        result.add(ScoredTrack(
          track: Track(title: t.title, artist: t.artist),
          score: prevScore,
          reasons: ['Popular in $tag'],
        ));
      } else {
        final t = freshPool[fi++];
        prevScore = prevScore * 0.99;
        result.add(ScoredTrack(
          track: Track(title: t.title, artist: t.artist),
          score: prevScore,
          reasons: const ['Trending now'],
        ));
      }
    }
    return result;
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
  /// listeners), rank by listeners desc. With Fresh finds on, chart
  /// tracks are *injected* at the fresh quota via [blendWithInjections]
  /// (amended 2026-10-20, §28 — the old behavior hard-filtered the
  /// whole list down to chart-overlapping tracks only).
  static List<ScoredTrack> surpriseSongs({
    required Map<String, List<TagTrack>> topByTag,
    List<TagTrack> chartTracks = const [],
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
    final keys = best.keys.toList()
      ..sort((a, b) => best[b]!.listeners.compareTo(best[a]!.listeners));
    final base = [
      for (final k in keys)
        ScoredTrack(
          track: Track(title: best[k]!.title, artist: best[k]!.artist),
          score: best[k]!.listeners.toDouble(),
          reasons: ['Popular in ${tagOf[k]}'],
        )
    ];
    if (chartTracks.isEmpty) return base.take(count).toList();
    return blendWithInjections(
      core: base,
      modifierByTag: const {},
      chartTracks: chartTracks,
      total: count,
      seedKeys: const {},
    );
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
