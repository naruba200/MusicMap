// Full-song resolver (full-song pivot, push 1): find a FULL song for
// a track. Previews are scrapped — a track plays as a full song or
// fails with a logged reason. This replaces the old preview chain
// entirely; nothing in playback consults track.previewUrl anymore.
//
// Sources, in priority order (in-app streams beat outbound links):
//   1. The track's own streamUrl (Audius/Jamendo-imported) — in-app.
//   2. Audius search — artist check REQUIRED when the artist is clean
//      (the old exemption is gone); title-only only when polluted.
//   3. Jamendo search (only when the user set a client_id) — in-app.
//   4. YTM finder (YouTubeVideoResolver.resolveVideoWithTitle, strict
//      title + artist rule) → videoId → VISIONOS player client
//      resolves a direct audio-only stream URL (verified live
//      2026-11-15: VISIONOS returns plain itag 251/140/… URLs where
//      WEB/ANDROID/IOS/EMBEDDED return none). VISIONOS success plays
//      in-app; on failure (bot-gated / no audio URL / network) the
//      match stays external (open in YTM/YouTube app) and the log
//      records why.
//   5. Spotify metadata search → canonical track → ONE re-resolve
//      round via Audius + YTM finder with the corrected metadata.
//      Metadata only: Spotify web audio is Widevine-DRM and cannot
//      play in-app; the Spotify step never claims audio.
//   6. Deezer / iTunes links (deezerTrackLink / itunesTrackLink,
//      strict match) → external match only.
//
// Matching is ALWAYS artist + title (cleaned title equality + the
// artist first-word rule). Title-only ONLY when the artist is really
// unknown (RecommendationEngine.isPollutedArtist).
//
// Shape: sources run concurrently WITHIN a phase (one phase per
// priority band), and phases run in order — in-app matches are
// preferred over any external match, every attempted source is
// logged, and each source is bounded by [perSourceTimeout]. The
// Spotify phase runs only when no in-app match was found yet, so a
// Spotify call is never spent on a track Audius already had.
//
// Every resolve records one [ResolutionEntry] in the [ResolutionLog]
// (when given): track + each source tried + outcome + detail. Cache:
// successful IN-APP resolutions (stream URL per normalized key) are
// cached; failures are NEVER cached (a failed source may succeed
// later); external matches are not cached (links rot, and re-finding
// them is cheap).
//
// NO audio extraction, NO yt-dlp-style downloading, NO signature
// decipherer, NO PO-token solver. In-app YouTube audio comes only
// from the VISIONOS player response's plain stream URLs — never a
// cipher, never a minted token.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../discover/audius_client.dart';
import '../discover/jamendo_client.dart';
import '../engine/recommendation_engine.dart';
import '../export/visionos_player_client.dart';
import '../export/youtube_export.dart';
import '../fallback/fallback_sources.dart';
import '../models/music_models.dart';
import '../platforms/music_platform.dart';
import 'resolution_log.dart';

/// Where a full-song match plays.
enum FullSongSource { ownStream, audius, jamendo, youtube, deezer, itunes }

/// Why a resolve ended without a match.
enum FullSongFailure {
  /// No source had a strict full-stream (or link) match.
  noStream,

  /// At least one source could not be reached; the named source is in
  /// [FullSongResolveResult.networkSource].
  network,

  /// Spotify found the canonical track, but its audio cannot play
  /// in-app (DRM) and no other source had a playable stream or link.
  spotifyAudioUnavailable,
}

/// One strict full-song match. Exactly one of [streamUrl] (in-app) or
/// [externalUrl] (outbound) is set.
class FullSongMatch {
  final FullSongSource source;

  /// Full-stream URL for in-app playback (own stream / Audius /
  /// Jamendo only).
  final String? streamUrl;

  /// Page/video link for outbound playback (YouTube / Deezer / iTunes).
  final String? externalUrl;

  /// True when this match came from the Spotify-corrected re-resolve
  /// (step 5) rather than the original metadata.
  final bool viaSpotify;

