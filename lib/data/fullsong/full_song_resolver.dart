// Hybrid "Play full song" race (see the task brief): find a full song
// for a track by racing platform lookups CONCURRENTLY and playing the
// first STRICT match. This is deliberately not the sequential preview
// chain — sequential lookups are what made on-demand previews slow and
// flaky (each tap re-ran the whole chain, and misses are not cached).
//
// Strict-matching rule (documented here, because a race must never play
// the wrong song):
//   * The cleaned result title MUST equal the cleaned wanted title.
//     Cleaning is RecommendationEngine.cleanTrackTitle (parentheticals,
//     bracket segments, feat. credits, TV-size/short-ver/radio-edit
//     suffixes stripped), compared lowercased and trimmed. This is the
//     same helper the preview chain's strict title-only steps use.
//   * Artist check: when the wanted artist is clean (not polluted), the
//     result artist must contain the primary artist's first word
//     ("A feat. B" -> "A" -> first word "a"). When the wanted artist
//     is polluted (empty or "Unknown artist" — the YTM case), the
//     artist check is SKIPPED: a polluted artist must never veto an
//     otherwise exact title match.
//   * Audius is the exception to the artist check: its "artist" is the
//     uploader's name/handle, not necessarily the recording artist, so
//     Audius matches on cleaned title only (exactly as the preview
//     chain's Audius last resort already does).
//   * YouTube titles are messy ("Artist - Title (Official Video)");
//     see [FullSongResolver.youtubeTitleMatches]: the cleaned video
//     title must equal the cleaned wanted title, or equal it after
//     stripping a leading "<primary artist> - " prefix (the
//     "(Official Video)" part is already removed by cleanTrackTitle).
//     A channel-prefixed title ("Some Channel - Song") for a polluted
//     artist is REJECTED — the safe direction, since the channel name
//     is not the artist and cannot verify the match.
//   * Deezer / iTunes links are matched inside FallbackSources
//     (deezerTrackLink / itunesTrackLink) under the same rule: cleaned
//     title equality plus the artist-word check when the artist is
//     clean, and NO first-result fallback anywhere.
//
// How the winner plays (labelled honestly):
//   * Audius / Jamendo winners carry a streamUrl and play IN-APP via
//     AudioPlayerNotifier.playStream (a full track, never called a
//     "preview").
//   * YouTube / Deezer / iTunes winners carry an externalUrl and are
//     opened via openLinkInAppFirst, so they play full in that
//     platform's app (or its web player as fallback). Full playback
//     there depends on the user's account in that app.
//   * No match -> the caller falls back to the 30s preview chain
//     (see [FullSongService]); a loose/wrong match is never played.
//
// Keyless everywhere except Jamendo, which is only constructed when
// the user has set a client_id (see fullSongResolverProvider). A
// source that throws, times out, or returns no strict match simply
// yields null and never blocks the others. NO audio extraction, NO
// yt-dlp-style downloading, NO in-app YouTube player — YouTube is an
// outbound link only.

import 'dart:async';

import '../discover/audius_client.dart';
import '../discover/jamendo_client.dart';
import '../engine/recommendation_engine.dart';
import '../export/youtube_export.dart';
import '../fallback/fallback_sources.dart';
import '../models/music_models.dart';

/// Where a full-song match plays.
enum FullSongSource { audius, jamendo, youtube, deezer, itunes }

/// One strict full-song match. Exactly one of [streamUrl] (in-app) or
/// [externalUrl] (outbound) is set.
class FullSongMatch {
  final FullSongSource source;

  /// Full-stream URL for in-app playback (Audius / Jamendo only).
  final String? streamUrl;

  /// Page/video link for outbound playback (YouTube / Deezer / iTunes).
  final String? externalUrl;

  const FullSongMatch({
    required this.source,
    this.streamUrl,
    this.externalUrl,
  });

  /// True when this match plays in-app (a streamUrl is present).
  bool get playInApp => streamUrl != null && streamUrl!.isNotEmpty;

