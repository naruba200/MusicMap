// Tests for Phase 2 Discogs enrichment (see
// lib/data/enrichment/): release parsing, search-id parsing,
// token rules (no token → no search request at all), failure
// swallow, the MusicBrainz-relation resolution path, and
// AlbumEnrichment merge / JSON round-trip. No live API is called:
// Discogs and MusicBrainz responses are canned via Dio adapters.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/enrichment/album_enrichment.dart';
import 'package:music_man/data/enrichment/discogs_client.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/enrichment/musicbrainz_client.dart';
import 'package:music_man/data/enrichment/rate_limiter.dart';
import 'package:music_man/data/models/music_models.dart';

Map<String, dynamic> _releasePayload() => {
      'id': 999,
      'year': 2020,
      'styles': ['Alternative Rock', 'Indie Rock'],
      'genres': ['Rock'],
      'community': {
        'rating': {'average': 4.2, 'count': 128}
      },
    };

Map<String, dynamic> _relationsPayload() => {
      'relations': [
        {
          'type': 'discogs',
          'url': {
            'resource': 'https://www.discogs.com/release/999-Album'
          }
        },
      ],
    };

RequestThrottler _noWait() =>
    RequestThrottler(minInterval: Duration.zero);

void main() {
  group('parseDiscogsRelease', () {
    test('parses year, styles, genres, community rating', () {
      final rel = parseDiscogsRelease(_releasePayload())!;
      expect(rel.id, 999);
      expect(rel.year, 2020);
      expect(rel.styles, ['Alternative Rock', 'Indie Rock']);
      expect(rel.genres, ['Rock']);
      expect(rel.communityRating, 4.2);
      expect(rel.ratingCount, 128);
      final album = rel.toAlbumEnrichment();
      expect(album.year, 2020);
      expect(album.discogsReleaseId, 999);
      expect(album.sources, ['Discogs']);
    });

    test('returns null without an id, tolerates missing fields', () {
      expect(parseDiscogsRelease({'year': 2020}), isNull);
      final rel = parseDiscogsRelease({'id': 5})!;
      expect(rel.year, isNull);
      expect(rel.styles, isEmpty);
      expect(rel.communityRating, isNull);
    });
  });

  group('parseDiscogsSearchReleaseId', () {
    test('takes the first release-type result only', () {
      expect(
          parseDiscogsSearchReleaseId({
            'results': [
              {'id': 11, 'type': 'artist'},
              {'id': 22, 'type': 'release'},
              {'id': 33, 'type': 'release'},
            ]
          }),
          22);
      expect(parseDiscogsSearchReleaseId({'results': []}), isNull);
      expect(
          parseDiscogsSearchReleaseId({
            'results': [
              {'id': 11, 'type': 'artist'},
            ]
          }),
          isNull);
    });
  });

  group('DiscogsClient token rules and failure tolerance', () {
    test('no token means search returns null without a request',
        () async {
      var calls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((_) {
        calls++;
        return {'results': []};
      });
      final client = DiscogsClient(dio, null, _noWait());
      expect(await client.searchRelease('Artist', 'Album'), isNull);
      expect(calls, 0);
    });

    test('a token sends the Authorization header on search', () async {
      RequestOptions? seen;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        seen = options;
        return {
          'results': [
            {'id': 42, 'type': 'release'},
          ]
        };
      });
      final client = DiscogsClient(dio, 'test-token', _noWait());
      expect(await client.searchRelease('Artist', 'Album'), 42);
      expect(seen?.headers['Authorization'], 'Discogs token=test-token');
      expect(seen?.headers['User-Agent'], DiscogsClient.userAgent);
    });

    test('a throwing transport returns null, never throws', () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      final client = DiscogsClient(dio, null, _noWait());
      expect(await client.fetchRelease(999), isNull);
      expect(await client.searchRelease('A', 'B'), isNull);
    });

    test('a canned release is parsed', () async {
      final dio = Dio();
      dio.httpClientAdapter =
          _CannedAdapter((_) => _releasePayload());
      final client = DiscogsClient(dio, null, _noWait());
      final rel = await client.fetchRelease(999);
      expect(rel?.year, 2020);
      expect(rel?.communityRating, 4.2);
    });
  });

  group('DiscogsEnricher via MusicBrainz relations', () {
    test('resolves a release from a matching song release', () async {
      final mbDio = Dio();
      mbDio.httpClientAdapter =
          _CannedAdapter((_) => _relationsPayload());
      final mb = MusicBrainzClient(mbDio, _noWait());
      final dgDio = Dio();
      dgDio.httpClientAdapter =
          _CannedAdapter((_) => _releasePayload());
      final dg = DiscogsClient(dgDio, null, _noWait());
      final enricher = DiscogsEnricher(dg, mb);
      final albums = [
        AlbumRec(
          name: 'Test Album',
          artist: 'Test Artist',
          songCount: 1,
          bestScore: 1.0,
          songs: const [
            ScoredTrack(
              track: Track(artist: 'Test Artist', title: 'Test Song'),
              score: 1.0,
              reasons: [],
            ),
          ],
        ),
      ];
      final trackKey = RecommendationEngine.normalizeKey(
          'Test Artist', 'Test Song');
      final out = await enricher.enrichAlbums(albums, {
        trackKey: const TrackEnrichment(
          releaseTitle: 'Test Album',
          releaseMbid: 'rel-1',
        ),
      });
      final key = albumEnrichmentKey('Test Artist', 'Test Album');
      expect(out[key]?.year, 2020);
      expect(out[key]?.styles.first, 'Alternative Rock');
      expect(out[key]?.communityRating, 4.2);
    });

    test('no matching song release means no enrichment, no throw',
        () async {
      final mbDio = Dio();
      mbDio.httpClientAdapter =
          _CannedAdapter((_) => _relationsPayload());
      final mb = MusicBrainzClient(mbDio, _noWait());
      final dgDio = Dio();
      var calls = 0;
      dgDio.httpClientAdapter = _CannedAdapter((_) {
        calls++;
        return _releasePayload();
      });
      final dg = DiscogsClient(dgDio, null, _noWait());
      final out =
          await DiscogsEnricher(dg, mb).enrichAlbums([
        const AlbumRec(
          name: 'Other Album',
          artist: 'Test Artist',
          songCount: 0,
          bestScore: 1.0,
          songs: [],
        ),
      ], const {});
      expect(out, isEmpty);
      // No release id could be resolved, so Discogs was never called.
      expect(calls, 0);
    });
  });

  group('AlbumEnrichment', () {
    test('key normalizes artist and album', () {
      expect(albumEnrichmentKey('  Test Artist ', 'Test Album '),
          'test artist|test album');
    });

    test('merge prefers update fields and unions sources', () {
      const base = AlbumEnrichment(
        year: 2020,
        styles: ['Rock'],
        sources: ['Discogs'],
      );
      const update = AlbumEnrichment(
        artUrl: 'https://example.test/art.jpg',
        discography: ['Other Album'],
        sources: ['TheAudioDB'],
      );
      final merged = base.merge(update);
      expect(merged.year, 2020);
      expect(merged.styles, ['Rock']);
      expect(merged.artUrl, 'https://example.test/art.jpg');
      expect(merged.discography, ['Other Album']);
      expect(merged.sources, ['Discogs', 'TheAudioDB']);
      expect(const AlbumEnrichment().isEmpty, isTrue);
    });

    test('JSON round-trip preserves every field', () {
      const e = AlbumEnrichment(
        year: 2020,
        styles: ['Alternative Rock'],
        genres: ['Rock'],
        communityRating: 4.2,
        ratingCount: 128,
        discogsReleaseId: 999,
        artUrl: 'https://example.test/art.jpg',
        artistThumbUrl: 'https://example.test/thumb.jpg',
        discography: ['Other Album'],
        sources: ['Discogs', 'TheAudioDB'],
      );
      final back = AlbumEnrichment.fromJson(e.toJson());
      expect(back.year, 2020);
      expect(back.styles, ['Alternative Rock']);
      expect(back.communityRating, 4.2);
      expect(back.ratingCount, 128);
      expect(back.discogsReleaseId, 999);
      expect(back.artUrl, 'https://example.test/art.jpg');
      expect(back.discography, ['Other Album']);
      expect(back.sources, ['Discogs', 'TheAudioDB']);
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