  const FullSongMatch({
    required this.source,
    this.streamUrl,
    this.externalUrl,
    this.viaSpotify = false,
  });

  /// True when this match plays in-app (a streamUrl is present).
  bool get playInApp => streamUrl != null && streamUrl!.isNotEmpty;

  /// Human label for tooltips / logs. Never "preview".
  String get label {
    switch (source) {
      case FullSongSource.ownStream:
        return 'Stream';
      case FullSongSource.audius:
        return 'Audius';
      case FullSongSource.jamendo:
        return 'Jamendo';
      case FullSongSource.youtube:
        return 'YouTube';
      case FullSongSource.deezer:
        return 'Deezer';
      case FullSongSource.itunes:
        return 'iTunes';
    }
  }

  /// Short label for the stream-source map (PreviewButton labels +
  /// logs): 'spotify-corrected' when the match came from the
  /// Spotify-corrected re-resolve, else the source name.
  String get sourceLabel => viaSpotify ? 'spotify-corrected' : source.name;
}

/// The outcome of one [FullSongResolver.resolve] call: the match (or
/// null) plus every source attempt, so the caller can log it and tell
/// the user WHY nothing played.
class FullSongResolveResult {
  final FullSongMatch? match;

  /// Per-source attempts, in the order they ran.
  final List<SourceAttempt> attempts;

  /// Why there is no match (null when [match] is present).
  final FullSongFailure? failure;

  /// First source that failed with a network error, if any (used for
  /// the "Couldn't reach <source>" message).
  final String? networkSource;

  /// True when the Spotify search found the canonical track but the
  /// re-resolve found nothing playable for it.
  final bool spotifyFoundTrack;

  const FullSongResolveResult({
    required this.match,
    required this.attempts,
    this.failure,
    this.networkSource,
    this.spotifyFoundTrack = false,
  });
}

/// What the full-song routing should do next. [noMatch] means no
/// source matched strictly — the caller reports the failure reason
/// (see [FullSongResolveResult.failure]) instead of falling back to a
/// preview (there are no previews anymore). [openFailed] means an
/// external winner was found but the outbound launch failed.
enum FullSongAction { playInApp, openExternal, noMatch, openFailed }

/// Resolves a track to a full song, in priority order, logging every
/// source attempted. See the file header for the rules.
class FullSongResolver {
  final FallbackSources _fallbacks;
  final AudiusClient? _audius;
  final JamendoClient? _jamendo;
  final YouTubeVideoResolver? _youtube;

  /// VISIONOS player client (videoId → direct audio URL), or null
  /// when the YTM rung is finder-only (then every YTM match stays
  /// external, as before this rung existed).
  final VisionOsPlayerClient? _visionOs;

  /// Spotify metadata search (query → canonical tracks), or null when
  /// Spotify is not signed in / not wired. Injected as a callback so
  /// the resolver stays testable without a real Spotify session.
  final Future<List<Track>> Function(String query)? _spotifySearch;

  /// Resolution log (may be null in unit tests that only assert the
  /// match). Every resolve records one entry here.
  final ResolutionLog? _log;

  /// Per-source timeout: no single source may hold a phase longer
  /// than this. Phases run in order, so the whole resolve is bounded
  /// by roughly this × the number of phases actually run (in-app hit
  /// ends it after phase 1; the Spotify phase only runs when phase 1
  /// found no in-app match).
  static const Duration perSourceTimeout = Duration(seconds: 8);

  /// Successful in-app resolutions, keyed by normalized track key.
  /// Failures are never cached; external matches are not cached.
  final Map<String, FullSongMatch> _cache = {};

  FullSongResolver({
    required FallbackSources fallbacks,
    AudiusClient? audius,
    JamendoClient? jamendo,
    YouTubeVideoResolver? youtube,
    VisionOsPlayerClient? visionOs,
    Future<List<Track>> Function(String query)? spotifySearch,
    ResolutionLog? log,
  })  : _fallbacks = fallbacks,
        _audius = audius,
        _jamendo = jamendo,
        _youtube = youtube,
        _visionOs = visionOs,
        _spotifySearch = spotifySearch,
        _log = log;

