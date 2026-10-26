// Tests for the Last.fm error-6 fallback chain (see
// lib/data/fallback/fallback_sources.dart): title cleaning, structured
// error codes, Deezer/iTunes parsing, per-seed resolution, and
// fallback scoring weight/reasons. No live API is called: Last.fm
// responses are canned via a Dio adapter, other sources via callbacks.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';

Track _t(String artist, String title) => Track(artist: artist, title: title);

SimilarTrack _s(String artist, String title, [double match = 0.5]) =>
    SimilarTrack(artist: artist, title: title, match: match);

void main() {
  group('cleanTrackTitle', () {
    test('leaves a plain base title unchanged', () {
      expect(RecommendationEngine.cleanTrackTitle('Bohemian Rhapsody'),
          'Bohemian Rhapsody');
    });

    test('strips parenthetical and bracket segments', () {
      expect(
          RecommendationEngine.cleanTrackTitle('My Song (TV Size)'),
          'My Song');
      expect(
          RecommendationEngine.cleanTrackTitle('My Song [Official Video]'),
          'My Song');
      expect(
          RecommendationEngine.cleanTrackTitle('My Song (feat. Guest)'),
          'My Song');
    });

    test('strips trailing feat credits and version tags', () {
      expect(RecommendationEngine.cleanTrackTitle('My Song feat. Guest'),
          'My Song');
      expect(RecommendationEngine.cleanTrackTitle('My Song ft. Guest'),
          'My Song');
      expect(RecommendationEngine.cleanTrackTitle('My Song - TV Size'),
          'My Song');
      expect(RecommendationEngine.cleanTrackTitle('My Song - TV-size'),
          'My Song');
      expect(RecommendationEngine.cleanTrackTitle('My Song - Short ver.'),
          'My Song');
    });

    test('combined suffixes collapse to the base title', () {
      expect(
          RecommendationEngine.cleanTrackTitle(
              'My Song feat. Guest (TV Size)'),
          'My Song');
    });
  });

  group('LastFmException error codes', () {
    test('fromApi keeps the message format and parses code 6', () {
      final e =
          LastFmException.fromApi(6, 'Track not found');
      expect(e.toString(), 'Last.fm error 6: Track not found');
      expect(e.code, 6);
      expect(e.isTrackNotFound, isTrue);
    });

    test('other codes and transport errors are not "not found"', () {
      expect(LastFmException.fromApi(10, 'Invalid API key').isTrackNotFound,
          isFalse);
      expect(const LastFmException('boom').code, isNull);
      expect(const LastFmException('boom').isTrackNotFound, isFalse);
      expect(const LastFmException('boom').toString(), 'boom');
    });

    test('a canned error-6 envelope throws with code 6', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter(
          (_) => {'error': 6, 'message': 'Track not found'});
      final client = LastFmClient(dio: dio, apiKey: 'test-key');
      try {
        await client.getSimilarTracks('A', 'Nope');
        fail('expected LastFmException');
      } on LastFmException catch (e) {
        expect(e.code, 6);
        expect(e.isTrackNotFound, isTrue);
      }
    });

    test('getSimilarArtists parses the similarartists envelope', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((method) {
        if (method == 'artist.getSimilar') {
          return {
            'similarartists': {
              'artist': [
                {'name': 'Similar One'},
                {'name': 'Similar Two'},
              ]
            }
          };
        }
        return <String, dynamic>{};
      });
      final client = LastFmClient(dio: dio, apiKey: 'test-key');
      expect(await client.getSimilarArtists('A'),
          ['Similar One', 'Similar Two']);
    });
  });

  group('searchTracks (title-only)', () {
    test('parses the track.search trackmatches envelope', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((method) {
        if (method == 'track.search') {
          return {
            'results': {
              'trackmatches': {
                'track': [
                  {'name': 'Glory Day', 'artist': 'Real Artist'},
                  {'name': '', 'artist': 'Real Artist'},
                ]
              }
            }
          };
        }
        return <String, dynamic>{};
      });
      final client = LastFmClient(dio: dio, apiKey: 'test-key');
      final tracks = await client.searchTracks('Glory Day');
      expect(tracks.length, 1);
      expect(tracks.single.title, 'Glory Day');
      expect(tracks.single.artist, 'Real Artist');
    });
  });

  group('Deezer / iTunes parsing', () {
    test('parseDeezerArtistId takes the first id, null when missing', () {
      expect(
          parseDeezerArtistId({
            'data': [
              {'id': 123, 'name': 'Artist'},
            ]
          }),
          '123');
      expect(parseDeezerArtistId({'data': []}), isNull);
      expect(parseDeezerArtistId({}), isNull);
    });

    test('parseDeezerTracks reads title + artist object, drops empties', () {
      final tracks = parseDeezerTracks({
        'data': [
          {'title': 'Hit', 'artist': {'name': 'Artist'}},
          {'title': '', 'artist': {'name': 'Artist'}},
          {'title': 'No Artist', 'artist': {'name': ''}},
        ]
      });
      expect(tracks.length, 1);
      expect(tracks.single.title, 'Hit');
      expect(tracks.single.artist, 'Artist');
    });

    test('parseDeezerRelatedIds collects ids', () {
      expect(
          parseDeezerRelatedIds({
            'data': [
              {'id': 1},
              {'id': 2},
            ]
          }),
          ['1', '2']);
    });

    test('parseITunesTracks reads trackName + artistName', () {
      final tracks = parseITunesTracks({
        'results': [
          {'trackName': 'Song', 'artistName': 'Singer'},
          {'trackName': '', 'artistName': 'Singer'},
        ]
      });
      expect(tracks.length, 1);
      expect(tracks.single.title, 'Song');
    });

    test('parseITunesPreviewUrl extracts previewUrl', () {
      expect(
          parseITunesPreviewUrl({
            'previewUrl': 'https://example.com/preview.m4a',
          }),
          'https://example.com/preview.m4a');
      expect(parseITunesPreviewUrl({'previewUrl': ''}), isNull);
      expect(parseITunesPreviewUrl({}), isNull);
      expect(parseITunesPreviewUrl('not a map'), isNull);
    });

    test('parseDeezerTracksWithPreviews extracts preview, drops empties',
        () {
      final result = parseDeezerTracksWithPreviews({
        'data': [
          {
            'title': 'Hit',
            'artist': {'name': 'Singer'},
            'preview': 'https://example.com/deezer.m4a',
          },
          {
            'title': 'No Preview',
            'artist': {'name': 'Singer'},
            'preview': '',
          },
          {
            'title': 'Missing Preview',
            'artist': {'name': 'Singer'},
          },
        ]
      });
      expect(result.tracks.length, 3);
      expect(
          result.previews[
              RecommendationEngine.normalizeKey('Singer', 'Hit')],
          'https://example.com/deezer.m4a');
      expect(result.previews.length, 1);
    });

    test('deezerArtistTracksWithPreviews returns tracks + previews',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _UrlCannedAdapter((options) {
        final url = options.uri.toString();
        if (url.contains('/search/artist')) {
          return {
            'data': [
              {'id': 7, 'name': 'Singer'}
            ]
          };
        }
        if (url.contains('/artist/7/top')) {
          return {
            'data': [
              {
                'title': 'Hit',
                'artist': {'name': 'Singer'},
                'preview': 'https://example.com/deezer.m4a',
              }
            ]
          };
        }
        return {'data': []};
      });
      final result =
          await FallbackSources(dio).deezerArtistTracksWithPreviews('Singer');
      expect(result.tracks.single.title, 'Hit');
      expect(
          result.previews[
              RecommendationEngine.normalizeKey('Singer', 'Hit')],
          'https://example.com/deezer.m4a');
    });

    test('deezerArtistTracksWithPreviews returns empty on Deezer failure',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _UrlCannedAdapter((_) {
        throw Exception('connection refused');
      });
      final result =
          await FallbackSources(dio).deezerArtistTracksWithPreviews('Singer');
      expect(result.tracks, isEmpty);
      expect(result.previews, isEmpty);
    });
  });

  group('resolveSeedSimilars', () {
    Future<SeedSimilarResult> resolve({
      Future<List<SimilarTrack>> Function(String, String)? getSimilar,
      Future<List<TagTrack>> Function(String, int)? getArtistTop,
      Future<List<String>> Function(String)? getSimilarArtistsFn,
      Future<List<SimilarTrack>> Function(String)? deezer,
      Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
              Function(String)? itunes,
      Future<({List<SimilarTrack> tracks, Map<String, String> previews})>
              Function(String)? deezerWithPreviews,
      Future<List<SimilarTrack>> Function(String)? searchByTitle,
    }) =>
        resolveSeedSimilars(
          artist: 'Obscure Artist',
          title: 'Obscure Song (TV Size)',
          getSimilar: getSimilar ??
              (_, __) async => throw const LastFmException(
                  'Last.fm error 6: Track not found',
                  code: 6),
          getArtistTopTracks: getArtistTop ?? (_, __) async => const [],
          getSimilarArtists: getSimilarArtistsFn ?? (_) async => const [],
          deezerArtistTracks: deezer ?? (_) async => const [],
          itunesArtistTracksWithPreviews: itunes ??
              (_) async =>
                  (tracks: const <SimilarTrack>[], previews: <String, String>{}),
          deezerArtistTracksWithPreviews: deezerWithPreviews,
          searchTracksByTitle: searchByTitle,
        );

    test('a true similar hit wins and no fallback is called', () async {
      var fallbackCalled = false;
      final result = await resolve(
        getSimilar: (_, __) async => [_s('Sim Artist', 'Sim Song')],
        getArtistTop: (_, __) async {
          fallbackCalled = true;
          return const [];
        },
      );
      expect(result.similars.single.title, 'Sim Song');
      expect(result.fallbackReason, isNull);
      expect(fallbackCalled, isFalse);
    });

    test('error 6 falls back to the artist top tracks', () async {
      final result = await resolve(
        getArtistTop: (_, __) async => [
          const TagTrack(artist: 'Obscure Artist', title: 'Artist Hit', listeners: 9),
        ],
      );
      expect(result.fallbackReason, 'More from Obscure Artist');
      expect(result.fallbacks.single.title, 'Artist Hit');
    });

    test('error 6 falls through to Deezer when Last.fm is empty', () async {
      final result = await resolve(
        deezer: (_) async => [_s('Deezer Artist', 'Deezer Song')],
      );
      expect(result.fallbackReason, 'More from Obscure Artist');
      expect(result.fallbacks.single.title, 'Deezer Song');
    });

    test('a Deezer throw (sinkhole) moves on to iTunes, never aborts',
        () async {
      final result = await resolve(
        deezer: (_) async => throw Exception('connection refused'),
        itunes: (_) async => (tracks: [_s('iTunes Artist', 'iTunes Song')],
            previews: {'itunes artist - itunes song': 'https://x.m4a'}),
      );
      expect(result.fallbackReason, 'More from Obscure Artist');
      expect(result.fallbacks.single.title, 'iTunes Song');
      expect(result.fallbackPreviews['itunes artist - itunes song'],
          'https://x.m4a');
    });

    test('Last.fm similars and Deezer/iTunes run concurrently (both returned)',
        () async {
      final result = await resolve(
        getSimilar: (_, __) async => [_s('Sim Artist', 'Sim Song')],
        deezer: (_) async => [_s('Deezer Artist', 'Deezer Song')],
      );
      expect(result.similars.single.title, 'Sim Song');
      expect(result.fallbacks.single.title, 'Deezer Song');
      expect(result.fallbackReason, 'More from Obscure Artist');
    });

    test('Deezer previews join fallbackPreviews (one Deezer call chain)',
        () async {
      var deezerCalls = 0;
      var plainDeezerCalls = 0;
      final result = await resolve(
        deezer: (_) async {
          plainDeezerCalls++;
          return const [];
        },
        deezerWithPreviews: (_) async {
          deezerCalls++;
          return (
            tracks: [_s('Deezer Artist', 'Deezer Song')],
            previews: {
              RecommendationEngine.normalizeKey(
                  'Deezer Artist', 'Deezer Song'): 'https://d.m4a',
            },
          );
        },
      );
      expect(result.fallbacks.single.title, 'Deezer Song');
      expect(
          result.fallbackPreviews[RecommendationEngine.normalizeKey(
              'Deezer Artist', 'Deezer Song')],
          'https://d.m4a');
      // The with-previews variant replaces the plain chain, not adds
      // a second one.
      expect(deezerCalls, 1);
      expect(plainDeezerCalls, 0);
    });

    test('iTunes preview wins a key conflict with Deezer', () async {
      final key =
          RecommendationEngine.normalizeKey('Same Artist', 'Same Song');
      final result = await resolve(
        deezerWithPreviews: (_) async => (
          tracks: [_s('Same Artist', 'Same Song')],
          previews: {key: 'https://deezer.m4a'},
        ),
        itunes: (_) async => (
          tracks: [_s('Same Artist', 'Same Song')],
          previews: {key: 'https://itunes.m4a'},
        ),
      );
      expect(result.fallbackPreviews[key], 'https://itunes.m4a');
    });

    test('bogus artist + real title still yields candidates via '
        'title-only search', () async {
      final result = await resolve(
        searchByTitle: (_) async => [_s('Real Artist', 'Real Song')],
      );
      expect(result.isEmpty, isFalse);
      expect(result.fallbacks.single.artist, 'Real Artist');
      expect(result.fallbackReason, contains('Found by title'));
    });

    test('title-only search strips a duplicated artist prefix', () async {
      final queries = <String>[];
      final result = await resolveSeedSimilars(
        artist: 'DJMax',
        title: 'DJMax - Glory Day',
        getSimilar: (_, __) async => throw const LastFmException(
            'Last.fm error 6: Track not found',
            code: 6),
        getArtistTopTracks: (_, __) async => const [],
        getSimilarArtists: (_) async => const [],
        deezerArtistTracks: (_) async => const [],
        itunesArtistTracksWithPreviews: (_) async =>
            (tracks: const <SimilarTrack>[], previews: <String, String>{}),
        searchTracksByTitle: (query) async {
          queries.add(query);
          if (query == 'Glory Day') {
            return [_s('Real Artist', 'Glory Day')];
          }
          return const [];
        },
      );
      expect(queries, contains('Glory Day'));
      expect(result.fallbacks.single.title, 'Glory Day');
      expect(result.fallbackReason, 'Found by title: "Glory Day"');
    });

    test('a fully unknown seed fails gracefully, never crashes', () async {
      final result = await resolve(
        searchByTitle: (_) async => const [],
      );
      expect(result.isEmpty, isTrue);
    });

    test('a throwing title search is swallowed like other fallbacks',
        () async {
      final result = await resolve(
        searchByTitle: (_) async => throw Exception('network down'),
      );
      expect(result.isEmpty, isTrue);
    });

    test('a non-6 Last.fm error still aborts', () async {
      await expectLater(
        resolve(
          getSimilar: (_, __) async => throw const LastFmException(
              'Last.fm error 10: Invalid API key',
              code: 10),
        ),
        throwsA(isA<LastFmException>()),
      );
    });

    test('one error-6 seed does not kill a multi-seed loop', () async {
      // Simulates the provider loop: seed 1 exhausts every fallback,
      // seed 2 returns true similars. The loop must not throw.
      Future<SeedSimilarResult> forSeed(String title) {
        if (title == 'Missing Song') {
          return resolve();
        }
        return resolveSeedSimilars(
          artist: 'Known Artist',
          title: title,
          getSimilar: (_, __) async => [_s('Sim Artist', 'Sim Song')],
          getArtistTopTracks: (_, __) async => const [],
          getSimilarArtists: (_) async => const [],
          deezerArtistTracks: (_) async => const [],
          itunesArtistTracksWithPreviews:
              (_) async =>
                  (tracks: const <SimilarTrack>[],
                      previews: <String, String>{}),
        );
      }

      final results = <SeedSimilarResult>[];
      for (final title in ['Missing Song', 'Known Song']) {
        results.add(await forSeed(title));
      }
      expect(results[0].isEmpty, isTrue);
      expect(results[1].similars.single.title, 'Sim Song');
    });
  });

  group('scoreCandidates fallback weighting', () {
    test('fallback tracks score below true hits and carry the reason',
        () {
      final scored = RecommendationEngine.scoreCandidates(
        seeds: [_t('Seed Artist', 'Seed Song')],
        similarBySeed: {
          0: [_s('Core Artist', 'Core Song')],
        },
        fallbackBySeed: {
          0: [_s('Fallback Artist', 'Fallback Song')],
        },
        fallbackReasonBySeed: {0: 'From Deezer'},
      );
      expect(scored.first.track.title, 'Core Song');
      expect(scored.first.score, 1.0);
      expect(scored[1].track.title, 'Fallback Song');
      expect(scored[1].score, closeTo(0.4, 0.001));
      expect(scored[1].reasons, ['From Deezer']);
    });

    test('similar-artist expansion adds new artists, not duplicates',
        () {
      // The provider's 1c step scores similar-artist top tracks as
      // 0.4-weight fallbacks; they must surface new artists while
      // seed tracks themselves stay excluded.
      final scored = RecommendationEngine.scoreCandidates(
        seeds: [_t('Seed Artist', 'Seed Song')],
        similarBySeed: const {},
        fallbackBySeed: {
          0: [
            _s('New Artist', 'New Song'),
            _s('Seed Artist', 'Seed Song'),
          ],
        },
        fallbackReasonBySeed: {0: 'Similar artists to Seed Artist'},
      );
      expect(scored.length, 1);
      expect(scored.single.track.artist, 'New Artist');
      expect(scored.single.score, closeTo(0.4, 0.001));
      expect(scored.single.reasons, ['Similar artists to Seed Artist']);
    });

    test('fallback rank weight decays and seed tracks are excluded', () {
      final scored = RecommendationEngine.scoreCandidates(
        seeds: [_t('Seed Artist', 'Seed Song')],
        similarBySeed: const {},
        fallbackBySeed: {
          0: [
            _s('Fallback Artist', 'First Song'),
            _s('Fallback Artist', 'Second Song'),
            _s('Seed Artist', 'Seed Song'),
          ],
        },
        fallbackReasonBySeed: {0: 'From iTunes'},
      );
      expect(scored.length, 2);
      expect(scored[0].score, closeTo(0.4, 0.001));
      expect(scored[1].score, closeTo(0.2, 0.001));
      expect(scored.every((s) => s.track.title != 'Seed Song'), isTrue);
    });
  });
}

/// Answers with the payload [respond] builds for the requested
/// Last.fm `method` query parameter.
class _CannedAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(String method) respond;
  _CannedAdapter(this.respond);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final method = options.queryParameters['method'] as String? ?? '';
    return ResponseBody.fromString(
      jsonEncode(respond(method)),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers with the payload [respond] builds for the request URL
/// (used for Deezer, which has no Last.fm-style method parameter).
class _UrlCannedAdapter implements HttpClientAdapter {
  final Map<String, dynamic> Function(RequestOptions options) respond;
  _UrlCannedAdapter(this.respond);

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