// MusicBrainz enrichment (Phase 2, step 1). Runs AFTER scoring, on
// top-N results only — never a candidate pool, never scored. Every
// failure returns null / skips the track, never aborts a run.
// Rate limit 1 req/s via [RequestThrottler], sequential calls only.
// No auth, but a meaningful User-Agent is mandatory. Plain Dio,
// no retry interceptor, short timeouts.

import 'package:dio/dio.dart';

import '../engine/recommendation_engine.dart';
import 'enrichment_cache.dart';
import 'enrichment_models.dart';
import 'rate_limiter.dart';

Map<String, dynamic> _asMap(dynamic value) =>
    value is Map ? value.cast<String, dynamic>() : const {};

List<Map<String, dynamic>> _asMapList(dynamic value) {
  if (value is List) {
    return value
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
  }
  return const [];
}

/// Parsed MusicBrainz recording: IDs, tags, first release, ISRCs.
/// Separate from [TrackEnrichment] so parsing is testable alone.
class MusicBrainzRecording {
  final String recordingMbid;
  final String? artistMbid;
  final List<String> tags;
  final String? releaseTitle;
  final String? releaseMbid;
  final String? releaseDate;
  final List<String> isrcs;

  const MusicBrainzRecording({
    required this.recordingMbid,
    this.artistMbid,
    this.tags = const [],
    this.releaseTitle,
    this.releaseMbid,
    this.releaseDate,
    this.isrcs = const [],
  });

  TrackEnrichment toEnrichment() => TrackEnrichment(
        recordingMbid: recordingMbid,
        artistMbid: artistMbid,
        tags: tags,
        releaseTitle: releaseTitle,
        releaseMbid: releaseMbid,
        releaseDate: releaseDate,
        isrcs: isrcs,
      );
}

