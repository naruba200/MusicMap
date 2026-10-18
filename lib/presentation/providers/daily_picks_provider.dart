// Daily picks (FR-12b): a small song + album set regenerated once per day,
// seeded from the user's favorited artists via tag top tracks/albums
// (same engine family as Surprise me). Cached in Hive, date-keyed.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/lastfm/lastfm_client.dart';
import 'providers.dart';

class DailyPicks {
  final List<ScoredTrack> songs;
  final List<AlbumRec> albums;
  final DateTime generatedAt;

  const DailyPicks({
    required this.songs,
    required this.albums,
    required this.generatedAt,
  });

  Map<String, dynamic> toJson() => {
        'songs': [for (final s in songs) s.toJson()],
        'albums': [for (final a in albums) a.toJson()],
        'generatedAt': generatedAt.toIso8601String(),
      };

  factory DailyPicks.fromJson(Map<String, dynamic> json) => DailyPicks(
        songs: (json['songs'] as List?)
                ?.whereType<Map>()
                .map((m) => ScoredTrack.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        albums: (json['albums'] as List?)
                ?.whereType<Map>()
                .map((m) => AlbumRec.fromJson(m.cast<String, dynamic>()))
                .toList() ??
            const [],
        generatedAt:
            DateTime.tryParse(json['generatedAt'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
      );
}

String _todayKey() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-'
      '${n.day.toString().padLeft(2, '0')}';
}

class DailyPicksNotifier extends StateNotifier<AsyncValue<DailyPicks?>> {
  final Ref _ref;
  late final Box _box;
  bool _ready = false;

  DailyPicksNotifier(this._ref) : super(const AsyncValue.loading()) {
    _init();
  }

  Future<void> _init() async {
    _box = await Hive.openBox('daily_picks');
    _ready = true;
    await load();
  }

  /// Load today's cached picks, or generate if stale/missing.
  Future<void> load() async {
    if (!_ready) return;
    final cached = _box.get('picks');
    if (cached is Map) {
      final map = cached.cast<String, dynamic>();
      if (map['date'] == _todayKey()) {
        try {
          state = AsyncValue.data(
              DailyPicks.fromJson((map['picks'] as Map).cast<String, dynamic>()));
          return;
        } catch (_) {
          // fall through to regenerate
        }
      }
    }
    await refresh();
  }

  /// Force regeneration (refresh button): replaces cache, resets the 24h timer.
  Future<void> refresh() async {
    if (!_ready) return;
    state = const AsyncValue.loading();
    try {
      final picks = await _generate();
      if (picks != null) {
        await _box.put('picks', {'date': _todayKey(), 'picks': picks.toJson()});
      }
      state = AsyncValue.data(picks);
    } catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }

  Future<DailyPicks?> _generate() async {
    if (lastFmApiKey == 'YOUR_LASTFM_API_KEY' || lastFmApiKey.trim().isEmpty) {
      throw Exception('Add your Last.fm API key to generate daily picks.');
    }
    final favRepo = _ref.read(favoritesRepositoryProvider);
    final artists = favRepo.favoritedArtists();
    if (artists.isEmpty) return null; // empty state: heart some songs first
    final lfm = LastFmClient(dio: _ref.read(dioProvider), apiKey: lastFmApiKey);

    final seeds = artists.take(5).toList();
    final songsByArtist = <String, List<TagTrack>>{};
    final albumsByArtist = <String, List<TagAlbum>>{};
    for (final artist in seeds) {
      try {
        songsByArtist[artist] = await lfm.getTagTopTracks(artist, limit: 10);
      } catch (_) {
        songsByArtist[artist] = const [];
      }
      try {
        albumsByArtist[artist] = await lfm.getTagTopAlbums(artist, limit: 10);
      } catch (_) {
        albumsByArtist[artist] = const [];
      }
    }
    var songs = RecommendationEngine.surpriseSongs(
      topByTag: songsByArtist,
      count: 10,
    );
    // Don't recommend songs the user already hearted.
    songs = songs
        .where((s) => !favRepo.isFavorite(s.track.artist, s.track.title))
        .toList();
    final albums = RecommendationEngine.surpriseAlbums(
      topByTag: albumsByArtist,
      count: 5,
    );
    return DailyPicks(
        songs: songs, albums: albums, generatedAt: DateTime.now());
  }
}

final dailyPicksProvider =
    StateNotifierProvider<DailyPicksNotifier, AsyncValue<DailyPicks?>>(
  (ref) => DailyPicksNotifier(ref),
);