  /// Human label for tooltips / logs. Never "preview".
  String get label {
    switch (source) {
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
}

/// What the full-song button should do next. [previewFallback] means
/// no source matched strictly, so the caller plays the 30s preview
/// chain instead (and says so in the UI). [openFailed] means an
/// external winner was found but the outbound launch failed.
enum FullSongAction { playInApp, openExternal, previewFallback, openFailed }

/// Races platform lookups concurrently and returns the first STRICT
/// match to complete, or null when nothing matches strictly. Late
/// results are ignored; a failing source never blocks the others.
class FullSongResolver {
  final FallbackSources _fallbacks;
  final AudiusClient? _audius;
  final JamendoClient? _jamendo;
  final YouTubeVideoResolver? _youtube;

  /// Per-source timeout: the race as a whole never waits longer than
  /// this plus scheduling for any single source. Short on purpose —
  /// a slow source must not hold the button hostage.
  static const Duration perSourceTimeout = Duration(seconds: 8);

  const FullSongResolver({
    required FallbackSources fallbacks,
    AudiusClient? audius,
    JamendoClient? jamendo,
    YouTubeVideoResolver? youtube,
  })  : _fallbacks = fallbacks,
        _audius = audius,
        _jamendo = jamendo,
        _youtube = youtube;

  /// Cleaned-title equality (see the file header for the rule).
  static bool titlesMatch(String resultTitle, String wantedTitle) {
    final x = RecommendationEngine.cleanTrackTitle(resultTitle)
        .toLowerCase()
        .trim();
    final y =
        RecommendationEngine.cleanTrackTitle(wantedTitle).toLowerCase().trim();
    return x.isNotEmpty && x == y;
  }

  /// Artist-word check for sources whose artist metadata is reliable
  /// (Deezer / iTunes / Jamendo). True when the wanted artist is
  /// polluted (check skipped) or the result artist contains the
  /// primary artist's first word.
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

  /// The race. All source lookups start immediately and run
  /// concurrently; the first one to complete with a strict match wins
  /// and later completions are ignored. Nulls and throws settle that
  /// source without affecting the others.
  Future<FullSongMatch?> resolve(Track track) async {
    final tasks = <Future<FullSongMatch?>>[];
    if (_audius != null) tasks.add(_audiusMatch(track));
    if (_jamendo != null) tasks.add(_jamendoMatch(track));
    if (_youtube != null) tasks.add(_youtubeMatch(track));
    tasks.add(_deezerMatch(track));
    tasks.add(_itunesMatch(track));
    if (tasks.isEmpty) return null;
    final completer = Completer<FullSongMatch?>();
    var remaining = tasks.length;
    void settle() {
      remaining--;
      if (remaining == 0 && !completer.isCompleted) {
        completer.complete(null);
      }
    }

    for (final task in tasks) {
      task.then((match) {
        if (match != null && !completer.isCompleted) {
          completer.complete(match);
        }
        settle();
      }, onError: (_) => settle());
    }
    return completer.future;
  }

  Future<FullSongMatch?> _audiusMatch(Track track) async {
    final client = _audius;
    if (client == null) return null;
    try {
      // Title-only query: a polluted artist string would poison the
      // search, and Audius artist metadata is the uploader, not the
      // recording artist, so the artist is never checked here.
      final query = RecommendationEngine.cleanTrackTitle(track.title);
      final results =
          await client.searchTracks(query, limit: 5).timeout(perSourceTimeout);
      for (final result in results) {
        if (result.streamUrl == null || result.streamUrl!.isEmpty) continue;
        if (titlesMatch(result.title, track.title)) {
          return FullSongMatch(
              source: FullSongSource.audius, streamUrl: result.streamUrl);
        }
      }
    } catch (_) {
      // A dead/slow Audius never blocks the other sources.
    }
    return null;
  }

  Future<FullSongMatch?> _jamendoMatch(Track track) async {
    final client = _jamendo;
    if (client == null) return null;
    try {
      final query = RecommendationEngine.cleanTrackTitle(track.title);
      final results =
          await client.searchTracks(query, limit: 5).timeout(perSourceTimeout);
      for (final result in results) {
        if (result.streamUrl == null || result.streamUrl!.isEmpty) continue;
        if (!titlesMatch(result.title, track.title)) continue;
        if (!artistMatches(result.artist, track)) continue;
        return FullSongMatch(
            source: FullSongSource.jamendo, streamUrl: result.streamUrl);
      }
    } catch (_) {
      // Same as Audius: a dead/slow Jamendo never blocks the others.
    }
    return null;
  }

  Future<FullSongMatch?> _youtubeMatch(Track track) async {
    final resolver = _youtube;
    if (resolver == null) return null;
    try {
      final pair = await resolver
          .resolveVideoWithTitle(track)
          .timeout(perSourceTimeout);
      if (pair == null) return null;
      if (!youtubeTitleMatches(pair.title, track)) return null;
      return FullSongMatch(
        source: FullSongSource.youtube,
        externalUrl: 'https://www.youtube.com/watch?v=${pair.videoId}',
      );
    } catch (_) {
      return null;
    }
  }

  Future<FullSongMatch?> _deezerMatch(Track track) async {
    try {
      final link = await _fallbacks
          .deezerTrackLink(track.artist, track.title)
          .timeout(perSourceTimeout);
      if (link == null || link.isEmpty) return null;
      return FullSongMatch(source: FullSongSource.deezer, externalUrl: link);
    } catch (_) {
      return null;
    }
  }

  Future<FullSongMatch?> _itunesMatch(Track track) async {
    try {
      final link = await _fallbacks
          .itunesTrackLink(track.artist, track.title)
          .timeout(perSourceTimeout);
      if (link == null || link.isEmpty) return null;
      return FullSongMatch(source: FullSongSource.itunes, externalUrl: link);
    } catch (_) {
      return null;
    }
  }
}

/// Thin routing layer over [FullSongResolver] so the routing decision
/// (in-app vs outbound vs preview fallback) is unit-testable without
/// a widget or a real audio player / url_launcher. The button wires
/// the callbacks to AudioPlayerNotifier.playStream, openLinkInAppFirst,
/// and AudioPlayerNotifier.play (preview fallback).
class FullSongService {
  final FullSongResolver resolver;

  const FullSongService(this.resolver);

  Future<FullSongAction> act(
    Track track, {
    required Future<void> Function(Track track, String streamUrl, String source)
        onInApp,
    required Future<bool> Function(Uri uri) onExternal,
    required Future<void> Function(Track track) onPreviewFallback,
  }) async {
    final match = await resolver.resolve(track);
    if (match == null) {
      await onPreviewFallback(track);
      return FullSongAction.previewFallback;
    }
    if (match.playInApp) {
      await onInApp(track, match.streamUrl!, match.source.name);
      return FullSongAction.playInApp;
    }
    final opened = await onExternal(Uri.parse(match.externalUrl!));
    return opened ? FullSongAction.openExternal : FullSongAction.openFailed;
  }
}
