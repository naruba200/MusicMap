// M2 generation orchestration: Last.fm fan-out with progress, engine
// scoring, Surprise-me mode, and live related genres (spec FR-04e…FR-11,
// FR-19). The engine itself stays pure Dart in data/engine.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import 'providers.dart';

/// Maps a mood/genre chip label to a Last.fm tag.
String tagForLabel(String label) =>
    genreTagMapping[label] ?? label.toLowerCase();

/// User-facing generation error with a retry hint.
class GenerationException implements Exception {
  final String message;
  final bool retryable;
  const GenerationException(this.message, {this.retryable = true});
  @override
  String toString() => message;
}

class GenerationProgress {
  final String phase;
  final int done;
  final int total;

  const GenerationProgress({
    required this.phase,
    required this.done,
    required this.total,
  });

  double get fraction =>
      total <= 0 ? 0 : (done / total).clamp(0.0, 1.0).toDouble();
}

class GenerationResult {
  final List<ScoredTrack> songs;
  final List<AlbumRec> albums;
  final String seedName;
  final bool isSurprise;
  final int seedCount;
  final int skippedSeeds;

  const GenerationResult({
    required this.songs,
    required this.albums,
    required this.seedName,
    required this.isSurprise,
    required this.seedCount,
    required this.skippedSeeds,
  });
}

class GenerationState {
  final bool running;
  final GenerationProgress? progress;
  final GenerationResult? result;
  final String? error;
  final bool canRetry;

  const GenerationState({
    this.running = false,
    this.progress,
    this.result,
    this.error,
    this.canRetry = false,
  });

  GenerationState copyWith({
    bool? running,
    GenerationProgress? progress,
    GenerationResult? result,
    String? error,
    bool? canRetry,
  }) =>
      GenerationState(
        running: running ?? this.running,
        progress: progress ?? this.progress,
        result: result ?? this.result,
        error: error ?? this.error,
        canRetry: canRetry ?? this.canRetry,
      );

  static const idle = GenerationState();
}

final generationProvider =
    StateNotifierProvider<GenerationNotifier, GenerationState>(
        (ref) => GenerationNotifier(ref.watch(dioProvider)));

/// Related genres for a selected genre chip, live via Last.fm tag.getSimilar
/// with the static fallback map on failure. Cached per genre for the session.
final relatedGenresProvider =
    FutureProvider.family<List<String>, String>((ref, genre) async {
  final client =
      LastFmClient(dio: ref.watch(dioProvider), apiKey: lastFmApiKey);
  try {
    final tags = await client.getSimilarTags(tagForLabel(genre));
    final cleaned = tags
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .take(6)
        .map(_displayTag)
        .toList();
    if (cleaned.isNotEmpty) return cleaned;
  } catch (_) {
    // Fall through to the static map.
  }
  return staticRelatedGenres[genre] ?? const [];
});

String _displayTag(String tag) =>
    tag.isEmpty ? tag : tag[0].toUpperCase() + tag.substring(1);

class GenerationNotifier extends StateNotifier<GenerationState> {
  final Dio _dio;
  bool _cancelled = false;

  GenerationNotifier(this._dio) : super(GenerationState.idle);

  LastFmClient get _lfm => LastFmClient(dio: _dio, apiKey: lastFmApiKey);

  void _requireKey() {
    if (lastFmApiKey == 'YOUR_LASTFM_API_KEY' || lastFmApiKey.trim().isEmpty) {
      throw const GenerationException(
        'Add your free Last.fm API key to lastFmApiKey in '
        'lib/core/constants.dart (get one at last.fm/api).',
        retryable: false,
      );
    }
  }

  void _setProgress(String phase, int done, int total) {
    state = state.copyWith(
        progress: GenerationProgress(phase: phase, done: done, total: total));
  }

  void cancel() {
    _cancelled = true;
  }

  void reset() {
    _cancelled = false;
    state = GenerationState.idle;
  }

