// Tests for Phase 2 MusicBrainz enrichment (see
// lib/data/enrichment/): recording parsing, Discogs-ID extraction
// from url-relations, throttler pacing, failure-swallow, enricher
// caps/dedupe, enrichment JSON round-trip, and cache freshness.
// No live API is called: MusicBrainz responses are canned via a Dio
// adapter, and the throttler uses a fake clock + recording delay.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/enrichment/enrichment_cache.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/enrichment/musicbrainz_client.dart';
import 'package:music_man/data/enrichment/rate_limiter.dart';
import 'package:music_man/data/models/music_models.dart';

Map<String, dynamic> _recordingPayload() => {
      'recordings': [
        {
          'id': 'rec-1',
          'title': 'Test Song',
          'artist-credit': [
            {
              'artist': {'id': 'art-1', 'name': 'Test Artist'}
            }
          ],
          'tags': [
            {'name': 'rock', 'count': 10},
            {'name': 'pop', 'count': 3},
            {'name': 'indie', 'count': 7},
            {'name': 'a', 'count': 1},
            {'name': 'b', 'count': 1},
            {'name': 'c', 'count': 1},
          ],
          'releases': [
            {'id': 'rel-0', 'title': '', 'date': ''},
            {
              'id': 'rel-1',
              'title': 'Test Album',
              'date': '2020-05-01'
            },
          ],
          'isrcs': ['USXXX2000001', 'USXXX2000002'],
        }
      ],
    };

