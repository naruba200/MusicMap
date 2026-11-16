// VISIONOS player client (full-song pivot, VISIONOS rung): resolve a
// YouTube videoId to a playable in-app audio URL via the InnerTube
// `youtubei/v1/player` endpoint with the VISIONOS client shape.
//
// Verified live 2026-11-15 (script
// ~/workspace/musicman-player/spikes/ytm_player_spike_visionos.py):
// `dQw4w9WgXcQ` → playability OK, 27 formats, 5 audio with plain
// URLs (itag 139/140/249/250/251); the itag 251 URL was fetched —
// HTTP 206, 4096 bytes, real WebM audio. The WEB / ANDROID / IOS /
// EMBEDDED shapes return zero audio URLs for the same videos
// (PO-token gated), so VISIONOS is the only client shape that serves
// direct audio URLs without a token.
//
// Caveat: two other test videos returned LOGIN_REQUIRED "Sign in to
// confirm you're not a bot" from a datacenter IP — likely IP
// reputation, and a phone on mobile data may do better. The resolver
// treats that as a normal fall-through (external handoff), never as
// an error, and phone QA is the decider.
//
// No signature decipherer, no PO-token solver: only formats carrying
// a plain `url` are ever used; `signatureCipher` entries are ignored
// entirely.

import 'dart:convert';

import 'package:dio/dio.dart';

/// Why a player call returned no audio URL.
enum VisionOsFailure {
  /// playabilityStatus LOGIN_REQUIRED — YouTube's bot check gated
  /// this video from this network.
  botGated,

  /// Playable status but no audio-only format with a plain URL.
  noAudioUrl,
}

/// Resolves a YouTube videoId to a direct audio-only stream URL via
/// the VISIONOS InnerTube player shape.
class VisionOsPlayerClient {
  final Dio _dio;

  // The well-known public InnerTube web-client key (the one yt-dlp
  // and the VISIONOS spike use). The app's other youtubei calls
  // (search/browse) need no key; the player endpoint requires the
  // `key` query param.
  static const _apiKey = 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';

  static const _playerUrl =
      'https://www.youtube.com/youtubei/v1/player?key=$_apiKey';

  // Safari on macOS 15, matching the VISIONOS client identity (the
  // spike's working shape). Must stay in sync with clientVersion.
  static const _userAgent =
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) '
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 '
      'Safari/605.1.15';

  /// Preferred audio itags, best first: 251 Opus ~160kbps, 140 m4a
  /// ~128kbps, 250 Opus ~70kbps, 249 Opus ~50kbps, 139 m4a ~48kbps.
  static const List<int> preferredItags = [251, 140, 250, 249, 139];

  VisionOsPlayerClient(this._dio);

  /// Best audio-only stream URL for [videoId], or (null, failure)
  /// when the player endpoint gives no playable audio. Transport
  /// errors (timeout / connection failure) propagate as DioException
  /// so the caller can log them as network errors instead of
  /// misreporting them as "no direct audio URL".
  Future<({String? url, int? itag, VisionOsFailure? failure})>
      resolveAudioUrl(String videoId) async {
    final res = await _dio.post(
      _playerUrl,
      data: {
        'context': {
          'client': {
            'clientName': 'VISIONOS',
            'clientVersion': '1.02',
            'hl': 'en',
            'gl': 'US',
          },
        },
        'videoId': videoId,
        'racyCheckOk': true,
        'contentCheckOk': true,
      },
      options: Options(
        headers: {'User-Agent': _userAgent},
        // The player call is a read-only query over POST — opt in to
        // connection retries so TLS-resetting networks recover the
        // way the youtubei search calls do. Never set this on an
        // OAuth POST.
        extra: const {'retryReadOnly': true},
      ),
    );
    final data = res.data;
    if (data is Map<String, dynamic>) return parsePlayerResponse(data);
    if (data is String) {
      return parsePlayerResponse(jsonDecode(data) as Map<String, dynamic>);
    }
    return (url: null, itag: null, failure: VisionOsFailure.noAudioUrl);
  }

  /// Pure parse of a player envelope: bot-gated, best audio URL by
  /// [preferredItags], or no-audio failure. Unit-testable without a
  /// network call.
  static ({String? url, int? itag, VisionOsFailure? failure})
      parsePlayerResponse(Map<String, dynamic> data) {
    final status = _dig(data, ['playabilityStatus', 'status']);
    if (status == 'LOGIN_REQUIRED') {
      return (url: null, itag: null, failure: VisionOsFailure.botGated);
    }
    final formats = <Map<String, dynamic>>[];
    for (final key in ['adaptiveFormats', 'formats']) {
      final list = _dig(data, ['streamingData', key]);
      if (list is List) {
        for (final entry in list) {
          if (entry is Map<String, dynamic>) formats.add(entry);
          if (entry is Map) formats.add(entry.cast<String, dynamic>());
        }
      }
    }
    final audio = <({int itag, String url})>[];
    for (final format in formats) {
      final mime = format['mimeType'];
      if (mime is! String || !mime.startsWith('audio/')) continue;
      final url = format['url'];
      if (url is! String || url.isEmpty) continue;
      final itag = int.tryParse('${format['itag']}');
      if (itag == null) continue;
      audio.add((itag: itag, url: url));
    }
    if (audio.isEmpty) {
      return (url: null, itag: null, failure: VisionOsFailure.noAudioUrl);
    }
    for (final wanted in preferredItags) {
      for (final candidate in audio) {
        if (candidate.itag == wanted) {
          return (url: candidate.url, itag: wanted, failure: null);
        }
      }
    }
    return (url: audio.first.url, itag: audio.first.itag, failure: null);
  }

  static dynamic _dig(dynamic node, List<Object> path) {
    dynamic current = node;
    for (final step in path) {
      if (step is String) {
        if (current is Map) {
          current = current[step];
        } else {
          return null;
        }
      } else if (step is int) {
        if (current is List && step < current.length) {
          current = current[step];
        } else {
          return null;
        }
      }
    }
    return current;
  }
}