  /// Cleaned-title equality (see the file header for the rule).
  static bool titlesMatch(String resultTitle, String wantedTitle) {
    final x = RecommendationEngine.cleanTrackTitle(resultTitle)
        .toLowerCase()
        .trim();
    final y =
        RecommendationEngine.cleanTrackTitle(wantedTitle).toLowerCase().trim();
    return x.isNotEmpty && x == y;
  }

  /// Artist-word check. True when the wanted artist is polluted
  /// (check skipped — title-only is the rule there) or the result
  /// artist contains the primary artist's first word. Applies to
  /// Audius too now: its artist is the uploader's name/handle, but
  /// the brief requires the check whenever the artist is clean.
  static bool artistMatches(String resultArtist, Track track) {
    if (RecommendationEngine.isPollutedArtist(track.artist)) return true;
    final first =
        RecommendationEngine.artistFirstWord(track.artist).toLowerCase();
    if (first.isEmpty) return true;
    return resultArtist.toLowerCase().contains(first);
  }

  /// YouTube displayed-title matching (see the file header). The
  /// cleaned video title must equal the cleaned wanted title, or
  /// equal it after stripping a leading "<primary artist> - " prefix
  /// (cleanTrackTitle already strips "(Official Video)"-style
  /// parentheticals and bracket segments).
  static bool youtubeTitleMatches(String videoTitle, Track track) {
    final cleanedVideo = RecommendationEngine.cleanTrackTitle(videoTitle)
        .toLowerCase()
        .trim();
    final wanted =
        RecommendationEngine.cleanTrackTitle(track.title).toLowerCase().trim();
    if (cleanedVideo.isNotEmpty && cleanedVideo == wanted) return true;
    if (RecommendationEngine.isPollutedArtist(track.artist)) return false;
    final artist =
        RecommendationEngine.primaryArtist(track.artist).toLowerCase().trim();
    if (artist.isEmpty) return false;
    for (final sep in [' - ', ' – ', ' — ', ': ']) {
      final prefix = '$artist$sep';
      if (cleanedVideo.startsWith(prefix)) {
        if (cleanedVideo.substring(prefix.length).trim() == wanted) {
          return true;
        }
      }
    }
    return false;
  }

