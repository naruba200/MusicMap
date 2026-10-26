// Tests for the Phase 3 ListenBrainz layer (see
// lib/data/fallback/listenbrainz_client.dart): recommendation parsing
// (both payload shapes, dedupe, caps, empty handling), client failure
// tolerance and request shape, cache-key normalisation, and the
// 0.4-weight fallback scoring merge the provider performs. No live
// API is called: responses are canned via a Dio adapter.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/listenbrainz_client.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';

Map<String, dynamic> _recPayload() => {
      'payload': {
        'user_name': 'testuser',
        'count': 2,
        'recordings': [
          {'artist_name': 'Similar A', 'recording_name': 'Hit One'},
          {'artist_name': 'Similar B', 'recording_name': 'Hit Two'},
          {'artist_name': '', 'recording_name': 'No Artist'},
          {'artist_name': 'Similar A', 'recording_name': 'Hit One'},
        ],
      },
    };

Map<String, dynamic> _listenShapedPayload() => {
      'payload': {
        'recordings': [
          {
            'track_metadata': {
              'artist_name': 'Meta Artist',
              'track_name': 'Meta Song',
            },
          },
        ],
      },
    };

void main() {
  group('parseListenBrainzRecommendations', () {
    test('parses recommendation shape, drops empties, dedupes', () {
      final tracks = parseListenBrainzRecommendations(_recPayload());
      expect(tracks.length, 2);
      expect(tracks[0].artist, 'Similar A');
      expect(tracks[0].title, 'Hit One');
      expect(tracks[1].artist, 'Similar B');
    });

    test('parses listen-shaped track_metadata items', () {
      final tracks =
          parseListenBrainzRecommendations(_listenShapedPayload());
      expect(tracks.length, 1);
      expect(tracks.single.artist, 'Meta Artist');
      expect(tracks.single.title, 'Meta Song');
    });

    test('falls back to top-level recordings, caps at limit', () {
      final tracks = parseListenBrainzRecommendations(
        {
          'recordings': [
            {'artist_name': 'A', 'recording_name': 'One'},
            {'artist_name': 'B', 'recording_name': 'Two'},
            {'artist_name': 'C', 'recording_name': 'Three'},
          ],
        },
        limit: 2,
      );
      expect(tracks.length, 2);
      expect(tracks.last.title, 'Two');
    });

    test('empty and malformed payloads yield []', () {
      expect(parseListenBrainzRecommendations({}), isEmpty);
      expect(parseListenBrainzRecommendations({'payload': {}}), isEmpty);
      expect(
          parseListenBrainzRecommendations(
              {'payload': {'recordings': 'not-a-list'}}),
          isEmpty);
    });
  });

  group('ListenBrainzClient', () {
    test('requests similar recommendations for the username', () async {
      RequestOptions? seen;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        seen = options;
        return _recPayload();
      });
      final client = ListenBrainzClient(dio);
      final tracks = await client.recommendedTracks('TestUser');
      expect(tracks.length, 2);
      expect(seen?.uri.path,
          contains('/cf/recommendation/user/TestUser/recording'));
      expect(seen?.queryParameters['artist_type'], 'similar');
      expect(seen?.headers['User-Agent'], ListenBrainzClient.userAgent);
    });

    test('blank username makes no request and returns []', () async {
      var calls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((_) {
        calls++;
        return _recPayload();
      });
      expect(await ListenBrainzClient(dio).recommendedTracks('   '),
          isEmpty);
      expect(calls, 0);
    });

    test('a dead host returns [] instead of throwing', () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      expect(await ListenBrainzClient(dio).recommendedTracks('user'),
          isEmpty);
    });

    test('count is clamped to the endpoint maximum of 100', () async {
      RequestOptions? seen;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        seen = options;
        return _recPayload();
      });
      await ListenBrainzClient(dio)
          .recommendedTracks('user', count: 500);
      expect(seen?.queryParameters['count'], 100);
    });
  });

  group('ListenBrainzCache keys', () {
    test('keyFor lowercases and trims the username', () {
      expect(ListenBrainzCache.keyFor('  TestUser '), 'lb:recs:testuser');
      expect(ListenBrainzCache.keyFor('testuser'), 'lb:recs:testuser');
    });
  });

  group('ListenBrainz fallback scoring (provider merge shape)', () {
    test('LB tracks score at 0.4 weight with an honest reason', () {
      final seeds = [const Track(artist: 'Seed Artist', title: 'Seed Song')];
      final scored = RecommendationEngine.scoreCandidates(
        seeds: seeds,
        similarBySeed: const {},
        fallbackBySeed: {
          0: [
            const SimilarTrack(artist: 'LB Artist', title: 'LB Song', match: 0),
          ],
        },
        fallbackReasonBySeed: {0: 'From ListenBrainz'},
      );
      expect(scored.length, 1);
      expect(scored.single.score, closeTo(0.4, 0.0001));
      expect(scored.single.reasons, contains('From ListenBrainz'));
    });

    test('LB tracks never recommend a seed track itself', () {
      final seeds = [const Track(artist: 'Seed Artist', title: 'Seed Song')];
      final scored = RecommendationEngine.scoreCandidates(
        seeds: seeds,
        similarBySeed: const {},
        fallbackBySeed: {
          0: [
            const SimilarTrack(
                artist: 'Seed Artist', title: 'Seed Song', match: 0),
          ],
        },
        fallbackReasonBySeed: {0: 'From ListenBrainz'},
      );
      expect(scored, isEmpty);
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
