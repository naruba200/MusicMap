// M2 generation orchestration: Last.fm fan-out with progress, engine
// scoring, Surprise-me mode, and live related genres (spec FR-04e…FR-11,
// FR-19). The engine itself stays pure Dart in data/engine.

import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/fallback/fallback_sources.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import '../../data/repositories/history_repository.dart';
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

  Map<String, dynamic> toJson() => {
        'songs': [for (final s in songs) s.toJson()],
        'albums': [for (final a in albums) a.toJson()],
        'seedName': seedName,
        'isSurprise': isSurprise,
        'seedCount': seedCount,
        'skippedSeeds': skippedSeeds,
      };

  factory GenerationResult.fromJson(Map<String, dynamic> json) =>
      GenerationResult(
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
        seedName: json['seedName'] as String? ?? 'Recommendations',
        isSurprise: json['isSurprise'] as bool? ?? false,
        seedCount: (json['seedCount'] as num?)?.toInt() ?? 0,
        skippedSeeds: (json['skippedSeeds'] as num?)?.toInt() ?? 0,
      );
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
    StateNotifierProvider<GenerationNotifier, GenerationState>((ref) =>
        GenerationNotifier(
            ref.watch(dioProvider), ref.watch(historyRepositoryProvider)));

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
  final HistoryRepository _history;

  /// Cross-source fallbacks use their own plain Dio (see
  /// FallbackSources): a sinkholed Deezer host must fail fast instead
  /// of burning the shared Dio's retries per failed seed.
  late final FallbackSources _fallbacks = FallbackSources();
  bool _cancelled = false;

  GenerationNotifier(this._dio, this._history) : super(GenerationState.idle);

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
    String? seedPlaylistId,
    String? seedPlatformId,
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

      // 1. Similar tracks per seed (FR-06), with the error-6
      // fallback chain (see resolveSeedSimilars): a single track
      // that Last.fm does not know no longer kills the run — it is
      // skipped (or replaced by an artist / cross-source fallback)
      // and the other seeds carry on. Only a non-6 error (network,
      // key, rate limit) still aborts, via resolveSeedSimilars'
      // rethrow, caught by the outer LastFmException handler.
      final similarBySeed = <int, List<SimilarTrack>>{};
      final fallbackBySeed = <int, List<SimilarTrack>>{};
      final fallbackReasonBySeed = <int, String>{};
      var skipped = 0;
      for (var i = 0; i < selection.seeds.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Finding similar tracks', i, selection.seeds.length);
        final seed = selection.seeds[i];
        final resolved = await resolveSeedSimilars(
          artist: RecommendationEngine.primaryArtist(seed.artist),
          title: seed.title,
          getSimilar: (a, t) => _lfm.getSimilarTracks(a, t),
          getArtistTopTracks: (a, limit) =>
              _lfm.getArtistTopTracks(a, limit: limit),
          getSimilarArtists: (a) => _lfm.getSimilarArtists(a),
          deezerArtistTracks: _fallbacks.deezerArtistTracks,
          itunesArtistTracks: _fallbacks.itunesArtistTracks,
        );
        if (resolved.tracks.isEmpty) {
          skipped++;
        } else if (resolved.isFallback) {
          fallbackBySeed[i] = resolved.tracks;
          fallbackReasonBySeed[i] = resolved.fallbackReason!;
        } else {
          similarBySeed[i] = resolved.tracks;
        }
      }
      _setProgress('Finding similar tracks', selection.seeds.length,
          selection.seeds.length);
      if (similarBySeed.isEmpty && fallbackBySeed.isEmpty) {
        throw GenerationException(
          'None of the seed tracks had similar-track data on Last.fm. '
          '$skipped of ${selection.seeds.length} seeds were not found, '
          'even after trying cleaned titles, artist fallbacks and other '
          'sources. Try a larger or more mainstream playlist, or '
          'Surprise Me with tags instead.',
          retryable: false,
        );
      }

      final scored = RecommendationEngine.scoreCandidates(
        seeds: selection.seeds,
        similarBySeed: similarBySeed,
        fallbackBySeed: fallbackBySeed,
        fallbackReasonBySeed: fallbackReasonBySeed,
      );

      // 2. Discovery modifiers (FR-07b, §30 seed mode): fetch each tag's
      // top tracks, take tag seeds round-robin, expand them via
      // track.getSimilar and score them into a tag pool — the picked
      // tags act as seeds (Chosic-style), not as a post-hoc blend.
      final tags = _tagsFor(settings);
      var modifierPool = const <ScoredTrack>[];
      if (tags.isNotEmpty) {
        final topByTag = <String, List<TagTrack>>{};
        for (var i = 0; i < tags.length; i++) {
          if (_cancelled) return _abort();
          _setProgress('Reading your tags', i, tags.length);
          topByTag[tags[i]] = await _lfm.getTagTopTracks(tags[i]);
        }
        final tagSelection = RecommendationEngine.selectTagSeeds(topByTag);
        final similarByTagSeed = <int, List<SimilarTrack>>{};
        for (var i = 0; i < tagSelection.seeds.length; i++) {
          if (_cancelled) return _abort();
          _setProgress('Expanding your tags', i, tagSelection.seeds.length);
          final seed = tagSelection.seeds[i];
          // Tag seeds get the per-seed skip + cleaned-title retry
          // only: the tag seed tracks themselves already head the
          // pool, so a failed expansion just loses its similars,
          // and the full cross-source chain is not worth the calls
          // here. Non-6 errors still rethrow and abort.
          final sims = await _similarOrCleaned(
            RecommendationEngine.primaryArtist(seed.artist),
            seed.title,
          );
          if (sims.isNotEmpty) similarByTagSeed[i] = sims;
        }
        modifierPool = RecommendationEngine.buildTagPool(
          tagSeeds: tagSelection.seeds,
          similarBySeed: similarByTagSeed,
          tagOfKey: tagSelection.tagOfKey,
        );
      }

      // 3. Fresh finds (FR-07c): the chart list, also injected by quota.
      var chartTracks = const <TagTrack>[];
      if (settings.freshFinds) {
        if (_cancelled) return _abort();
        _setProgress('Checking trending tracks', 0, 1);
        chartTracks = await _lfm.getChartTopTracks();
      }

      // 4. Blend the seed-similar core with the injections.
      final seedKeys = {
        for (final t in tracks)
          RecommendationEngine.normalizeKey(t.artist, t.title)
      };
      final songs = RecommendationEngine.blendWithInjections(
        core: scored,
        modifierPool: modifierPool,
        chartTracks: chartTracks,
        total: settings.songCount,
        seedKeys: seedKeys,
      );

      // 5. Album enrichment (FR-11): track.getSimilar carries no album
      // data, so without this the Albums tab would always be empty.
      // Look it up for the top songs (capped) before deriving albums.
      final enriched = <ScoredTrack>[];
      final enrichN = songs.length < 50 ? songs.length : 50;
      for (var i = 0; i < songs.length; i++) {
        if (_cancelled) return _abort();
        final st = songs[i];
        if (i < enrichN) {
          _setProgress('Looking up album info', i, enrichN);
          try {
            final info = await _lfm.getTrackInfo(
              RecommendationEngine.primaryArtist(st.track.artist),
              st.track.title,
            );
            final album = info.album?.trim();
            enriched.add(album == null || album.isEmpty
                ? st
                : ScoredTrack(
                    track: Track(
                      title: st.track.title,
                      artist: st.track.artist,
                      album: album,
                      imageUrl: info.imageUrl ?? st.track.imageUrl,
                      durationMs: st.track.durationMs,
                      platformTrackId: st.track.platformTrackId,
                    ),
                    score: st.score,
                    reasons: st.reasons,
                  ));
          } catch (_) {
            enriched.add(st); // one bad lookup must not kill the run
          }
        } else {
          enriched.add(st);
        }
      }
      _setProgress('Looking up album info', enrichN, enrichN);

      final albums =
          RecommendationEngine.deriveAlbums(enriched, settings.albumCount);
      await _finishRun(
        result: GenerationResult(
          songs: enriched,
          albums: albums,
          seedName: seedName,
          isSurprise: false,
          seedCount: selection.seeds.length,
          skippedSeeds: skipped,
        ),
        seedPlaylistId: seedPlaylistId,
        seedPlatformId: seedPlatformId,
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
      final random = Random();
      var tags = _tagsFor(settings);
      if (tags.isEmpty) tags = _randomDefaultTags(random);

      // Songs: tag top tracks merged + ranked (FR-19).
      final topByTag = <String, List<TagTrack>>{};
      for (var i = 0; i < tags.length; i++) {
        if (_cancelled) return _abort();
        _setProgress('Exploring ${tags[i]}', i, tags.length);
        topByTag[tags[i]] = await _lfm.getTagTopTracks(tags[i]);
      }
      var chartTracks = const <TagTrack>[];
      if (settings.freshFinds) {
        if (_cancelled) return _abort();
        _setProgress('Checking trending tracks', 0, 1);
        chartTracks = await _lfm.getChartTopTracks();
      }
      final songs = RecommendationEngine.surpriseSongs(
        topByTag: topByTag,
        chartTracks: chartTracks,
        count: settings.songCount,
        random: random,
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
        random: random,
      );

      await _finishRun(
        result: GenerationResult(
          songs: songs,
          albums: albums,
          seedName: 'Surprise picks',
          isSurprise: true,
          seedCount: 0,
          skippedSeeds: 0,
        ),
        seedPlaylistId: null,
        seedPlatformId: null,
      );
    } on GenerationException catch (e) {
      state = GenerationState(error: e.message, canRetry: e.retryable);
    } on LastFmException catch (e) {
      state = GenerationState(error: e.message, canRetry: true);
    } catch (e) {
      state = GenerationState(error: 'Something went wrong: $e', canRetry: true);
    }
  }

  /// One track.getSimilar attempt plus, on error 6 or an empty
  /// result, one cleaned-title retry. Returns [] when both miss.
  /// Non-6 LastFmExceptions (and transport errors) are rethrown.
  Future<List<SimilarTrack>> _similarOrCleaned(
      String artist, String title) async {
    try {
      final sims = await _lfm.getSimilarTracks(artist, title);
      if (sims.isNotEmpty) return sims;
    } on LastFmException catch (e) {
      if (!e.isTrackNotFound) rethrow;
    }
    final cleaned = RecommendationEngine.cleanTrackTitle(title);
    if (cleaned == title) return const [];
    try {
      return await _lfm.getSimilarTracks(artist, cleaned);
    } on LastFmException catch (e) {
      if (!e.isTrackNotFound) rethrow;
      return const [];
    }
  }

  List<String> _tagsFor(DiscoverySettings settings) => [
        for (final m in settings.moods) tagForLabel(m),
        for (final g in settings.genres) tagForLabel(g),
      ];

  /// 3 random distinct tags when the user picked none (FR-19).
  /// Random per run, so Surprise differs each time — the old day-based
  /// rotation gave the same 3 tags all day, which was a second source
  /// of identical Surprise results.
  List<String> _randomDefaultTags(Random random) {
    const pool = ['pop', 'rock', 'electronic', 'hip-hop', 'j-pop', 'anime'];
    final shuffled = [...pool]..shuffle(random);
    return shuffled.take(3).toList();
  }

  /// Persist a completed run to history (FR-13), then publish the result.
  /// History failures never fail the run itself.
  Future<void> _finishRun({
    required GenerationResult result,
    String? seedPlaylistId,
    String? seedPlatformId,
  }) async {
    final now = DateTime.now();
    try {
      await _history.add(HistoryRun(
        id: now.microsecondsSinceEpoch.toString(),
        timestamp: now,
        seedName: result.seedName,
        seedPlaylistId: seedPlaylistId,
        seedPlatformId: seedPlatformId,
        isSurprise: result.isSurprise,
        resultJson: result.toJson(),
      ));
    } catch (_) {
      // history is best-effort
    }
    state = GenerationState(result: result);
  }

  void _abort() {
    _cancelled = false;
    state = GenerationState.idle;
  }
}

