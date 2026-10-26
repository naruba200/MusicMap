// M2 generation orchestration: Last.fm fan-out with progress, engine
// scoring, Surprise-me mode, and live related genres (spec FR-04e…FR-11,
// FR-19). The engine itself stays pure Dart in data/engine.

import 'dart:async';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/fallback/fallback_sources.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../../data/models/music_models.dart';
import '../../data/repositories/favorites_repository.dart';
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
                .toList() ?? const [],
        albums: (json['albums'] as List?)
                ?.whereType<Map>()
                .map((m) => AlbumRec.fromJson(m.cast<String, dynamic>()))
                .toList() ?? const [],
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
            ref.watch(dioProvider),
            ref.watch(historyRepositoryProvider),
            ref.watch(favoritesRepositoryProvider)));

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
  final FavoritesRepository _favorites;

  /// Cross-source fallbacks use their own plain Dio (see
  /// FallbackSources): a sinkholed Deezer host must fail fast instead
  /// of burning the shared Dio's retries per failed seed.
  late final FallbackSources _fallbacks = FallbackSources();
  bool _cancelled = false;

  GenerationNotifier(this._dio, this._history, this._favorites)
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

    if (learned.isEmpty) return chartTracks;

    // Merge learned tracks ahead of chart tracks, deduped by normalized key.
    final merged = <TagTrack>[];
    merged.addAll(learned);
    final chartKeys = <String>{};
    for (final t in learned) {
      chartKeys.add(RecommendationEngine.normalizeKey(t.artist, t.title));
    }
    for (final t in chartTracks) {
      final key = RecommendationEngine.normalizeKey(t.artist, t.title);
      if (!chartKeys.contains(key)) {
        merged.add(t);
        chartKeys.add(key);
      }
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
      // previewUrl by normalized key, so tracks from iTunes carry a
      // 30-second preview URL for in-app playback.
      final previewByKey = <String, String>{};
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
          deezerArtistTracksWithPreviews:
              _fallbacks.deezerArtistTracksWithPreviews,
          itunesArtistTracksWithPreviews:
              _fallbacks.itunesArtistTracksWithPreviews,
        );
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
          // Stash iTunes preview URLs by normalized track key.
          previewByKey.addAll(resolved.fallbackPreviews);
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

      var scored = RecommendationEngine.scoreCandidates(
        seeds: selection.seeds,
        similarBySeed: similarBySeed,
        fallbackBySeed: fallbackBySeed,
        fallbackReasonBySeed: fallbackReasonBySeed,
      );

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
        var expIdx = 0;
        for (var i = 0; i < selection.seeds.length; i++) {
          if (_cancelled) return _abort();
          final seed = selection.seeds[i];
          final artist = RecommendationEngine.primaryArtist(seed.artist);
          try {
            final topTracks = await _lfm.getArtistTopTracks(artist, limit: 15);
            final sims = <SimilarTrack>[];
            for (final t in topTracks) {
              sims.add(SimilarTrack(
                artist: t.artist,
                title: t.title,
                match: 0,
              ));
              // Stash iTunes-free preview: artist top tracks don't carry
              // preview URLs, so these stay preview-less unless resolved
              // on demand later.
            }
            if (sims.isNotEmpty) {
              expansionBySeed[i] = sims;
            }
          } catch (_) {
            // one bad artist must not kill the run
          }
          _setProgress('Expanding seed artists', ++expIdx,
              selection.seeds.length);
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

      // Stash preview URLs onto tracks that have them.
      songs = songs.map((st) {
        final key =
            RecommendationEngine.normalizeKey(st.track.artist, st.track.title);
        final preview = previewByKey[key];
        if (preview != null &&
            st.track.previewUrl == null) {
          return ScoredTrack(
            track: Track(
              title: st.track.title,
              artist: st.track.artist,
              album: st.track.album,
              imageUrl: st.track.imageUrl,
              durationMs: st.track.durationMs,
              platformTrackId: st.track.platformTrackId,
              previewUrl: preview,
            ),
            score: st.score,
            reasons: st.reasons,
          );
        }
        return st;
      }).toList();

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
                      previewUrl: st.track.previewUrl,
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

/// Manages 30-second preview playback for recommended tracks.
/// One shared player across the app; only one preview plays at a time.
/// Resolves missing preview URLs on demand via iTunes search.
///
/// The state carries the playing track key so buttons can watch it:
/// [AsyncLoading] while a preview URL is being resolved, `data(key)`
/// while that track plays, and `data(null)` when stopped or paused.
/// The key of the track currently being resolved is exposed via
/// [resolvingKey] so a button can show a spinner for its own track
/// while the state is loading.
class AudioPlayerNotifier extends StateNotifier<AsyncValue<String?>> {
  final AudioPlayer _player;
  final FallbackSources _fallbacks;
  String? _playingKey;
  String? _resolvingKey;
  StreamSubscription<PlayerState>? _stateSub;
  /// Cache of resolved preview URLs keyed by normalized track key.
  final Map<String, String> _previewCache = {};

  AudioPlayerNotifier(this._fallbacks, [AudioPlayer? player])
      : _player = player ?? AudioPlayer(),
        super(const AsyncValue.data(null));

  /// Subscribe to completion events lazily, only when audio actually
  /// plays, so constructing the notifier (and resolving a preview that
  /// turns out not to exist) never touches platform channels.
  void _ensureStateSub() {
    _stateSub ??= _player.onPlayerStateChanged.listen((playerState) {
      if (playerState == PlayerState.completed && _playingKey != null) {
        _playingKey = null;
        state = const AsyncValue.data(null);
      }
    });
  }

  /// Normalized key for a track, using the same function generation
  /// uses to look preview URLs up, so keys built anywhere in the
  /// fallback layer match the keys used here.
  String _key(Track track) =>
      RecommendationEngine.normalizeKey(track.artist, track.title);

  bool get isPlaying => _playingKey != null;

  String? get playingKey => _playingKey;

  /// Normalized key of the track whose preview is being resolved, if
  /// any. Only meaningful while [state] is [AsyncLoading].
  String? get resolvingKey => _resolvingKey;

  /// Resolve a preview URL for [track] from cache, the track itself, or
  /// an on-demand iTunes search. Public so the on-demand path is
  /// testable without driving audio playback.
  Future<String?> resolvePreview(Track track) async {
    final key = _key(track);
    // Already cached.
    final cached = _previewCache[key];
    if (cached != null) return cached;
    // Already on the track.
    if (track.previewUrl != null && track.previewUrl!.isNotEmpty) {
      _previewCache[key] = track.previewUrl!;
      return track.previewUrl;
    }
    // On-demand iTunes lookup.
    final preview = await _fallbacks.itunesTrackPreview(
      track.artist, track.title,
    );
    if (preview != null) _previewCache[key] = preview;
    return preview;
  }

  Future<void> play(Track track) async {
    final key = _key(track);
    if (_playingKey == key) {
      // Toggle: pause if already playing this track. No resolve needed.
      await _player.pause();
      _playingKey = null;
      state = const AsyncValue.data(null);
      return;
    }
    // Resolve first (loading state), so a tap on a preview-less track
    // actually runs the on-demand lookup instead of doing nothing.
    _resolvingKey = key;
    state = const AsyncLoading();
    final preview = await resolvePreview(track);
    // A newer tap superseded this resolve; its own state update wins.
    if (_resolvingKey != key) return;
    _resolvingKey = null;
    if (preview == null || preview.isEmpty) {
      // No preview anywhere: restore the previous playing state
      // (still playing another track, or stopped) instead of
      // leaving a stale loading state behind.
      state = AsyncValue.data(_playingKey);
      return;
    }
    // Stop any other track, then play this one.
    _ensureStateSub();
    await _player.stop();
    await _player.play(UrlSource(preview));
    _playingKey = key;
    state = AsyncValue.data(key);
  }

  Future<void> pause() async {
    await _player.pause();
    _playingKey = null;
    _resolvingKey = null;
    state = const AsyncValue.data(null);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}

/// Shared audio player provider for preview playback.
final audioPlayerProvider =
    StateNotifierProvider<AudioPlayerNotifier, AsyncValue<String?>>(
  (ref) => AudioPlayerNotifier(ref.watch(fallbackSourcesProvider)),
);