void main() {
  group('parseMusicBrainzRecordingSearch', () {
    test('parses ids, vote-sorted capped tags, release, ISRCs', () {
      final rec =
          parseMusicBrainzRecordingSearch(_recordingPayload())!;
      expect(rec.recordingMbid, 'rec-1');
      expect(rec.artistMbid, 'art-1');
      // Most-voted first, capped at 5 (the 6th tag drops out).
      expect(rec.tags, ['rock', 'indie', 'pop', 'a', 'b']);
      // Untitled release entry is skipped.
      expect(rec.releaseTitle, 'Test Album');
      expect(rec.releaseMbid, 'rel-1');
      expect(rec.releaseDate, '2020-05-01');
      expect(rec.isrcs, ['USXXX2000001', 'USXXX2000002']);
    });

    test('returns null for empty recordings or a missing id', () {
      expect(parseMusicBrainzRecordingSearch({'recordings': []}),
          isNull);
      expect(
          parseMusicBrainzRecordingSearch({
            'recordings': [
              {'title': 'No Id'}
            ]
          }),
          isNull);
    });
  });

  group('TrackEnrichment', () {
    test('releaseYear reads the year or null', () {
      expect(
          const TrackEnrichment(releaseDate: '2020-05-01')
              .releaseYear,
          '2020');
      expect(
          const TrackEnrichment(releaseDate: '1999').releaseYear,
          '1999');
      expect(
          const TrackEnrichment(releaseDate: 'soon').releaseYear,
          isNull);
      expect(const TrackEnrichment().releaseYear, isNull);
    });

    test('JSON round-trip preserves every field', () {
      const e = TrackEnrichment(
        recordingMbid: 'rec-1',
        artistMbid: 'art-1',
        tags: ['rock'],
        releaseTitle: 'Test Album',
        releaseMbid: 'rel-1',
        releaseDate: '2020-05-01',
        isrcs: ['USXXX2000001'],
      );
      final back = TrackEnrichment.fromJson(e.toJson());
      expect(back.recordingMbid, 'rec-1');
      expect(back.artistMbid, 'art-1');
      expect(back.tags, ['rock']);
      expect(back.releaseTitle, 'Test Album');
      expect(back.releaseMbid, 'rel-1');
      expect(back.releaseDate, '2020-05-01');
      expect(back.isrcs, ['USXXX2000001']);
      expect(const TrackEnrichment().isEmpty, isTrue);
      expect(e.isEmpty, isFalse);
    });
  });

  group('Discogs release IDs from MusicBrainz relations', () {
    test('extracts the id from a release URL only', () {
      expect(
          extractDiscogsReleaseId(
              'https://www.discogs.com/release/1234567-Title'),
          '1234567');
      expect(
          extractDiscogsReleaseId(
              'https://www.discogs.com/master/1234567-Title'),
          isNull);
      expect(
          extractDiscogsReleaseId(
              'https://www.discogs.com/artist/123-Name'),
          isNull);
    });

    test('parses the discogs relation, ignoring other relations', () {
      expect(
          parseDiscogsReleaseIdFromRelations({
            'relations': [
              {
                'type': 'wikipedia',
                'url': {'resource': 'https://en.wikipedia.org/wiki/X'}
              },
              {
                'type': 'discogs',
                'url': {
                  'resource':
                      'https://www.discogs.com/release/7654321-Album'
                }
              },
            ]
          }),
          '7654321');
      expect(parseDiscogsReleaseIdFromRelations({'relations': []}),
          isNull);
    });
  });

  group('RequestThrottler', () {
    test('first slot is free, later slots wait the full gap', () async {
      final waits = <Duration>[];
      var now = DateTime(2026, 1, 1);
      final throttler = RequestThrottler(
        minInterval: const Duration(milliseconds: 1100),
        delay: (d) async {
          waits.add(d);
        },
        now: () => now,
      );
      await throttler.waitForSlot();
      expect(waits, isEmpty);
      await throttler.waitForSlot();
      expect(waits, [const Duration(milliseconds: 1100)]);
      // Clock advanced 400ms: only the remainder is waited.
      now = now.add(const Duration(milliseconds: 400));
      await throttler.waitForSlot();
      expect(waits.length, 2);
      // Second wait claimed a slot at the (fake) current time, so the
      // third wait measures from there: 1100 - 400 = 700ms.
      expect(waits[1], const Duration(milliseconds: 700));
    });
  });

  group('MusicBrainzClient failure tolerance', () {
    test('a throwing transport returns null, never throws', () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      final client = MusicBrainzClient(
          dio, RequestThrottler(minInterval: Duration.zero));
      expect(await client.lookupRecording('A', 'Song'), isNull);
      expect(await client.lookupReleaseDiscogsId('rel-1'), isNull);
    });

    test('a canned recording is parsed and carries the User-Agent',
        () async {
      RequestOptions? seen;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        seen = options;
        return _recordingPayload();
      });
      final client = MusicBrainzClient(
          dio, RequestThrottler(minInterval: Duration.zero));
      final rec = await client.lookupRecording('Test Artist', 'Test Song');
      expect(rec?.recordingMbid, 'rec-1');
      expect(rec?.tags.first, 'rock');
      expect(seen?.headers['User-Agent'], MusicBrainzClient.userAgent);
      expect(seen?.uri.host, 'musicbrainz.org');
    });
  });

  group('MusicBrainzEnricher', () {
    test('caps at the limit and dedupes identical tracks', () async {
      final dio = Dio();
      var calls = 0;
      dio.httpClientAdapter = _CannedAdapter((_) {
        calls++;
        return _recordingPayload();
      });
      final client = MusicBrainzClient(
          dio, RequestThrottler(minInterval: Duration.zero));
      final enricher = MusicBrainzEnricher(client);
      final tracks = [
        for (var i = 0; i < 12; i++)
          ScoredTrack(
            track: Track(artist: 'Artist $i', title: 'Song $i'),
            score: 1.0,
            reasons: const [],
          ),
        // Duplicate of track 0: must not cost another request.
        const ScoredTrack(
          track: Track(artist: 'Artist 0', title: 'Song 0'),
          score: 1.0,
          reasons: [],
        ),
      ];
      final out = await enricher.enrichTracks(tracks, limit: 10);
      expect(out.length, 10);
      expect(calls, 10);
      final key = RecommendationEngine.normalizeKey('Artist 0', 'Song 0');
      expect(out[key]?.recordingMbid, 'rec-1');
    });

    test('a dead source yields an empty map, never throws', () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      final client = MusicBrainzClient(
          dio, RequestThrottler(minInterval: Duration.zero));
      final out = await MusicBrainzEnricher(client).enrichTracks([
        const ScoredTrack(
          track: Track(artist: 'A', title: 'Song'),
          score: 1.0,
          reasons: [],
        ),
      ]);
      expect(out, isEmpty);
    });
  });

  group('isCacheEntryFresh', () {
    test('30-day TTL: fresh inside, stale outside, bad entries stale',
        () {
      final now = DateTime(2026, 1, 31);
      expect(
          isCacheEntryFresh(
              {'cachedAt': DateTime(2026, 1, 30).toIso8601String()},
              now),
          isTrue);
      expect(
          isCacheEntryFresh(
              {'cachedAt': DateTime(2025, 12, 31).toIso8601String()},
              now),
          isFalse);
      expect(isCacheEntryFresh({'cachedAt': 'not-a-date'}, now),
          isFalse);
      expect(isCacheEntryFresh(null, now), isFalse);
      expect(isCacheEntryFresh({}, now), isFalse);
    });
  });
}

/// Answers every request with the payload [respond] builds.
class _CannedAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options) respond;
  _CannedAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    return ResponseBody.fromString(
      jsonEncode(respond(options)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Simulates a dead host: every request throws.
class _ThrowingAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException(
      requestOptions: options,
      error: 'connection refused',
      type: DioExceptionType.connectionError,
    );
  }

  @override
  void close({bool force = false}) {}
}
