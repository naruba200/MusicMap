// M2 generation orchestration: Last.fm fan-out with progress, engine
// scoring, Surprise-me mode, and live related genres (spec FR-04e…FR-11,
// FR-19). The engine itself stays pure Dart in data/engine.

import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/enrichment/discogs_client.dart';
import '../../data/enrichment/theaudiodb_client.dart';
import '../../data/enrichment/enrichment_cache.dart';
import '../../data/enrichment/enrichment_models.dart';
import '../../data/enrichment/musicbrainz_client.dart';
import '../../data/discover/audius_client.dart';
import '../../data/discover/jamendo_client.dart';
import '../../data/export/visionos_player_client.dart';
import '../../data/export/youtube_export.dart';
import '../../data/fallback/fallback_sources.dart';
import '../../data/fallback/listenbrainz_client.dart';
import '../../data/fullsong/full_song_resolver.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import '../../data/repositories/favorites_repository.dart';
import '../../data/repositories/history_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/spotify/spotify_client.dart';
import '../../data/spotify/spotify_session.dart';
import 'audio_backend.dart';
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
  /// Set when the final song list is shorter than requested because
  /// the sources ran dry (Phase 1 sparse generation). Null when the
  /// list filled up, and always null for Surprise runs. Shown as an
  /// explanation banner on the results screen instead of silently
  /// showing few songs.
  final String? sparseExplanation;
  /// Post-score MusicBrainz annotations, keyed by normalized key.
  /// Never affects scores or order.
  final Map<String, TrackEnrichment> enrichments;
  /// Post-score Discogs annotations (Phase 2, step 2), keyed by
  /// artist|album key. Never affects scores or order.
  final Map<String, AlbumEnrichment> albumEnrichments;

  const GenerationResult({
    required this.songs,
    required this.albums,
    required this.seedName,
    required this.isSurprise,
    required this.seedCount,
    required this.skippedSeeds,
    this.sparseExplanation,
    this.enrichments = const {},
    this.albumEnrichments = const {},
  });

  Map<String, dynamic> toJson() => {
        'songs': [for (final s in songs) s.toJson()],
        'albums': [for (final a in albums) a.toJson()],
        'seedName': seedName,
        'isSurprise': isSurprise,
        'seedCount': seedCount,
        'skippedSeeds': skippedSeeds,
        if (sparseExplanation != null)
          'sparseExplanation': sparseExplanation,
        if (enrichments.isNotEmpty)
          'enrichments': {
            for (final e in enrichments.entries) e.key: e.value.toJson()
          },
        if (albumEnrichments.isNotEmpty)
          'albumEnrichments': {
            for (final e in albumEnrichments.entries)
              e.key: e.value.toJson()
          },
      };

  factory GenerationResult.fromJson(Map<String, dynamic> json) =>
      GenerationResult(
        songs: (json['songs'] as List?)
                ?.whereType<Map>()
                .map((m) => ScoredTrack.fromJson(m.cast<String, dynamic>()))
                .toList() ?? const [],
        albums: (json['albums'] as List?)
                ?.whereType<Map>()
                .map((m) => AlbumRec.fromJson(m.cast<String, dynamic>()))
                .toList() ?? const [],
        seedName: json['seedName'] as String? ?? 'Recommendations',
        isSurprise: json['isSurprise'] as bool? ?? false,
        seedCount: (json['seedCount'] as num?)?.toInt() ?? 0,
        skippedSeeds: (json['skippedSeeds'] as num?)?.toInt() ?? 0,
        sparseExplanation: json['sparseExplanation'] as String?,
        enrichments: ((json['enrichments'] as Map?) ?? {}).map(
          (k, v) => MapEntry(
              k.toString(),
              TrackEnrichment.fromJson(
                  (v as Map).cast<String, dynamic>())),
        ),
        albumEnrichments: ((json['albumEnrichments'] as Map?) ?? {})
            .map(
          (k, v) => MapEntry(
              k.toString(),
              AlbumEnrichment.fromJson(
                  (v as Map).cast<String, dynamic>())),
        ),
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
            ref.watch(dioProvider),
            ref.watch(historyRepositoryProvider),
            ref.watch(favoritesRepositoryProvider),
            ref.watch(settingsRepositoryProvider),
            // ref.read, not ref.watch: watching the version would
            // recreate this notifier (and wipe its state) on every
            // history bump, including the bump _finishRun itself does.
            ref.read(historyVersionProvider.notifier)));

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

/// Runs [fn] over [items] in batches of [batchSize] in flight at
/// once, preserving input order in the returned list. Used to bound
/// Last.fm fan-out (batchSize 5 in generation) instead of
/// one-at-a-time loops, without unbounded concurrency. [onProgress]
/// is called after each batch; [shouldStop] is checked between
/// batches and, when true, stops early and returns the results
/// gathered so far (the caller must then check why it stopped).
Future<List<R>> mapBatched<T, R>(
  List<T> items,
  int batchSize,
  Future<R> Function(int index, T item) fn, {
  void Function(int done, int total)? onProgress,
  bool Function()? shouldStop,
}) async {
  final results = <R>[];
  for (var start = 0; start < items.length; start += batchSize) {
    final end =
        start + batchSize > items.length ? items.length : start + batchSize;
    final batch = await Future.wait(
      [for (var i = start; i < end; i++) fn(i, items[i])],
    );
    results.addAll(batch);
    onProgress?.call(end, items.length);
    if (shouldStop != null && shouldStop()) break;
  }
  return results;
}

class GenerationNotifier extends StateNotifier<GenerationState> {
  final Dio _dio;
  final HistoryRepository _history;
  final FavoritesRepository _favorites;

  /// Optional: only used for the ListenBrainz username (Phase 3).
  /// Null in older constructions — the layer is then inactive.
  final SettingsRepository? _settingsRepository;

  /// Cross-source fallbacks use their own plain Dio (see
  /// FallbackSources): a sinkholed Deezer host must fail fast instead
  /// of burning the shared Dio's retries per failed seed.
  late final FallbackSources _fallbacks = FallbackSources();

  /// MusicBrainz enrichment: plain Dio, 1 req/s, never aborts.
  late final MusicBrainzClient _musicBrainz = MusicBrainzClient();

  /// Discogs enrichment: unauthenticated known-release fetches.
  /// Pass a user-supplied token here only if the user provides one
  /// (never commit a real token); null keeps token-free resolution.
  late final DiscogsClient _discogs = DiscogsClient();

  /// TheAudioDB enrichment: documented public test key by default.
  /// Replace with a personal key only if the user supplies one
  /// (never commit a personal key).
  late final TheAudioDBClient _theAudioDb = TheAudioDBClient();

  /// ListenBrainz (Phase 3): plain Dio via its own client, one
  /// capped call per generation, cached 7 days. Never aborts a run.
  late final ListenBrainzClient _listenBrainz = ListenBrainzClient();
  bool _cancelled = false;

  /// Monotonic run id: background enrichment from an older run must
  /// never publish over a newer run's state or history. Incremented
  /// at the start of every generate/surprise run; background steps
  /// check [_isStale] before each publish.
  int _generationRun = 0;

  /// Shared history-version controller (see historyVersionProvider
  /// in providers.dart). Optional so older constructions still work;
  /// bumped in [_finishRun] after a history write succeeds.
  final StateController<int>? _historyVersion;

  GenerationNotifier(this._dio, this._history, this._favorites,
      [this._settingsRepository, this._historyVersion])
      : super(GenerationState.idle);

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

  /// Build a "learned" Fresh Finds pool from the user's favorited artists.
  /// For each favorited artist (capped at 8), fetch their top tracks on
  /// Last.fm. The more favorites you have, the larger this pool relative
  /// to the raw global chart — a light learning signal. Falls back to the
  /// global chart when there are no favorites yet.
  Future<List<TagTrack>> _buildFreshPool({
    required bool freshFinds,
  }) async {
    if (!freshFinds) return const [];

    final chartTracks = await _lfm.getChartTopTracks();
    final favArtists = _favorites.favoritedArtists();
    if (favArtists.isEmpty) return chartTracks;

    final learned = <TagTrack>[];
    final seen = <String>{};
    for (final artist in favArtists.take(8)) {
      try {
        final topTracks = await _lfm.getArtistTopTracks(artist, limit: 10);
        for (final t in topTracks) {
          final key =
              RecommendationEngine.normalizeKey(t.artist, t.title);
          if (seen.add(key)) {
            learned.add(TagTrack(
              artist: t.artist,
              title: t.title,
              listeners: t.listeners,
            ));
          }
        }
      } catch (_) {
        // one bad artist must not kill fresh finds
      }
    }

    return mergeLearnedFreshPool(learned: learned, chart: chartTracks);
  }