/// First recording from a search response, or null. Tags are
/// most-voted first, capped at 5; first titled release wins.
MusicBrainzRecording? parseMusicBrainzRecordingSearch(
    Map<String, dynamic> json) {
  final recordings = _asMapList(json['recordings']);
  if (recordings.isEmpty) return null;
  final rec = recordings.first;
  final id = (rec['id'] as String?)?.trim();
  if (id == null || id.isEmpty) return null;

  String? artistMbid;
  for (final credit in _asMapList(rec['artist-credit'])) {
    final artist = _asMap(credit['artist']);
    final aid = (artist['id'] as String?)?.trim();
    if (aid != null && aid.isNotEmpty) {
      artistMbid = aid;
      break;
    }
  }

  final tagVotes = <({String name, int count})>[];
  for (final tag in _asMapList(rec['tags'])) {
    final name = (tag['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) continue;
    tagVotes.add(
        (name: name, count: (tag['count'] as num?)?.toInt() ?? 0));
  }
  tagVotes.sort((a, b) => b.count.compareTo(a.count));
  final tags = tagVotes.take(5).map((t) => t.name).toList();

  String? releaseTitle;
  String? releaseMbid;
  String? releaseDate;
  for (final rel in _asMapList(rec['releases'])) {
    final title = (rel['title'] as String?)?.trim() ?? '';
    if (title.isEmpty) continue;
    releaseTitle = title;
    releaseMbid = (rel['id'] as String?)?.trim();
    final date = (rel['date'] as String?)?.trim();
    releaseDate = (date != null && date.isNotEmpty) ? date : null;
    break;
  }

  final isrcs = <String>[];
  for (final isrc in (rec['isrcs'] as List? ?? [])) {
    final s = isrc.toString().trim();
    if (s.isNotEmpty) isrcs.add(s);
  }

  return MusicBrainzRecording(
    recordingMbid: id,
    artistMbid: artistMbid,
    tags: tags,
    releaseTitle: releaseTitle,
    releaseMbid: releaseMbid,
    releaseDate: releaseDate,
    isrcs: isrcs,
  );
}

/// Discogs release ID from a url-relation resource, or null for
/// non-release URLs. E.g. ".../release/1234567-Title" → "1234567".
String? extractDiscogsReleaseId(String resource) {
  final match = RegExp(r'discogs\.com/release/(\d+)').firstMatch(resource);
  return match?.group(1);
}

/// Discogs release ID from a release lookup (inc=url-rels), or
/// null. Lets the Discogs step resolve a release without search.
String? parseDiscogsReleaseIdFromRelations(Map<String, dynamic> json) {
  for (final rel in _asMapList(json['relations'])) {
    if (rel['type'] != 'discogs') continue;
    final resource = (_asMap(rel['url'])['resource'] as String?) ?? '';
    final id = extractDiscogsReleaseId(resource);
    if (id != null) return id;
  }
  return null;
}

/// Best-effort client: null on any failure, never throws.
class MusicBrainzClient {
  /// Mandatory meaningful User-Agent (app/version + project URL).
  static const userAgent =
      'MusicMan/1.0.0 (https://github.com/naruba200/MusicMap)';

  static const _base = 'https://musicbrainz.org/ws/2';

  final Dio _dio;
  final RequestThrottler _throttler;

  /// Plain Dio by default (no shared retry interceptor).
  MusicBrainzClient([Dio? dio, RequestThrottler? throttler])
      : _dio = dio ?? Dio(),
        _throttler = throttler ??
            RequestThrottler(
                minInterval: const Duration(milliseconds: 1100));

  Options get _options => Options(
        headers: {'User-Agent': userAgent},
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 10),
      );

  String _lucene(String value) => value.replaceAll('"', '').trim();

  /// Recording search by artist + title; first match wins.
  Future<MusicBrainzRecording?> lookupRecording(
      String artist, String title) async {
    try {
      await _throttler.waitForSlot();
      final res = await _dio.get(
        '$_base/recording/',
        queryParameters: {
          'query':
              'recording:"${_lucene(title)}" AND artist:"${_lucene(artist)}"',
          'fmt': 'json',
          'limit': 1,
        },
        options: _options,
      );
      return parseMusicBrainzRecordingSearch(_asMap(res.data));
    } catch (_) {
      return null;
    }
  }

  /// Discogs release ID for a release, via url-relations.
  Future<String?> lookupReleaseDiscogsId(String releaseMbid) async {
    try {
      await _throttler.waitForSlot();
      final res = await _dio.get(
        '$_base/release/$releaseMbid',
        queryParameters: {'inc': 'url-rels', 'fmt': 'json'},
        options: _options,
      );
      return parseDiscogsReleaseIdFromRelations(_asMap(res.data));
    } catch (_) {
      return null;
    }
  }
}

/// Post-score enrichment: sequential, cached, capped at [limit],
/// deduped by key. Failures and cached misses skipped silently.
class MusicBrainzEnricher {
  final MusicBrainzClient _client;
  final EnrichmentCache? _cache;

  MusicBrainzEnricher(this._client, [this._cache]);

  Future<Map<String, TrackEnrichment>> enrichTracks(
    List<ScoredTrack> tracks, {
    int limit = 10,
  }) async {
    final out = <String, TrackEnrichment>{};
    final seen = <String>{};
    for (final st in tracks) {
      if (out.length >= limit) break;
      final key = RecommendationEngine.normalizeKey(
          st.track.artist, st.track.title);
      if (!seen.add(key)) continue;
      final cache = _cache;
      if (cache != null) {
        final cached = cache.lookupTrack(key);
        if (cached != null) {
          out[key] = cached;
          continue;
        }
        if (!cache.shouldRetryTrack(key, DateTime.now())) continue;
      }
      final rec = await _client.lookupRecording(
        RecommendationEngine.primaryArtist(st.track.artist),
        st.track.title,
      );
      if (rec == null) {
        cache?.storeTrackMiss(key);
        continue;
      }
      final enrichment = rec.toEnrichment();
      out[key] = enrichment;
      cache?.storeTrack(key, enrichment);
    }
    return out;
  }
}