  /// Resolve [track] to a full song. Never throws: a failing source
  /// is recorded in the attempts and the resolve continues.
  Future<FullSongResolveResult> resolve(Track track) async {
    final attempts = <SourceAttempt>[];
    final key = RecommendationEngine.normalizeKey(track.artist, track.title);

    // Cached in-app success: no network, no re-check.
    final cached = _cache[key];
    if (cached != null) {
      attempts.add(SourceAttempt(
        source: cached.source.name,
        outcome: SourceOutcome.matched,
        detail: 'Cached ${cached.label} match',
      ));
      _record(track, attempts, 'Cached ${cached.label} stream');
      return FullSongResolveResult(match: cached, attempts: attempts);
    }

    // 1. The track's own full stream (Audius/Jamendo-imported).
    if (track.streamUrl != null && track.streamUrl!.isNotEmpty) {
      final match = FullSongMatch(
          source: FullSongSource.ownStream, streamUrl: track.streamUrl);
      attempts.add(const SourceAttempt(
        source: 'own stream',
        outcome: SourceOutcome.matched,
        detail: 'Track carries its own full stream URL',
      ));
      _cacheMatch(key, match);
      _record(track, attempts, 'Own stream');
      return FullSongResolveResult(match: match, attempts: attempts);
    }
    attempts.add(const SourceAttempt(
      source: 'own stream',
      outcome: SourceOutcome.noMatch,
      detail: 'Track has no stream URL',
    ));

    // Phases 2–4 + 6, concurrently: Audius, Jamendo, YTM finder,
    // Deezer link, iTunes link. All attempts are awaited (bounded by
    // perSourceTimeout each) so every source is logged and the winner
    // is picked by PRIORITY, not by arrival order.
    final phase1 = await Future.wait([
      _audiusMatch(track, attempts),
      _jamendoMatch(track, attempts),
      _youtubeMatch(track, attempts),
      _deezerMatch(track, attempts),
      _itunesMatch(track, attempts),
    ]);

    // In-app beats external: first playInApp match in priority
    // order (Audius, Jamendo, YouTube via VISIONOS).
    FullSongMatch? match;
    for (final candidate in phase1) {
      if (candidate != null && candidate.playInApp) {
        match = candidate;
        break;
      }
    }
    if (match != null) {
      _cacheMatch(key, match);
      _record(track, attempts, '${match.label} stream');
      return FullSongResolveResult(match: match, attempts: attempts);
    }

    // 5. Spotify metadata search → one re-resolve round with the
    // corrected title/artist (Audius + YTM finder only). Runs only
    // when no in-app match was found yet.
    var spotifyFoundTrack = false;
    if (_spotifySearch != null) {
      final canonical = await _spotifyMatch(track, attempts);
      if (canonical != null) {
        spotifyFoundTrack = true;
        final corrected = Track(
          title: canonical.title,
          artist: canonical.artist,
          album: canonical.album,
          imageUrl: canonical.imageUrl,
          durationMs: canonical.durationMs,
          platformTrackId: canonical.platformTrackId,
        );
        final reResolved = await Future.wait([
          _audiusMatch(corrected, attempts,
              sourceLabel: 'spotify-audius', viaSpotify: true),
          _youtubeMatch(corrected, attempts,
              sourceLabel: 'spotify-youtube', viaSpotify: true),
        ]);
        match = reResolved[0] ?? reResolved[1];
        if (match != null) {
          if (match.playInApp) _cacheMatch(key, match);
          _record(
              track,
              attempts,
              match.playInApp
                  ? '${match.label} stream (via Spotify)'
                  : '${match.label} link (via Spotify)');
          return FullSongResolveResult(match: match, attempts: attempts);
        }
      }
    } else {
      attempts.add(const SourceAttempt(
        source: 'spotify',
        outcome: SourceOutcome.skipped,
        detail: 'Spotify is not signed in',
      ));
    }

    // 6 (already attempted): the best external match from phase 1 —
    // YTM finder first, then Deezer, then iTunes.
    match = phase1[2] ?? phase1[3] ?? phase1[4];
    if (match != null) {
      _record(track, attempts, '${match.label} link');
      return FullSongResolveResult(match: match, attempts: attempts);
    }

    // Nothing matched. Classify the failure for the SnackBar.
    final networkAttempt = attempts.firstWhere(
      (a) => a.outcome == SourceOutcome.networkError,
      orElse: () => const SourceAttempt(
          source: '', outcome: SourceOutcome.noMatch, detail: ''),
    );
    final failure = spotifyFoundTrack
        ? FullSongFailure.spotifyAudioUnavailable
        : networkAttempt.source.isNotEmpty
            ? FullSongFailure.network
            : FullSongFailure.noStream;
    _record(
      track,
      attempts,
      failure == FullSongFailure.spotifyAudioUnavailable
          ? 'Found on Spotify — audio cannot play in-app'
          : failure == FullSongFailure.network
              ? 'Could not reach ${networkAttempt.source}'
              : 'No full stream found',
    );
    return FullSongResolveResult(
      match: null,
      attempts: attempts,
      failure: failure,
      networkSource:
          networkAttempt.source.isNotEmpty ? networkAttempt.source : null,
      spotifyFoundTrack: spotifyFoundTrack,
    );
  }

  void _cacheMatch(String key, FullSongMatch match) {
    if (match.playInApp) _cache[key] = match;
  }