  /// Pure merge of learned (favorited-artist) top tracks ahead of the
  /// global chart, deduped by normalized key. Extracted from
  /// [_buildFreshPool] so the favorites -> Fresh Finds path is
  /// unit-testable without Last.fm; behaviour is unchanged.
  static List<TagTrack> mergeLearnedFreshPool({
    required List<TagTrack> learned,
    required List<TagTrack> chart,
  }) {
    if (learned.isEmpty) return chart;
    final merged = <TagTrack>[...learned];
    final seen = <String>{
      for (final t in learned)
        RecommendationEngine.normalizeKey(t.artist, t.title),
    };
    for (final t in chart) {
      final key = RecommendationEngine.normalizeKey(t.artist, t.title);
      if (seen.add(key)) merged.add(t);
    }
    return merged;
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
    final runId = ++_generationRun;
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

      // 1. Similar tracks per seed (FR-06). All no-auth sources
      // (Last.fm, Deezer, iTunes) run concurrently per seed; Last.fm
      // similars are weighted at 1.0, Deezer/iTunes/artist-top at 0.4.
      final similarBySeed = <int, List<SimilarTrack>>{};
      final fallbackBySeed = <int, List<SimilarTrack>>{};
      final fallbackReasonBySeed = <int, String>{};
      // NOTE (full-song pivot): the seed resolution still returns
      // iTunes/Deezer preview URLs alongside the fallback tracks
      // (same responses, no extra calls), but they are NOT attached
      // to generated tracks anymore — playback is full-song only and
      // never reads track.previewUrl.
      var skipped = 0;
      // Batched (5 in flight) instead of one seed at a time: the
      // sources within one seed already run concurrently, but seeds
      // never overlapped before. Merge stays sequential and in seed
      // order, so scoring is unchanged.
      final resolvedBySeed = await mapBatched(
        selection.seeds,
        5,
        (i, seed) => resolveSeedSimilars(
          artist: RecommendationEngine.primaryArtist(seed.artist),
          title: seed.title,
          getSimilar: (a, t) => _lfm.getSimilarTracks(a, t),
          getArtistTopTracks: (a, limit) =>
              _lfm.getArtistTopTracks(a, limit: limit),
          getSimilarArtists: (a) => _lfm.getSimilarArtists(a),
          deezerArtistTracks: _fallbacks.deezerArtistTracks,
          deezerArtistTracksWithPreviews:
              _fallbacks.deezerArtistTracksWithPreviews,
          itunesArtistTracksWithPreviews:
              _fallbacks.itunesArtistTracksWithPreviews,
          // Title-only last resort (Phase 1 sparse generation).
          searchTracksByTitle: (t) => _lfm.searchTracks(t),
        ),
        shouldStop: () => _cancelled,
        onProgress: (done, total) =>
            _setProgress('Finding similar tracks', done, total),
      );
      if (_cancelled) return _abort();
      for (var i = 0; i < selection.seeds.length; i++) {
        final seed = selection.seeds[i];
        final resolved = resolvedBySeed[i];
        if (resolved.isEmpty) {
          skipped++;
        } else {
          if (resolved.hasSimilars) {
            similarBySeed[i] = resolved.similars;
          }
          if (resolved.hasFallbacks) {
            fallbackBySeed[i] = resolved.fallbacks;
            fallbackReasonBySeed[i] =
                resolved.fallbackReason ??
                'More from ${RecommendationEngine.primaryArtist(seed.artist)}';
          }
          // iTunes/Deezer preview URLs that used to ride along here
          // are deliberately dropped (see above): playback never
          // reads track.previewUrl anymore.
        }
      }
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

      var scored = RecommendationEngine.scoreCandidates(
        seeds: selection.seeds,
        similarBySeed: similarBySeed,
        fallbackBySeed: fallbackBySeed,
        fallbackReasonBySeed: fallbackReasonBySeed,
      );

      // 1a. ListenBrainz (Phase 3): optional username layer, one
      // capped call per generation, cached 7 days. Dormant when no
      // username is set; failures return [] and never abort. Merged
      // like the 1b/1c expansions: original scores kept, LB tracks
      // added at 0.4 weight with reason "From ListenBrainz".
      final lbUsername = _settingsRepository?.listenBrainzUsername;
      if (lbUsername != null && !_cancelled) {
        _setProgress('Checking ListenBrainz', 0, 1);
        final lbTracks = await _listenBrainzTracks(lbUsername);
        if (lbTracks.isNotEmpty) {
          final lbScored = RecommendationEngine.scoreCandidates(
            seeds: selection.seeds,
            similarBySeed: const {},
            fallbackBySeed: {0: lbTracks},
            fallbackReasonBySeed: {0: 'From ListenBrainz'},
          );
          final existingKeys = {
            for (final s in scored)
              RecommendationEngine.normalizeKey(
                  s.track.artist, s.track.title)
          };
          final merged = <ScoredTrack>[];
          merged.addAll(scored);
          for (final e in lbScored) {
            final key = RecommendationEngine.normalizeKey(
                e.track.artist, e.track.title);
            if (!existingKeys.contains(key)) {
              merged.add(e);
              existingKeys.add(key);
            }
          }
          merged.sort((a, b) => b.score.compareTo(a.score));
          scored = merged;
        }
      }

      // 1b. Aggressive expansion (fixes sparse results): if the core pool
      // is smaller than the requested count, query each seed artist's own
      // top tracks on Last.fm and add them as additional fallback-weighted
      // candidates. This guarantees the pool has enough material to fill
      // the requested song count even when Last.fm doesn't know most
      // seed tracks.
      if (scored.length < settings.songCount) {
        if (_cancelled) return _abort();
        _setProgress('Expanding seed artists', 0, selection.seeds.length);
        final expansionBySeed = <int, List<SimilarTrack>>{};
        final expansionLists = await mapBatched(
          selection.seeds,
          5,
          (i, seed) async {
            final artist = RecommendationEngine.primaryArtist(seed.artist);
            try {
              final topTracks =
                  await _lfm.getArtistTopTracks(artist, limit: 15);
              final sims = <SimilarTrack>[];
              for (final t in topTracks) {
                sims.add(SimilarTrack(
                  artist: t.artist,
                  title: t.title,
                  match: 0,
                ));
              }
              return sims;
            } catch (_) {
              // one bad artist must not kill the run
              return const <SimilarTrack>[];
            }
          },
          shouldStop: () => _cancelled,
          onProgress: (done, total) =>
              _setProgress('Expanding seed artists', done, total),
        );
        if (_cancelled) return _abort();
        for (var i = 0; i < selection.seeds.length; i++) {
          if (expansionLists[i].isNotEmpty) {
            expansionBySeed[i] = expansionLists[i];
          }
        }
        if (expansionBySeed.isNotEmpty) {
          final expansionReasons = <int, String>{};
          for (var i = 0; i < selection.seeds.length; i++) {
            if (expansionBySeed.containsKey(i)) {
              expansionReasons[i] =
                  'More from ${RecommendationEngine.primaryArtist(selection.seeds[i].artist)}';
            }
          }
          final expanded = RecommendationEngine.scoreCandidates(
            seeds: selection.seeds,
            similarBySeed: similarBySeed,
            fallbackBySeed: {
              ...fallbackBySeed,
              ...expansionBySeed,
            },
            fallbackReasonBySeed: {
              ...fallbackReasonBySeed,
              ...expansionReasons,
            },
          );
          // Merge: keep original scores for tracks already present, add
          // new expansion tracks at their scored values.
          final existingKeys = {
            for (final s in scored)
              RecommendationEngine.normalizeKey(
                  s.track.artist, s.track.title)
          };
          final merged = <ScoredTrack>[];
          merged.addAll(scored);
          for (final e in expanded) {
            final key = RecommendationEngine.normalizeKey(
                e.track.artist, e.track.title);
            if (!existingKeys.contains(key)) {
              merged.add(e);
              existingKeys.add(key);
            }
          }
          merged.sort((a, b) => b.score.compareTo(a.score));
          scored = merged;
        }
      }

      // 1c. Similar-artist expansion (Phase 1 sparse generation): if
      // the pool is STILL short after the seed-artist top-15
      // expansion, add top tracks of Last.fm similar artists. This
      // is the step that discovers new artists instead of more tracks
      // by the same (possibly wrong) artist. Capped: at most 2
      // similar artists per seed, 5 tracks each, 40 new tracks total;
      // 0.4 weight via scoreCandidates fallbacks; one bad artist
      // never kills the run.
      if (scored.length < settings.songCount) {
        if (_cancelled) return _abort();
        _setProgress('Exploring similar artists', 0, selection.seeds.length);
        final simExpBySeed = <int, List<SimilarTrack>>{};
        final simExpReasons = <int, String>{};
        var simAdded = 0;
        const simCap = 40;
        final simExpansionLists = await mapBatched(
          selection.seeds,
          5,
          (i, seed) async {
            final artist = RecommendationEngine.primaryArtist(seed.artist);
            try {
              final similars = await _lfm.getSimilarArtists(artist);
              final sims = <SimilarTrack>[];
              for (final similar in similars.take(2)) {
                try {
                  final topTracks =
                      await _lfm.getArtistTopTracks(similar, limit: 5);
                  for (final t in topTracks) {
                    sims.add(SimilarTrack(
                      artist: t.artist,
                      title: t.title,
                      match: 0,
                    ));
                  }
                } catch (_) {
                  // one bad similar artist must not kill the run
                }
              }
              return sims;
            } catch (_) {
              // one bad artist must not kill the run
              return const <SimilarTrack>[];
            }
          },
          shouldStop: () => _cancelled,
          onProgress: (done, total) =>
              _setProgress('Exploring similar artists', done, total),
        );
        if (_cancelled) return _abort();
        for (var i = 0; i < selection.seeds.length; i++) {
          if (simAdded >= simCap) break;
          final seed = selection.seeds[i];
          final artist = RecommendationEngine.primaryArtist(seed.artist);
          final sims = simExpansionLists[i];
          if (sims.isEmpty) continue;
          // Enforce the 40-track cap in seed order (the old
          // sequential loop could overshoot it by up to one similar
          // artist's tracks; the cap is now exact).
          final remaining = simCap - simAdded;
          final take = remaining < sims.length ? remaining : sims.length;
          final taken = sims.sublist(0, take);
          if (taken.isNotEmpty) {
            simExpBySeed[i] = taken;
            simExpReasons[i] = 'Similar artists to $artist';
            simAdded += taken.length;
          }
        }
        if (simExpBySeed.isNotEmpty) {
          final simExpanded = RecommendationEngine.scoreCandidates(
            seeds: selection.seeds,
            similarBySeed: similarBySeed,
            fallbackBySeed: simExpBySeed,
            fallbackReasonBySeed: simExpReasons,
          );
          final existingKeys = {
            for (final s in scored)
              RecommendationEngine.normalizeKey(
                  s.track.artist, s.track.title)
          };
          final merged = <ScoredTrack>[];
          merged.addAll(scored);
          for (final e in simExpanded) {
            final key = RecommendationEngine.normalizeKey(
                e.track.artist, e.track.title);
            if (!existingKeys.contains(key)) {
              merged.add(e);
              existingKeys.add(key);
            }
          }
          merged.sort((a, b) => b.score.compareTo(a.score));
          scored = merged;
        }
      }

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

      // 2b. Learned Fresh Finds: favorited-artist top tracks merged into
      // the modifier pool so your taste shapes recommendations.
      if (settings.freshFinds) {
        if (_cancelled) return _abort();
        _setProgress('Learning from your favorites', 0, 1);
        final freshPool = await _buildFreshPool(freshFinds: true);
        if (freshPool.isNotEmpty) {
          modifierPool = [
            ...modifierPool,
            ...freshPool.map((t) => ScoredTrack(
              track: Track(title: t.title, artist: t.artist),
              score: 1.0,
              reasons: const ['Based on your favorites'],
            )),
          ];
        }
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
      var songs = RecommendationEngine.blendWithInjections(
        core: scored,
        modifierPool: modifierPool,
        chartTracks: chartTracks,
        total: settings.songCount,
        seedKeys: seedKeys,
      );

      // 5. Album enrichment (FR-11): track.getSimilar carries no album
      // data, so without this the Albums tab would always be empty.
      // Look it up for the top songs (capped) before deriving albums.
      final enrichN = songs.length < 50 ? songs.length : 50;
      // Batched (5 in flight) instead of one lookup at a time;
      // Future.wait preserves input order, so `enriched` stays in
      // song order exactly as the sequential loop produced it.
      final enriched = await mapBatched(
        songs,
        5,
        (i, st) async {
          if (i >= enrichN) return st;
          try {
            final info = await _lfm.getTrackInfo(
              RecommendationEngine.primaryArtist(st.track.artist),
              st.track.title,
            );
            final album = info.album?.trim();
            if (album == null || album.isEmpty) return st;
            return ScoredTrack(
              track: Track(
                title: st.track.title,
                artist: st.track.artist,
                album: album,
                imageUrl: info.imageUrl ?? st.track.imageUrl,
                durationMs: st.track.durationMs,
                platformTrackId: st.track.platformTrackId,
                previewUrl: st.track.previewUrl,
              ),
              score: st.score,
              reasons: st.reasons,
            );
          } catch (_) {
            return st; // one bad lookup must not kill the run
          }
        },
        shouldStop: () => _cancelled,
        onProgress: (done, total) => _setProgress('Looking up album info',
            done < enrichN ? done : enrichN, enrichN),
      );
      if (_cancelled) return _abort();


      final albums =
          RecommendationEngine.deriveAlbums(enriched, settings.albumCount);
      // Sparse-result explanation (Phase 1): when the sources ran dry
      // and the list came up short, say so instead of silently
      // showing few songs.
      String? sparseExplanation;
      if (enriched.length < settings.songCount) {
        final skippedPart = skipped > 0
            ? '$skipped seed tracks were unknown to Last.fm, Deezer '
                'and iTunes, so '
            : '';
        sparseExplanation =
            'Only ${enriched.length} of ${settings.songCount} requested '
            'songs could be found — ${skippedPart}the sources ran dry. '
            'Try a larger or more mainstream playlist.';
      }
      // Results first: publish the unenriched result now, so the
      // Results screen opens as soon as scoring + album info are
      // done. Enrichment below only annotates cards (it never
      // rescores or reorders), so each step merges in via a later
      // publish that the live Results screen picks up. History is
      // written only once, at the very end, with the full enriched
      // result — exactly as before.
      var current = GenerationResult(
        songs: enriched,
        albums: albums,
        seedName: seedName,
        isSurprise: false,
        seedCount: selection.seeds.length,
        skippedSeeds: skipped,
        sparseExplanation: sparseExplanation,
      );
      _publishResult(current);
      // 6. MusicBrainz enrichment: AFTER scoring, top 10 only,
      // cached 30 days, 1 req/s, still strictly serial (the cap is
      // policy, not a bottleneck to parallelize away). Annotates
      // only, never rescores.
      if (_isStale(runId)) return;
      final enrichments = await _enrichTopTracks(enriched);
      if (_isStale(runId)) return;
      current = _withEnrichments(current, enrichments: enrichments);
      _publishResult(current);
      // 7. Discogs album enrichment: top 5 albums only, cached
      // 30 days. Annotates only, never rescores.
      var albumEnrichments =
          await _enrichTopAlbums(albums, enrichments);
      if (_isStale(runId)) return;
      current =
          _withEnrichments(current, albumEnrichments: albumEnrichments);
      _publishResult(current);
      // 8. TheAudioDB album enrichment: artwork + discography,
      // merged into the Discogs map. Annotates only, never drops
      // existing entries.
      albumEnrichments = await _enrichTopAlbumsTadb(
          albums, albumEnrichments, enrichments);
      if (_isStale(runId)) return;
      current =
          _withEnrichments(current, albumEnrichments: albumEnrichments);
      await _finishRun(
        result: current,
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
    // A surprise run supersedes any background enrichment still
    // running from an earlier playlist run (see [_isStale]).
    _generationRun++;
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

      // MusicBrainz enrichment, as in the playlist path.
      if (_cancelled) return _abort();
      final enrichments = await _enrichTopTracks(songs);
      if (_cancelled) return _abort();
      // Discogs album enrichment, as in the playlist path.
      var albumEnrichments =
          await _enrichTopAlbums(albums, enrichments);
      if (_cancelled) return _abort();
      // TheAudioDB album enrichment, as in the playlist path.
      albumEnrichments = await _enrichTopAlbumsTadb(
          albums, albumEnrichments, enrichments);
      if (_cancelled) return _abort();

      await _finishRun(
        result: GenerationResult(
          songs: songs,
          albums: albums,
          seedName: 'Surprise picks',
          isSurprise: true,
          seedCount: 0,
          skippedSeeds: 0,
          enrichments: enrichments,
          albumEnrichments: albumEnrichments,
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

  /// Post-score TheAudioDB enrichment for a run's top albums.
  /// Merges artwork + discography into the Discogs map; never
  /// drops existing entries. Any failure returns the input map.
  Future<Map<String, AlbumEnrichment>> _enrichTopAlbumsTadb(
      List<AlbumRec> albums,
      Map<String, AlbumEnrichment> existing,
      Map<String, TrackEnrichment> trackEnrichments) async {
    try {
      _setProgress('Enriching top albums (TheAudioDB)', 0, 1);
      TheAudioDBAlbumCache? cache;
      try {
        cache = await TheAudioDBAlbumCache.open();
      } catch (_) {
        cache = null;
      }
      final out = await TheAudioDBEnricher(_theAudioDb, cache)
          .enrichAlbums(albums, existing, trackEnrichments);
      _setProgress('Enriching top albums (TheAudioDB)', 1, 1);
      return out;
    } catch (_) {
      return existing;
    }
  }

  /// Post-score Discogs enrichment for a run's top albums.
  /// Cache opens lazily; uncached on open failure. Any failure
  /// returns an empty map — enrichment never fails a run.
  Future<Map<String, AlbumEnrichment>> _enrichTopAlbums(
      List<AlbumRec> albums,
      Map<String, TrackEnrichment> trackEnrichments) async {
    try {
      _setProgress('Enriching top albums (Discogs)', 0, 1);
      DiscogsAlbumCache? cache;
      try {
        cache = await DiscogsAlbumCache.open();
      } catch (_) {
        cache = null;
      }
      final out = await DiscogsEnricher(_discogs, _musicBrainz, cache)
          .enrichAlbums(albums, trackEnrichments);
      _setProgress('Enriching top albums (Discogs)', 1, 1);
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Post-score MusicBrainz enrichment for a run's top songs.
  /// Cache opens lazily; uncached on open failure. Any failure
  /// returns an empty map — enrichment never fails a run.
  Future<Map<String, TrackEnrichment>> _enrichTopTracks(
      List<ScoredTrack> songs) async {
    try {
      _setProgress('Enriching top tracks (MusicBrainz)', 0, 1);
      EnrichmentCache? cache;
      try {
        cache = await EnrichmentCache.open();
      } catch (_) {
        cache = null; // uncached enrichment is still better than none
      }
      final enrichments =
          await MusicBrainzEnricher(_musicBrainz, cache).enrichTracks(songs);
      _setProgress('Enriching top tracks (MusicBrainz)', 1, 1);
      return enrichments;
    } catch (_) {
      return const {};
    }
  }

  /// ListenBrainz recommendations for [username], via the 7-day Hive
  /// cache when it opens (a cache failure just means uncached).
  /// A fresh cached miss returns [] without a network call; every
  /// failure path returns [] and never aborts the run.
  Future<List<SimilarTrack>> _listenBrainzTracks(String username) async {
    try {
      ListenBrainzCache? cache;
      try {
        cache = await ListenBrainzCache.open();
      } catch (_) {
        cache = null;
      }
      if (cache != null) {
        final hit = cache.lookup(username);
        if (hit != null) return hit;
        if (!cache.shouldRetry(username, DateTime.now())) {
          return const [];
        }
      }
      final tracks = await _listenBrainz.recommendedTracks(username);
      if (cache != null) {
        if (tracks.isEmpty) {
          cache.storeMiss(username);
        } else {
          cache.store(username, tracks);
        }
      }
      return tracks;
    } catch (_) {
      return const [];
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

  /// True when this run is no longer current: cancelled, or a newer
  /// run has started. Background enrichment steps must check this
  /// before each publish so they never overwrite a newer run.
  bool _isStale(int runId) => _cancelled || runId != _generationRun;

  /// Publish a result to state without writing history yet. Used for
  /// the results-first emit: the user sees songs/albums as soon as
  /// scoring + album info are done, while enrichment still runs in
  /// the background and merges in via later publishes.
  void _publishResult(GenerationResult result) {
    state = GenerationState(result: result);
  }

  /// A copy of [base] with new enrichment maps (same songs, albums,
  /// seed info and explanation). Enrichment never rescores or
  /// reorders, so only the annotation maps change.
  GenerationResult _withEnrichments(
    GenerationResult base, {
    Map<String, TrackEnrichment>? enrichments,
    Map<String, AlbumEnrichment>? albumEnrichments,
  }) =>
      GenerationResult(
        songs: base.songs,
        albums: base.albums,
        seedName: base.seedName,
        isSurprise: base.isSurprise,
        seedCount: base.seedCount,
        skippedSeeds: base.skippedSeeds,
        sparseExplanation: base.sparseExplanation,
        enrichments: enrichments ?? base.enrichments,
        albumEnrichments: albumEnrichments ?? base.albumEnrichments,
      );

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
      // Bump the shared version AFTER the write succeeds, so the
      // History tab (IndexedStack, never rebuilt on tab switch)
      // re-reads getAll() and shows this run immediately.
      _historyVersion?.state++;
    } catch (e) {
      // History is best-effort: results still display even if the
      // write fails. But log it, so a real write failure is
      // distinguishable from the old refresh bug (which looked
      // identical from the UI: a missing run).
      debugPrint('History write failed: $e');
    }
    state = GenerationState(result: result);
  }

  void _abort() {
    _cancelled = false;
    state = GenerationState.idle;
  }
}

/// Repeat behaviour at the end of a track (completion) and on
/// next/previous at the ends of the queue.
enum RepeatMode { off, all, one }

/// Snapshot of the single shared player (mini-player, play buttons and
/// the Android media notification all read this one state).
class PlaybackState {
  /// Track currently loaded (playing or paused). Null when stopped.
  final Track? currentTrack;

  /// Play queue: the list the current track was played from, so
  /// next/previous work across screens. Empty when nothing is loaded.
  final List<Track> queue;

  /// Index of [currentTrack] in [queue], -1 when there is no queue.
  final int queueIndex;

  final bool isPlaying;

  /// True while a full song is being resolved for a tap.
  final bool isResolving;

  /// Normalized key of the track being resolved, if any. Only
  /// meaningful while [isResolving] is true.
  final String? resolvingKey;

  /// Playback position; [duration] is null until the backend reports
  /// it (a live radio stream never does).
  final Duration position;
  final Duration? duration;

  /// True when the current track is a live stream (Jamendo radio).
  /// Live streams show "Live" instead of a duration, and never
  /// report one.
  final bool isLive;

  /// Shuffle state. When true, next/previous walk [shuffledOrder]
  /// instead of [queue] order; the order holds queue indices with
  /// the current track first. Empty when shuffle is off.
  final bool shuffleEnabled;
  final List<int> shuffledOrder;

  /// Repeat mode for completion auto-advance and next/previous at
  /// the ends of the queue.
  final RepeatMode repeatMode;

  /// Human-readable reason for the last playback failure, if any.
  /// Shown once as a SnackBar by the root scaffold; [errorSeq]
  /// increments per failure so the scaffold can tell a new failure
  /// from the previous one.
  final String? lastError;
  final int errorSeq;

  const PlaybackState({
    this.currentTrack,
    this.queue = const [],
    this.queueIndex = -1,
    this.isPlaying = false,
    this.isResolving = false,
    this.resolvingKey,
    this.position = Duration.zero,
    this.duration,
    this.isLive = false,
    this.shuffleEnabled = false,
    this.shuffledOrder = const [],
    this.repeatMode = RepeatMode.off,
    this.lastError,
    this.errorSeq = 0,
  });

  static const idle = PlaybackState();

  /// Normalized key of [currentTrack], null when stopped.
  String? get currentKey => currentTrack == null
      ? null
      : RecommendationEngine.normalizeKey(
          currentTrack!.artist, currentTrack!.title);

  bool get hasCurrentTrack => currentTrack != null;

  /// Position of the current track inside [shuffledOrder], -1 when
  /// shuffle is off or the order does not cover the current track.
  int get shufflePosition =>
      shuffleEnabled ? shuffledOrder.indexOf(queueIndex) : -1;

  /// True when next() would move to another track: there is a later
  /// track in the active order, or repeat-all wraps to the start.
  bool get hasNext {
    if (queueIndex < 0 || queue.isEmpty) return false;
    if (shuffleEnabled && shuffledOrder.isNotEmpty) {
      final pos = shufflePosition;
      if (pos < 0) return false;
      return pos + 1 < shuffledOrder.length ||
          repeatMode == RepeatMode.all;
    }
    return queueIndex + 1 < queue.length || repeatMode == RepeatMode.all;
  }

  /// True when previous() would move to another track: there is an
  /// earlier track in the active order, or repeat-all wraps to the
  /// end. (previous() restarts the current track first when well
  /// into it, so this only gates the move itself.)
  bool get hasPrevious {
    if (queueIndex < 0 || queue.isEmpty) return false;
    if (shuffleEnabled && shuffledOrder.isNotEmpty) {
      final pos = shufflePosition;
      if (pos < 0) return false;
      return pos > 0 || repeatMode == RepeatMode.all;
    }
    return queueIndex > 0 || repeatMode == RepeatMode.all;
  }

  /// 0..1 progress for the mini-player bar; 0 when duration is unknown.
  double get progressFraction {
    final d = duration;
    if (d == null || d.inMilliseconds <= 0) return 0;
    return (position.inMilliseconds / d.inMilliseconds).clamp(0.0, 1.0);
  }

  PlaybackState copyWith({
    Track? currentTrack,
    bool clearCurrentTrack = false,
    List<Track>? queue,
    int? queueIndex,
    bool? isPlaying,
    bool? isResolving,
    String? resolvingKey,
    bool clearResolvingKey = false,
    Duration? position,
    Duration? duration,
    bool clearDuration = false,
    bool? isLive,
    bool? shuffleEnabled,
    List<int>? shuffledOrder,
    RepeatMode? repeatMode,
    String? lastError,
    bool clearLastError = false,
    int? errorSeq,
  }) =>
      PlaybackState(
        currentTrack:
            clearCurrentTrack ? null : (currentTrack ?? this.currentTrack),
        queue: queue ?? this.queue,
        queueIndex: queueIndex ?? this.queueIndex,
        isPlaying: isPlaying ?? this.isPlaying,
        isResolving: isResolving ?? this.isResolving,
        resolvingKey:
            clearResolvingKey ? null : (resolvingKey ?? this.resolvingKey),
        position: position ?? this.position,
        duration: clearDuration ? null : (duration ?? this.duration),
        isLive: isLive ?? this.isLive,
        shuffleEnabled: shuffleEnabled ?? this.shuffleEnabled,
        shuffledOrder: shuffledOrder ?? this.shuffledOrder,
        repeatMode: repeatMode ?? this.repeatMode,
        lastError: clearLastError ? null : (lastError ?? this.lastError),
        errorSeq: errorSeq ?? this.errorSeq,
      );
}

/// Manages playback for recommended tracks — one shared player across
/// the app; only one track plays at a time. Resolves each track to a
/// FULL song through [FullSongResolver] (no previews anywhere). The
/// queue is the list a track was played from (results, playlist,
/// album, Discover tab), so the mini-player's next/previous buttons
/// work across screens.
class AudioPlayerNotifier extends StateNotifier<PlaybackState> {
  AudioBackend? _backend;

  /// Full-song resolver (injected in tests; built from the fallbacks
  /// + Audius client when omitted, so a bare notifier still resolves
  /// through Deezer/iTunes links + Audius).
  final FullSongResolver _resolver;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  /// Monotonic token: a resolve superseded by a newer tap is dropped
  /// instead of overwriting the newer track's state.
  int _playToken = 0;
  /// How each resolved track was sourced: 'ownStream' for a track's
  /// own stream, 'audius' / 'jamendo' / 'youtube' for full in-app
  /// streams, 'spotify-corrected' for a match found via the Spotify
  /// metadata re-resolve, 'full' for a full stream handed to
  /// playStream (e.g. Jamendo radio). Only in-app sources are ever
  /// recorded here: an outbound-only match is reported in-app
  /// instead of opened, so it never gets a source label. The button
  /// uses this to label a full track honestly. Jamendo is only a
  /// resolver step when the user set a client_id (see
  /// [audioPlayerProvider]).
  final Map<String, String> _streamSource = {};

  /// Position ticks are rounded to this grid before they reach the
  /// state, so the player notifies at most 4 times a second instead
  /// of on every audioplayers event (several per second). Seeks set
  /// the exact position directly and are never rounded.
  static const positionStep = Duration(milliseconds: 250);

  AudioPlayerNotifier(FallbackSources fallbacks,
      {AudioBackend? backend,
      AudiusClient? audiusClient,
      FullSongResolver? resolver})
      : _backend = backend,
        _resolver = resolver ??
            FullSongResolver(fallbacks: fallbacks, audius: audiusClient),
        super(PlaybackState.idle);

  /// The real backend, created lazily on first actual playback so that
  /// constructing the notifier — and resolving a track, which is pure
  /// Dart plus the resolver cache — never touches the audio platform.
  /// (audioplayers' AudioPlayer constructor calls _create() on the
  /// platform, which has no registered plugin in a flutter_test
  /// environment; the old eager construction is what made the
  /// no-network resolve test fail on CI.)
  AudioBackend get _audio => _backend ??= AudioplayersBackend();

  /// Subscribe to backend events lazily, only when audio actually
  /// plays, so constructing the notifier (and resolving a track that
  /// turns out to have no full song) never touches platform channels.
  void _ensureSubs() {
    if (_stateSub != null) return;
    _stateSub = _audio.onPlayerStateChanged.listen((playerState) {
      if (playerState != PlayerState.completed) return;
      // A finished track replays, advances, or stops by repeat mode.
      if (state.repeatMode == RepeatMode.one) {
        unawaited(_replayCurrent());
        return;
      }
      final next = _nextIndex();
      if (next != null) {
        unawaited(_playAt(next));
      } else {
        unawaited(stop());
      }
    });
    _positionSub = _audio.onPositionChanged.listen((pos) {
      if (!state.hasCurrentTrack) return;
      // Round the tick to the 250 ms grid and drop it when the
      // rounded value has not moved: audioplayers fires several
      // times a second, and every state assignment rebuilds every
      // widget watching the player (every song row on every
      // kept-alive tab). Rounding plus the dedupe below caps
      // position notifications at 4 per second.
      final step = positionStep.inMilliseconds;
      final rounded = Duration(
          milliseconds: (pos.inMilliseconds / step).round() * step);
      if (rounded == state.position) return;
      state = state.copyWith(position: rounded);
    });
    _durationSub = _audio.onDurationChanged.listen((d) {
      if (!state.hasCurrentTrack) return;
      state = state.copyWith(duration: d);
    });
  }

  /// Normalized key for a track, using the same function generation
  /// and the fallback layer use, so keys built anywhere match the
  /// keys used here.
  String _key(Track track) =>
      RecommendationEngine.normalizeKey(track.artist, track.title);

  bool get isPlaying => state.isPlaying;

  /// Current player state, for the media notification handler (which
  /// has no Riverpod ref to watch the provider through).
  PlaybackState get currentState => state;

  /// Normalized key of the currently playing track, null otherwise.
  String? get playingKey => state.isPlaying ? state.currentKey : null;

  /// Normalized key of the track whose full song is being resolved, if
  /// any. Only meaningful while [PlaybackState.isResolving] is true.
  String? get resolvingKey => state.resolvingKey;

  /// Resolution source for [track] once it has been resolved:
  /// 'ownStream' (the track's own stream), 'audius' / 'jamendo' /
  /// 'youtube' (full in-app stream), 'spotify-corrected' (match found
  /// via the Spotify metadata re-resolve) or 'full' (full stream
  /// handed to playStream). Null before any resolution, and null
  /// when the track had no in-app stream. Every resolution is a full
  /// track, never a preview.
  String? streamSourceFor(Track track) => _streamSource[_key(track)];

  /// Human-readable reason for a playback failure, for the SnackBar.
  /// A [failure] distinguishes the cases the resolver reports: no
  /// full stream anywhere, a source that could not be reached, or a
  /// track that only exists on Spotify (whose audio cannot play
  /// in-app). Without a [failure], [error] is a load/play error from
  /// the backend: network-looking failures say so; anything else
  /// stays a plain "couldn't play" instead of leaking a long platform
  /// message into the UI.
  static String playbackErrorMessage(Object error,
      {FullSongFailure? failure, String? networkSource}) {
    switch (failure) {
      case FullSongFailure.noStream:
        return 'No full stream found for this track';
      case FullSongFailure.network:
        final source = networkSource ?? 'a source';
        return "Couldn't reach $source — check your connection";
      case FullSongFailure.spotifyAudioUnavailable:
        return "Spotify audio can't play in-app";
      case null:
        break;
    }
    final detail = error is AudioPlayerException
        ? (error.cause?.toString() ?? error.toString())
        : error.toString();
    if (_looksLikeNetwork(detail)) {
      return "Couldn't load audio — check your connection";
    }
    return "Couldn't play this track";
  }

  static bool _looksLikeNetwork(String text) {
    final lower = text.toLowerCase();
    return lower.contains('socketexception') ||
        lower.contains('unknown host') ||
        lower.contains('failed host lookup') ||
        lower.contains('timed out') ||
        lower.contains('connection') ||
        lower.contains('network') ||
        lower.contains('unable to load') ||
        lower.contains('404') ||
        lower.contains('403');
  }

  /// Record a playback failure for [track] (loaded, paused): the
  /// mini-player still shows what failed, and bumping
  /// [PlaybackState.errorSeq] makes the root scaffold's SnackBar fire.
  /// Shuffle, repeat and live state survive the failure: the track
  /// is still loaded with the same queue. [isLive] overrides the
  /// preserved flag when the caller knows better (a failed load of
  /// a new track); otherwise the current flag is kept.
  void _reportError(
      String message, Track track, List<Track> queue, int index,
      {bool? isLive}) {
    state = PlaybackState(
      currentTrack: track,
      queue: queue,
      queueIndex: index,
      isLive: isLive ?? state.isLive,
      shuffleEnabled: state.shuffleEnabled,
      shuffledOrder: _orderForQueue(queue, index),
      repeatMode: state.repeatMode,
      lastError: message,
      errorSeq: state.errorSeq + 1,
    );
  }

  /// Play [track], resolving it to a full song first. Tapping the
  /// playing track pauses it; tapping the paused track resumes it.
  /// [queue] is the list the track was played from (results,
  /// playlist, album, Discover tab) — it becomes the next/previous
  /// queue. Without a queue the track plays on its own.
  Future<void> play(Track track, {List<Track>? queue}) async {
    final key = _key(track);
    final current = state;
    if (current.currentKey == key && !current.isResolving) {
      if (current.isPlaying) {
        await pause();
      } else if (current.currentTrack != null) {
        await resume();
      }
      return;
    }
    final newQueue = queue ?? _queueFor(track);
    final index = _indexOfKey(newQueue, key);
    final token = ++_playToken;
    // Resolve first (resolving state), so a tap on a track with no
    // full song actually runs the lookup instead of doing nothing.
    // A track already playing keeps playing meanwhile.
    state = current.copyWith(isResolving: true, resolvingKey: key);
    final failure = await _resolveAndPlay(
      track: track,
      queue: newQueue,
      index: index < 0 ? 0 : index,
      token: token,
    );
    // A newer tap superseded this resolve; its own state update wins.
    if (token != _playToken) return;
    if (failure != null) {
      // No full song anywhere: report why, and restore the previous
      // playing state (still playing another track, or stopped)
      // instead of leaving a stale resolving state behind.
      state = current.copyWith(
        lastError: failure,
        errorSeq: current.errorSeq + 1,
      );
      return;
    }
  }

  /// Resolve [track] through the full-song resolver and play it
  /// in-app. Returns the failure message to report, or null when the
  /// track is playing in-app. A match that is outbound-only (a
  /// YouTube / Deezer / iTunes link with no in-app stream) is a
  /// failure too: the app reports "No full stream found for this
  /// track" in-app and never opens another app from a tap. The user
  /// can still open a track in its platform app explicitly, from the
  /// overflow sheet on the track row. Never touches state on the
  /// failure path (the caller owns the error state); on the success
  /// path it checks [token] first, so a superseded resolve cannot
  /// overwrite a newer tap's state.
  Future<String?> _resolveAndPlay({
    required Track track,
    required List<Track> queue,
    required int index,
    required int token,
  }) async {
    final result = await _resolver.resolve(track);
    if (token != _playToken) return null;
    final match = result.match;
    if (match == null) {
      return playbackErrorMessage(
        '',
        failure: result.failure,
        networkSource: result.networkSource,
      );
    }
    if (!match.playInApp) {
      // Outbound-only match: no in-app stream exists. Report it
      // in-app with the standard no-stream message; the per-source
      // reason is in the Playback log.
      return playbackErrorMessage('', failure: FullSongFailure.noStream);
    }
    _streamSource[_key(track)] = match.sourceLabel;
    await _playResolved(
      track: track,
      url: match.streamUrl!,
      queue: queue,
      index: index,
      token: token,
    );
    return null;
  }

  /// Play an already-resolved full-stream URL (a full-song match, a
  /// Discover stream, a Jamendo radio), bypassing the toggle in
  /// [play]: a full stream for the same track key that is already
  /// playing must not swallow the new one as a "pause". Records the
  /// source so the shared buttons show the playing state honestly.
  /// [live] marks a true live stream (Jamendo radio): the player
  /// shows "Live" instead of a duration for it. In-app resolver
  /// streams are files, so they stay false.
  Future<void> playStream(Track track, String url,
      {String source = 'audius', List<Track>? queue, bool live = false}) async {
    final key = _key(track);
    final newQueue = queue ?? _queueFor(track);
    final index = _indexOfKey(newQueue, key);
    final token = ++_playToken;
    _streamSource[key] = source;
    await _playResolved(
      track: track,
      url: url,
      queue: newQueue,
      index: index < 0 ? 0 : index,
      token: token,
      isLive: live,
    );
  }

  /// Play the track at [index] in the current queue (mini-player
  /// next/previous, media notification, completion auto-advance).
  /// When shuffle is on, the shuffle position re-anchors to [index]:
  /// the order itself is unchanged, only the walk position moves.
  Future<void> playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    await _playAt(index);
  }

  Future<void> _playAt(int index) async {
    final queue = state.queue;
    if (index < 0 || index >= queue.length) return;
    final track = queue[index];
    final token = ++_playToken;
    state = state.copyWith(
      isResolving: true,
      resolvingKey: _key(track),
    );
    final failure = await _resolveAndPlay(
      track: track,
      queue: queue,
      index: index,
      token: token,
    );
    if (token != _playToken) return;
    if (failure != null) {
      // Unplayable queue entry: report why and stop on the failed
      // track (paused) instead of spinning on the next one.
      state = state.copyWith(
        isPlaying: false,
        isResolving: false,
        clearResolvingKey: true,
        lastError: failure,
        errorSeq: state.errorSeq + 1,
      );
      return;
    }
  }

  /// Stop the backend and start [url] for [track]; on a load failure
  /// the attempted track stays loaded (paused) with the reason in
  /// [PlaybackState.lastError]. [token] guards against superseded
  /// resolves. The duration is fetched explicitly after play:
  /// onDurationChanged can fire while the old track is still in
  /// state (and get dropped), so the event alone never fills the
  /// new track's duration. A null fetch leaves the duration null
  /// (live streams never report one); the event subscription stays
  /// as a backup for a duration that arrives later.
  Future<void> _playResolved({
    required Track track,
    required String url,
    required List<Track> queue,
    required int index,
    required int token,
    bool isLive = false,
  }) async {
    _ensureSubs();
    try {
      await _audio.stop();
      await _audio.play(url);
    } on Object catch (e) {
      if (token != _playToken) return;
      _reportError(playbackErrorMessage(e), track, queue, index,
          isLive: isLive);
      return;
    }
    if (token != _playToken) return;
    // Fetch after play, while the new track is about to land in
    // state; a superseded resolve must not publish over the newer
    // track, so the token is checked again after the fetch.
    final fetchedDuration = await _audio.getDuration();
    if (token != _playToken) return;
    state = state.copyWith(
      currentTrack: track,
      queue: queue,
      queueIndex: index,
      isPlaying: true,
      isResolving: false,
      clearResolvingKey: true,
      position: Duration.zero,
      duration: fetchedDuration,
      clearDuration: fetchedDuration == null,
      isLive: isLive,
      shuffledOrder: _orderForQueue(queue, index),
      clearLastError: true,
    );
  }

  /// Queue containing [track] if the current queue has it, else a
  /// single-track queue.
  List<Track> _queueFor(Track track) {
    final key = _key(track);
    if (_indexOfKey(state.queue, key) >= 0) return state.queue;
    return [track];
  }

  int _indexOfKey(List<Track> queue, String key) {
    for (var i = 0; i < queue.length; i++) {
      if (_key(queue[i]) == key) return i;
    }
    return -1;
  }

  /// True when two queues hold the same tracks in the same order
  /// (by normalized key), so a kept shuffled order still fits.
  bool _sameQueue(List<Track> a, List<Track> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_key(a[i]) != _key(b[i])) return false;
    }
    return true;
  }

  /// True when [order] is a full permutation of 0..[length).
  bool _validOrder(List<int> order, int length) {
    if (order.length != length) return false;
    final seen = <int>{};
    for (final i in order) {
      if (i < 0 || i >= length || !seen.add(i)) return false;
    }
    return true;
  }

  /// Shuffled order of queue indices with [currentIndex] first.
  List<int> _buildShuffledOrder(List<Track> queue, int currentIndex) {
    final order = List<int>.generate(queue.length, (i) => i)..shuffle();
    order.remove(currentIndex);
    order.insert(0, currentIndex);
    return order;
  }

  /// Shuffled order to store when [queue] becomes the playing queue
  /// at [index]: keep the current order when the queue is unchanged
  /// (next/previous walk it), rebuild anchored at the new track
  /// when the queue itself changed, empty when shuffle is off.
  List<int> _orderForQueue(List<Track> queue, int index) {
    if (!state.shuffleEnabled) return const [];
    if (_sameQueue(queue, state.queue) &&
        _validOrder(state.shuffledOrder, queue.length) &&
        state.shuffledOrder.contains(index)) {
      return state.shuffledOrder;
    }
    if (queue.isEmpty || index < 0) return const [];
    return _buildShuffledOrder(queue, index);
  }

  /// Queue index [i] lands at after moving the entry at [oldIndex]
  /// to [newIndex].
  int _movedIndex(int i, int oldIndex, int newIndex) {
    if (i == oldIndex) return newIndex;
    if (oldIndex < newIndex) {
      if (i > oldIndex && i <= newIndex) return i - 1;
    } else if (i >= newIndex && i < oldIndex) {
      return i + 1;
    }
    return i;
  }

  /// Shuffled order after removing queue entry [removed]: the entry
  /// drops out and later indices shift down by one.
  List<int> _orderAfterRemoval(List<int> order, int removed) => [
        for (final i in order)
          if (i != removed) i > removed ? i - 1 : i,
      ];

  /// Shuffled order after inserting a queue entry at [insertAt]:
  /// later indices shift up by one, and the new entry lands right
  /// after the current track in the walk, so play-next means next
  /// in shuffle order too. Empty stays empty (shuffle off).
  List<int> _orderAfterInsertion(
      List<int> order, int insertAt, int currentIndex) {
    if (order.isEmpty) return const [];
    final shifted = [
      for (final i in order) i >= insertAt ? i + 1 : i,
    ];
    final pos = shifted.indexOf(currentIndex);
    if (pos < 0) return [...shifted, insertAt];
    shifted.insert(pos + 1, insertAt);
    return shifted;
  }

  Future<void> pause() async {
    final backend = _backend;
    if (backend == null || !state.hasCurrentTrack) return;
    await backend.pause();
    state = state.copyWith(isPlaying: false);
  }

  Future<void> resume() async {
    if (!state.hasCurrentTrack || state.isPlaying) return;
    _ensureSubs();
    try {
      await _audio.resume();
    } on Object catch (e) {
      _reportError(playbackErrorMessage(e), state.currentTrack!,
          state.queue, state.queueIndex);
      return;
    }
    state = state.copyWith(isPlaying: true);
  }

  /// Stop playback and clear the player (the mini-player bar hides).
  Future<void> stop() async {
    final backend = _backend;
    if (backend != null) {
      await backend.stop();
    }
    _playToken++;
    state = PlaybackState.idle;
  }

  Future<void> next() async {
    final next = _nextIndex();
    if (next != null) await _playAt(next);
  }

  Future<void> previous() async {
    // Standard behaviour: restart the track when well into it,
    // otherwise go to the previous one.
    if (state.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    final prev = _previousIndex();
    if (prev != null) await _playAt(prev);
  }

  /// Queue index of the track next() would play, or null when there
  /// is none: the next entry in the shuffled order while shuffle is
  /// on, else the next queue entry; repeat-all wraps to the start.
  int? _nextIndex() {
    final s = state;
    if (s.queue.isEmpty || s.queueIndex < 0) return null;
    if (s.shuffleEnabled && s.shuffledOrder.isNotEmpty) {
      final pos = s.shufflePosition;
      if (pos < 0) return null;
      if (pos + 1 < s.shuffledOrder.length) return s.shuffledOrder[pos + 1];
      return s.repeatMode == RepeatMode.all ? s.shuffledOrder.first : null;
    }
    if (s.queueIndex + 1 < s.queue.length) return s.queueIndex + 1;
    return s.repeatMode == RepeatMode.all ? 0 : null;
  }

  /// Queue index of the track previous() would play, or null when
  /// there is none: the previous entry in the shuffled order while
  /// shuffle is on, else the previous queue entry; repeat-all wraps
  /// to the end.
  int? _previousIndex() {
    final s = state;
    if (s.queue.isEmpty || s.queueIndex < 0) return null;
    if (s.shuffleEnabled && s.shuffledOrder.isNotEmpty) {
      final pos = s.shufflePosition;
      if (pos < 0) return null;
      if (pos > 0) return s.shuffledOrder[pos - 1];
      return s.repeatMode == RepeatMode.all ? s.shuffledOrder.last : null;
    }
    if (s.queueIndex > 0) return s.queueIndex - 1;
    return s.repeatMode == RepeatMode.all ? s.queue.length - 1 : null;
  }

  /// Replay the current track from the start (repeat-one
  /// completion): seek to zero and resume directly on the backend,
  /// since the state still reports playing after a completed event
  /// and resume() would no-op on it.
  Future<void> _replayCurrent() async {
    final backend = _backend;
    if (backend == null || !state.hasCurrentTrack) return;
    await backend.seek(Duration.zero);
    await backend.resume();
    state = state.copyWith(position: Duration.zero, isPlaying: true);
  }

  /// Turn shuffle on or off. Turning it on builds a shuffled order
  /// of queue indices with the current track first; turning it off
  /// clears the order and restores plain queue order.
  void toggleShuffle() {
    if (state.shuffleEnabled) {
      state = state.copyWith(shuffleEnabled: false, shuffledOrder: const []);
      return;
    }
    final queue = state.queue;
    final index = state.queueIndex;
    final order = queue.isEmpty || index < 0
        ? const <int>[]
        : _buildShuffledOrder(queue, index);
    state = state.copyWith(shuffleEnabled: true, shuffledOrder: order);
  }

  /// Cycle repeat off to all to one and back to off.
  void cycleRepeat() {
    switch (state.repeatMode) {
      case RepeatMode.off:
        setRepeatMode(RepeatMode.all);
      case RepeatMode.all:
        setRepeatMode(RepeatMode.one);
      case RepeatMode.one:
        setRepeatMode(RepeatMode.off);
    }
  }

  void setRepeatMode(RepeatMode mode) {
    state = state.copyWith(repeatMode: mode);
  }

  /// Reorder [queue]: move the track at [oldIndex] to [newIndex].
  /// The current track keeps playing: [queueIndex] follows the same
  /// track, and the shuffled order is remapped through the same move.
  /// Out-of-range indices are a no-op.
  void moveInQueue(int oldIndex, int newIndex) {
    final queue = state.queue;
    if (oldIndex < 0 ||
        oldIndex >= queue.length ||
        newIndex < 0 ||
        newIndex >= queue.length ||
        oldIndex == newIndex) {
      return;
    }
    final newQueue = [...queue];
    final track = newQueue.removeAt(oldIndex);
    newQueue.insert(newIndex, track);
    final newIndexOfCurrent =
        _movedIndex(state.queueIndex, oldIndex, newIndex);
    var order = [
      for (final i in state.shuffledOrder)
        _movedIndex(i, oldIndex, newIndex),
    ];
    if (state.shuffleEnabled && !_validOrder(order, newQueue.length)) {
      order = _buildShuffledOrder(newQueue, newIndexOfCurrent);
    }
    state = state.copyWith(
      queue: newQueue,
      queueIndex: newIndexOfCurrent,
      shuffledOrder: order,
    );
  }

  /// Remove the track at [index] from the queue. Removing another
  /// track leaves playback alone; removing the current track
  /// advances to the next track (the next entry in the shuffled
  /// order while shuffle is on, else the track that slides into its
  /// place, wrapping to the first under repeat-all), or stops when
  /// no next track remains. Out-of-range indices are a no-op.
  Future<void> removeFromQueue(int index) async {
    final s = state;
    if (index < 0 || index >= s.queue.length) return;
    final newQueue = [...s.queue]..removeAt(index);
    if (newQueue.isEmpty) {
      await stop();
      return;
    }
    final order = _orderAfterRemoval(s.shuffledOrder, index);
    if (index != s.queueIndex) {
      final currentKey = s.currentKey;
      state = s.copyWith(
        queue: newQueue,
        queueIndex:
            currentKey == null ? -1 : _indexOfKey(newQueue, currentKey),
        shuffledOrder: order,
      );
      return;
    }
    // The removed track was playing: advance, or stop at the end.
    final target = _advanceTargetAfterRemoval(s, index, order);
    if (target == null) {
      await stop();
      return;
    }
    state = s.copyWith(
      queue: newQueue,
      queueIndex: target,
      shuffledOrder: order,
    );
    await _playAt(target);
  }

  /// Queue index removeFromQueue advances to after removing the
  /// current track at [index], or null when playback should stop.
  /// [order] is the shuffled order after the removal.
  int? _advanceTargetAfterRemoval(
      PlaybackState s, int index, List<int> order) {
    if (s.shuffleEnabled && s.shuffledOrder.isNotEmpty) {
      final pos = s.shuffledOrder.indexOf(index);
      if (pos < 0) return null;
      if (pos < order.length) return order[pos];
      return s.repeatMode == RepeatMode.all && order.isNotEmpty
          ? order.first
          : null;
    }
    if (index < s.queue.length - 1) return index;
    return s.repeatMode == RepeatMode.all ? 0 : null;
  }

  /// Insert [track] directly after the current track, so it plays
  /// next. A track already in the queue moves there instead of
  /// duplicating; the playing track itself is already first, so it
  /// stays put. With nothing loaded, the track simply plays.
  Future<void> playNext(Track track) async {
    final s = state;
    if (!s.hasCurrentTrack) {
      await play(track);
      return;
    }
    final key = _key(track);
    if (key == s.currentKey) return;
    final queue = [...s.queue];
    final existing = _indexOfKey(queue, key);
    var order = s.shuffledOrder;
    var currentIndex = s.queueIndex;
    if (existing >= 0) {
      queue.removeAt(existing);
      order = _orderAfterRemoval(order, existing);
      if (existing < currentIndex) currentIndex -= 1;
    }
    final insertAt = currentIndex + 1;
    queue.insert(insertAt, track);
    order = _orderAfterInsertion(order, insertAt, currentIndex);
    if (s.shuffleEnabled && !_validOrder(order, queue.length)) {
      order = _buildShuffledOrder(queue, currentIndex);
    }
    state = s.copyWith(
      queue: queue,
      queueIndex: currentIndex,
      shuffledOrder: order,
    );
  }

  /// Append [track] to the end of the queue, unless it is already
  /// there. Playback and the current track are untouched.
  void addToQueue(Track track) {
    final s = state;
    if (_indexOfKey(s.queue, _key(track)) >= 0) return;
    final queue = [...s.queue, track];
    var order = s.shuffledOrder;
    if (s.shuffleEnabled) {
      order = _validOrder(order, s.queue.length)
          ? [...order, queue.length - 1]
          : _buildShuffledOrder(queue, s.queueIndex);
    }
    state = s.copyWith(queue: queue, shuffledOrder: order);
  }

  Future<void> seek(Duration position) async {
    final backend = _backend;
    if (backend == null || !state.hasCurrentTrack) return;
    await backend.seek(position);
    state = state.copyWith(position: position);
  }

  /// Mini-player play/pause button: pause when playing, resume the
  /// loaded track when paused, nothing when stopped.
  Future<void> togglePlayPause() async {
    if (state.isPlaying) {
      await pause();
    } else if (state.hasCurrentTrack) {
      await resume();
    }
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    _backend?.dispose();
    super.dispose();
  }
}

/// Shared audio player provider for full-song playback.
final audioPlayerProvider =
    StateNotifierProvider<AudioPlayerNotifier, PlaybackState>(
  // Audius / YouTube / Spotify are constructed here with plain Dios
  // (same timeouts as the Discover tab's Dio) rather than watched
  // from discover_provider, so generation does not depend on the
  // Discover provider file. Discover playback is unaffected.
  // Jamendo joins only when the user set a client_id (see
  // lib/core/constants.dart); Spotify search uses the signed-in
  // session (sp_dc) and degrades to "not signed in" when absent.
  (ref) {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final fallbacks = ref.watch(fallbackSourcesProvider);
    final audius = AudiusClient(dio);
    final spotify = SpotifyInternalClient(ref.watch(dioProvider),
        SpotifySession());
    final resolver = FullSongResolver(
      fallbacks: fallbacks,
      audius: audius,
      jamendo: jamendoClientId.isNotEmpty &&
              jamendoClientId != 'YOUR_JAMENDO_CLIENT_ID'
          ? JamendoClient(dio, clientId: jamendoClientId)
          : null,
      youtube: YouTubeVideoResolver(dio),
      visionOs: VisionOsPlayerClient(dio),
      spotifySearch: (query) => spotify.searchTracks(query),
      log: ref.read(resolutionLogProvider.notifier).log,
    );
    return AudioPlayerNotifier(
      fallbacks,
      audiusClient: audius,
      resolver: resolver,
    );
  },
);