  /// Playlist-seeded run (FR-05…FR-09, FR-11).
  Future<void> generateFromPlaylist({
    required String seedName,
    required List<Track> tracks,
    required DiscoverySettings settings,
  }) async {
    _cancelled = false;
    state = const GenerationState(running: true);
    try {
      _requireKey();
      final selection = RecommendationEngine.selectSeeds(tracks);
      if (!selection.meetsMinimum) {
        throw GenerationException(
          'Need at least $minUsableTracks usable tracks — '
          'this playlist has ${selection.usableCount}.',
          retryable: false,
        );
      }

      // 1. Similar tracks per seed (FR-06).
      final similarBySeed = <int, List<SimilarTrack>>{};
      var skipped = 0;
      for (var i = 0; i < selection.seeds.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Finding similar tracks', i, selection.seeds.length);
        final seed = selection.seeds[i];
        final sims = await _lfm.getSimilarTracks(
          RecommendationEngine.primaryArtist(seed.artist),
          seed.title,
        );
        if (sims.isEmpty) {
          skipped++;
        } else {
          similarBySeed[i] = sims;
        }
      }
      _setProgress('Finding similar tracks', selection.seeds.length,
          selection.seeds.length);
      if (similarBySeed.isEmpty) {
        throw const GenerationException(
          'None of the seed tracks had similar-track data on Last.fm. '
          'Try a larger or more mainstream playlist.',
          retryable: false,
        );
      }

      var scored = RecommendationEngine.scoreCandidates(
        seeds: selection.seeds,
        similarBySeed: similarBySeed,
      );

      // 2. Discovery-modifier blending (FR-07b).
      final tags = _tagsFor(settings);
      final modifierSets = <Set<String>>[];
      for (var i = 0; i < tags.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Applying discovery filters', i, tags.length);
        final top = await _lfm.getTagTopTracks(tags[i]);
        modifierSets.add({
          for (final t in top)
            RecommendationEngine.normalizeKey(t.artist, t.title)
        });
      }
      scored = RecommendationEngine.applyModifierBoost(scored, modifierSets);

      // 3. Fresh-finds boost (FR-07c).
      if (settings.freshFinds) {
        if (_cancelled) return _abort();
        _setProgress('Checking trending tracks', 0, 1);
        final chart = await _lfm.getChartTopTracks();
        scored = RecommendationEngine.applyFreshBoost(scored, {
          for (final t in chart)
            RecommendationEngine.normalizeKey(t.artist, t.title)
        });
      }

      final songs = RecommendationEngine.topN(scored, settings.songCount);
      final albums =
          RecommendationEngine.deriveAlbums(songs, settings.albumCount);
      state = GenerationState(
        result: GenerationResult(
          songs: songs,
          albums: albums,
          seedName: seedName,
          isSurprise: false,
          seedCount: selection.seeds.length,
          skippedSeeds: skipped,
        ),
      );
    } on GenerationException catch (e) {
      state = GenerationState(error: e.message, canRetry: e.retryable);
    } on LastFmException catch (e) {
      state = GenerationState(error: e.message, canRetry: true);
    } catch (e) {
      state = GenerationState(error: 'Something went wrong: $e', canRetry: true);
    }
  }

  /// No-seed discovery (FR-19).
  Future<void> surprise({required DiscoverySettings settings}) async {
    _cancelled = false;
    state = const GenerationState(running: true);
    try {
      _requireKey();
      var tags = _tagsFor(settings);
      if (tags.isEmpty) tags = _rotatingDefaultTags();

      // Songs: tag top tracks merged + ranked (FR-19).
      final topByTag = <String, List<TagTrack>>{};
      for (var i = 0; i < tags.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Exploring ${tags[i]}', i, tags.length);
        topByTag[tags[i]] = await _lfm.getTagTopTracks(tags[i]);
      }
      Set<String>? trending;
      if (settings.freshFinds) {
        if (_cancelled) return _abort();
        _setProgress('Checking trending tracks', 0, 1);
        final chart = await _lfm.getChartTopTracks();
        trending = {
          for (final t in chart)
            RecommendationEngine.normalizeKey(t.artist, t.title)
        };
      }
      final songs = RecommendationEngine.surpriseSongs(
        topByTag: topByTag,
        trendingKeys: trending,
        count: settings.songCount,
      );

      // Albums: tag top albums (FR-19).
      final albumsByTag = <String, List<TagAlbum>>{};
      for (var i = 0; i < tags.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Finding albums', i, tags.length);
        albumsByTag[tags[i]] = await _lfm.getTagTopAlbums(tags[i]);
      }
      final albums = RecommendationEngine.surpriseAlbums(
        topByTag: albumsByTag,
        count: settings.albumCount,
      );

      state = GenerationState(
        result: GenerationResult(
          songs: songs,
          albums: albums,
          seedName: 'Surprise picks',
          isSurprise: true,
          seedCount: 0,
          skippedSeeds: 0,
        ),
      );
    } on GenerationException catch (e) {
      state = GenerationState(error: e.message, canRetry: e.retryable);
    } on LastFmException catch (e) {
      state = GenerationState(error: e.message, canRetry: true);
    } catch (e) {
      state = GenerationState(error: 'Something went wrong: $e', canRetry: true);
    }
  }

  List<String> _tagsFor(DiscoverySettings settings) => [
        for (final m in settings.moods) tagForLabel(m),
        for (final g in settings.genres) tagForLabel(g),
      ];

  /// 3 rotating tags when the user picked none (FR-19).
  List<String> _rotatingDefaultTags() {
    const pool = ['pop', 'rock', 'electronic', 'hip-hop', 'j-pop', 'anime'];
    final start = DateTime.now().day % pool.length;
    return [for (var i = 0; i < 3; i++) pool[(start + i) % pool.length]];
  }

  void _abort() {
    _cancelled = false;
    state = GenerationState.idle;
  }
}