  void _record(
      Track track, List<SourceAttempt> attempts, String result) {
    _log?.record(ResolutionEntry.forTrack(
      track,
      attempts: attempts,
      result: result,
    ));
  }

  /// Classify a source failure for the log: network-looking errors
  /// (timeouts / connection failures) vs a session rejection vs a
  /// plain miss. Returns (outcome, detail).
  static (SourceOutcome, String) _classifyError(Object e) {
    if (e is PlatformException && e.authExpired) {
      return (SourceOutcome.sessionRejected,
          'Session rejected — sign in again');
    }
    if (e is TimeoutException) {
      return (SourceOutcome.networkError, 'Timed out');
    }
    if (e is SocketException) {
      return (SourceOutcome.networkError, e.message);
    }
    if (e is DioException) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.connectionError:
        case DioExceptionType.badCertificate:
          return (
            SourceOutcome.networkError,
            e.message ?? e.error?.toString() ?? 'Connection failed'
          );
        case DioExceptionType.badResponse:
          return (
            SourceOutcome.noMatch,
            'HTTP ${e.response?.statusCode ?? 'error'}'
          );
        case DioExceptionType.cancel:
        case DioExceptionType.unknown:
          final inner = e.error;
          if (inner is SocketException) {
            return (SourceOutcome.networkError, inner.message);
          }
          return (SourceOutcome.noMatch, e.message ?? 'Request failed');
      }
    }
    return (SourceOutcome.noMatch, e.toString());
  }

  Future<FullSongMatch?> _audiusMatch(
    Track track,
    List<SourceAttempt> attempts, {
    String sourceLabel = 'audius',
    bool viaSpotify = false,
  }) async {
    final client = _audius;
    if (client == null) {
      attempts.add(SourceAttempt(
        source: sourceLabel,
        outcome: SourceOutcome.skipped,
        detail: viaSpotify ? 'Spotify-corrected re-resolve' : 'No client',
      ));
      return null;
    }
    try {
      // Title-only query: a polluted artist string would poison the
      // search. The ARTIST CHECK still applies to the results
      // whenever the artist is clean (see artistMatches).
      final query = RecommendationEngine.cleanTrackTitle(track.title);
      final results =
          await client.searchTracks(query, limit: 5).timeout(perSourceTimeout);
      var titleMatched = false;
      for (final result in results) {
        if (result.streamUrl == null || result.streamUrl!.isEmpty) continue;
        if (!titlesMatch(result.title, track.title)) continue;
        titleMatched = true;
        if (!artistMatches(result.artist, track)) continue;
        attempts.add(SourceAttempt(
          source: sourceLabel,
          outcome: SourceOutcome.matched,
          detail: viaSpotify
              ? 'Spotify-corrected title/artist matched'
              : 'Title + artist matched',
        ));
        return FullSongMatch(
          source: FullSongSource.audius,
          streamUrl: result.streamUrl,
          viaSpotify: viaSpotify,
        );
      }
      attempts.add(SourceAttempt(
        source: sourceLabel,
        outcome: SourceOutcome.noMatch,
        detail: titleMatched
            ? 'Title matched but artist did not match'
            : 'No title match',
      ));
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(SourceAttempt(
          source: sourceLabel, outcome: outcome, detail: detail));
    }
    return null;
  }

  Future<FullSongMatch?> _jamendoMatch(
    Track track,
    List<SourceAttempt> attempts,
  ) async {
    final client = _jamendo;
    if (client == null) {
      attempts.add(const SourceAttempt(
        source: 'jamendo',
        outcome: SourceOutcome.skipped,
        detail: 'No client_id set',
      ));
      return null;
    }
    try {
      final query = RecommendationEngine.cleanTrackTitle(track.title);
      final results =
          await client.searchTracks(query, limit: 5).timeout(perSourceTimeout);
      var titleMatched = false;
      for (final result in results) {
        if (result.streamUrl == null || result.streamUrl!.isEmpty) continue;
        if (!titlesMatch(result.title, track.title)) continue;
        titleMatched = true;
        if (!artistMatches(result.artist, track)) continue;
        attempts.add(const SourceAttempt(
          source: 'jamendo',
          outcome: SourceOutcome.matched,
          detail: 'Title + artist matched',
        ));
        return FullSongMatch(
            source: FullSongSource.jamendo, streamUrl: result.streamUrl);
      }
      attempts.add(SourceAttempt(
        source: 'jamendo',
        outcome: SourceOutcome.noMatch,
        detail: titleMatched
            ? 'Title matched but artist did not match'
            : 'No title match',
      ));
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(
          SourceAttempt(source: 'jamendo', outcome: outcome, detail: detail));
    }
    return null;
  }

  Future<FullSongMatch?> _youtubeMatch(
    Track track,
    List<SourceAttempt> attempts, {
    String sourceLabel = 'youtube',
    bool viaSpotify = false,
  }) async {
    final resolver = _youtube;
    if (resolver == null) {
      attempts.add(SourceAttempt(
        source: sourceLabel,
        outcome: SourceOutcome.skipped,
        detail: viaSpotify ? 'Spotify-corrected re-resolve' : 'No client',
      ));
      return null;
    }
    try {
      final pair = await resolver
          .resolveVideoWithTitle(track)
          .timeout(perSourceTimeout);
      if (pair == null) {
        attempts.add(SourceAttempt(
          source: sourceLabel,
          outcome: SourceOutcome.noMatch,
          detail: 'No video found',
        ));
        return null;
      }
      if (!youtubeTitleMatches(pair.title, track)) {
        attempts.add(SourceAttempt(
          source: sourceLabel,
          outcome: SourceOutcome.noMatch,
          detail: 'Video title "${pair.title}" did not match strictly',
        ));
        return null;
      }
      // VISIONOS rung: the finder videoId may carry a playable
      // in-app audio URL. On failure the match stays external and
      // the log records why (bot-gated / no direct audio URL /
      // network) — a VISIONOS failure is a fall-through, never an
      // error that aborts the resolve.
      final visionOs = _visionOs;
      if (visionOs != null) {
        try {
          final audio = await visionOs
              .resolveAudioUrl(pair.videoId)
              .timeout(perSourceTimeout);
          if (audio.url != null) {
            attempts.add(SourceAttempt(
              source: sourceLabel,
              outcome: SourceOutcome.matched,
              detail: 'YouTube audio stream via VISIONOS'
                  ' (itag ${audio.itag})',
            ));
            return FullSongMatch(
              source: FullSongSource.youtube,
              streamUrl: audio.url,
              viaSpotify: viaSpotify,
            );
          }
          attempts.add(SourceAttempt(
            source: sourceLabel,
            outcome: SourceOutcome.noDirectUrl,
            detail: audio.failure == VisionOsFailure.botGated
                ? 'Video ${pair.videoId} found — no direct audio URL'
                    ' (bot-gated)'
                : 'Video ${pair.videoId} found — no direct audio URL',
          ));
        } catch (e) {
          final (outcome, detail) = _classifyError(e);
          attempts.add(SourceAttempt(
              source: sourceLabel, outcome: outcome, detail: detail));
          // Fall through to the external match below.
        }
      } else {
        attempts.add(SourceAttempt(
          source: sourceLabel,
          outcome: SourceOutcome.noDirectUrl,
          detail: 'Video ${pair.videoId} found — no direct audio URL',
        ));
      }
      return FullSongMatch(
        source: FullSongSource.youtube,
        externalUrl: 'https://www.youtube.com/watch?v=${pair.videoId}',
        viaSpotify: viaSpotify,
      );
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(SourceAttempt(
          source: sourceLabel, outcome: outcome, detail: detail));
      return null;
    }
  }

  /// Spotify metadata search for the canonical track. Returns the
  /// best track, or null when the search found nothing / failed
  /// (a failure is logged and the chain continues without Spotify).
  Future<Track?> _spotifyMatch(
    Track track,
    List<SourceAttempt> attempts,
  ) async {
    final search = _spotifySearch;
    if (search == null) return null;
    try {
      final query =
          '${RecommendationEngine.primaryArtist(track.artist)} ${RecommendationEngine.cleanTrackTitle(track.title)}'
              .trim();
      final results = await search(query).timeout(perSourceTimeout);
      if (results.isEmpty) {
        attempts.add(const SourceAttempt(
          source: 'spotify',
          outcome: SourceOutcome.noMatch,
          detail: 'Search found no tracks',
        ));
        return null;
      }
      final canonical = results.first;
      attempts.add(SourceAttempt(
        source: 'spotify',
        outcome: SourceOutcome.matched,
        detail:
            'Canonical track: "${canonical.title}" by ${canonical.artist} (metadata only — audio cannot play in-app)',
      ));
      return canonical;
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(
          SourceAttempt(source: 'spotify', outcome: outcome, detail: detail));
      return null;
    }
  }

  Future<FullSongMatch?> _deezerMatch(
    Track track,
    List<SourceAttempt> attempts,
  ) async {
    try {
      final link = await _fallbacks
          .deezerTrackLink(track.artist, track.title)
          .timeout(perSourceTimeout);
      if (link == null || link.isEmpty) {
        attempts.add(const SourceAttempt(
          source: 'deezer',
          outcome: SourceOutcome.noMatch,
          detail: 'No strict link match',
        ));
        return null;
      }
      attempts.add(const SourceAttempt(
        source: 'deezer',
        outcome: SourceOutcome.matched,
        detail: 'Strict link match',
      ));
      return FullSongMatch(source: FullSongSource.deezer, externalUrl: link);
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(
          SourceAttempt(source: 'deezer', outcome: outcome, detail: detail));
      return null;
    }
  }

  Future<FullSongMatch?> _itunesMatch(
    Track track,
    List<SourceAttempt> attempts,
  ) async {
    try {
      final link = await _fallbacks
          .itunesTrackLink(track.artist, track.title)
          .timeout(perSourceTimeout);
      if (link == null || link.isEmpty) {
        attempts.add(const SourceAttempt(
          source: 'itunes',
          outcome: SourceOutcome.noMatch,
          detail: 'No strict link match',
        ));
        return null;
      }
      attempts.add(const SourceAttempt(
        source: 'itunes',
        outcome: SourceOutcome.matched,
        detail: 'Strict link match',
      ));
      return FullSongMatch(source: FullSongSource.itunes, externalUrl: link);
    } catch (e) {
      final (outcome, detail) = _classifyError(e);
      attempts.add(
          SourceAttempt(source: 'itunes', outcome: outcome, detail: detail));
      return null;
    }
  }
}

/// Thin routing layer over [FullSongResolver] so the routing decision
/// (in-app vs outbound vs no match) is unit-testable without a widget
/// or a real audio player / url_launcher. The player wires the
/// callbacks to AudioPlayerNotifier._playResolved, openLinkInAppFirst,
/// and its failure reporting — there is no preview fallback anymore.
class FullSongService {
  final FullSongResolver resolver;

  const FullSongService(this.resolver);

  Future<FullSongAction> act(
    Track track, {
    required Future<void> Function(Track track, String streamUrl, String source)
        onInApp,
    required Future<bool> Function(Uri uri) onExternal,
    required Future<void> Function(FullSongResolveResult result) onNoMatch,
  }) async {
    final result = await resolver.resolve(track);
    final match = result.match;
    if (match == null) {
      await onNoMatch(result);
      return FullSongAction.noMatch;
    }
    if (match.playInApp) {
      await onInApp(track, match.streamUrl!, match.sourceLabel);
      return FullSongAction.playInApp;
    }
    final opened = await onExternal(Uri.parse(match.externalUrl!));
    return opened ? FullSongAction.openExternal : FullSongAction.openFailed;
  }
}
