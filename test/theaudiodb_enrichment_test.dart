// Tests for Phase 2 TheAudioDB enrichment (see
// lib/data/enrichment/theaudiodb_client.dart): artwork parsing,
// discography parsing, failure-swallow, the documented public test
// key, and the enricher's merge-into-Discogs / caps / dedupe
// behaviour. No live API is called: responses are canned via a Dio
// adapter, and the throttler is a zero-wait one.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/enrichment/album_enrichment.dart';
import 'package:music_man/data/enrichment/enrichment_models.dart';
import 'package:music_man/data/enrichment/rate_limiter.dart';
import 'package:music_man/data/enrichment/theaudiodb_client.dart';
import 'package:music_man/data/models/music_models.dart';

RequestThrottler _noWait() =>
    RequestThrottler(minInterval: Duration.zero);

Map<String, dynamic> _artPayload() => {
      'album': [
        {'strAlbumThumb': 'https://example.test/art.jpg'},
      ],
    };

Map<String, dynamic> _thumbPayload() => {
      'artists': [
        {'strArtistThumb': 'https://example.test/thumb.jpg'},
      ],
    };

Map<String, dynamic> _discographyPayload() => {
      'album': [
        {'strAlbum': 'Test Album'},
        {'strAlbum': 'Other Album'},
        {'strAlbum': 'Third Album'},
      ],
    };

/// Answers every request from the canned payload matching its path.
Map<String, dynamic> _route(RequestOptions options) {
  final path = options.path;
  if (path.contains('searchalbum.php')) return _artPayload();
  if (path.contains('discography')) return _discographyPayload();
  if (path.contains('artist-mb.php') || path.contains('search.php')) {
    return _thumbPayload();
  }
  return {};
}

AlbumRec _album(String name, String artist, {String? artUrl}) =>
    AlbumRec(
      name: name,
      artist: artist,
      artUrl: artUrl,
      songCount: 1,
      bestScore: 1.0,
      songs: const [
        ScoredTrack(
          track: Track(artist: 'Test Artist', title: 'Test Song'),
          score: 1.0,
          reasons: [],
        ),
      ],
    );

void main() {
  group('parseArtistThumb', () {
    test('takes the first non-empty thumbnail', () {
      expect(
        parseArtistThumb({
          'artists': [
            {'strArtistThumb': ''},
            {'strArtistThumb': 'https://example.test/thumb.jpg'},
          ],
        }),
        'https://example.test/thumb.jpg',
      );
    });

    test('returns null when no thumbnail exists', () {
      expect(parseArtistThumb({'artists': []}), isNull);
      expect(parseArtistThumb({}), isNull);
      expect(
        parseArtistThumb({
          'artists': [
            {'strArtistThumb': '  '},
          ],
        }),
        isNull,
      );
    });
  });

  group('parseAlbumArtwork', () {
    test('takes the first non-empty artwork URL', () {
      expect(parseAlbumArtwork(_artPayload()),
          'https://example.test/art.jpg');
    });

    test('returns null when no artwork exists', () {
      expect(parseAlbumArtwork({'album': []}), isNull);
      expect(parseAlbumArtwork({}), isNull);
    });
  });

  group('parseDiscography', () {
    test('returns album names in source order, skipping blanks', () {
      expect(
        parseDiscography({
          'album': [
            {'strAlbum': 'First'},
            {'strAlbum': '  '},
            {'strAlbum': 'Second'},
          ],
        }),
        ['First', 'Second'],
      );
      expect(parseDiscography({}), isEmpty);
    });
  });

  group('TheAudioDBClient', () {
    test('uses the documented public test key by default', () async {
      expect(TheAudioDBClient.testApiKey, '123');
      String? seenPath;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        seenPath = options.path;
        return _route(options);
      });
      final client = TheAudioDBClient(dio, null, _noWait());
      await client.albumArtwork('Test Artist', 'Test Album');
      expect(seenPath, contains('/json/123/'));
    });

    test('a throwing transport returns null / [], never throws',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      final client = TheAudioDBClient(dio, null, _noWait());
      expect(await client.albumArtwork('A', 'B'), isNull);
      expect(await client.artistThumbByName('A'), isNull);
      expect(await client.artistThumbByMbid('mbid-1'), isNull);
      expect(await client.discographyByName('A'), isEmpty);
      expect(await client.discographyByMbid('mbid-1'), isEmpty);
    });

    test('canned responses are parsed', () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter(_route);
      final client = TheAudioDBClient(dio, null, _noWait());
      expect(await client.albumArtwork('Test Artist', 'Test Album'),
          'https://example.test/art.jpg');
      expect(await client.artistThumbByMbid('mbid-1'),
          'https://example.test/thumb.jpg');
      expect(await client.discographyByMbid('mbid-1'),
          ['Test Album', 'Other Album', 'Third Album']);
    });
  });

  group('TheAudioDBEnricher', () {
    test('merges into a Discogs entry without overwriting it',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter(_route);
      final client = TheAudioDBClient(dio, null, _noWait());
      final key = albumEnrichmentKey('Test Artist', 'Test Album');
      final out = await TheAudioDBEnricher(client).enrichAlbums(
        [_album('Test Album', 'Test Artist')],
        {
          key: const AlbumEnrichment(
            year: 2020,
            styles: ['Rock'],
            communityRating: 4.2,
            ratingCount: 10,
            sources: ['Discogs'],
          ),
        },
        <String, TrackEnrichment>{},
      );
      final merged = out[key];
      // Discogs-owned fields survive the merge.
      expect(merged?.year, 2020);
      expect(merged?.styles, ['Rock']);
      expect(merged?.communityRating, 4.2);
      expect(merged?.ratingCount, 10);
      // TheAudioDB adds only its own fields.
      expect(merged?.artUrl, 'https://example.test/art.jpg');
      expect(merged?.artistThumbUrl, 'https://example.test/thumb.jpg');
      // The album itself is excluded from its own discography.
      expect(merged?.discography, ['Other Album', 'Third Album']);
      expect(merged?.sources, containsAll(['Discogs', 'TheAudioDB']));
    });

    test('caps at the limit and dedupes identical albums', () async {
      var artCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        if (options.path.contains('searchalbum.php')) artCalls++;
        return _route(options);
      });
      final client = TheAudioDBClient(dio, null, _noWait());
      final enricher = TheAudioDBEnricher(client);
      final capped = await enricher.enrichAlbums(
        [
          _album('Test Album', 'Test Artist'),
          _album('Second Album', 'Other Artist'),
        ],
        <String, AlbumEnrichment>{},
        <String, TrackEnrichment>{},
        limit: 1,
      );
      expect(capped, hasLength(1));
      expect(
          capped.containsKey(
              albumEnrichmentKey('Test Artist', 'Test Album')),
          isTrue);
      artCalls = 0;
      final deduped = await enricher.enrichAlbums(
        [
          _album('Test Album', 'Test Artist'),
          _album('Test Album', 'Test Artist'),
        ],
        <String, AlbumEnrichment>{},
        <String, TrackEnrichment>{},
      );
      expect(deduped, hasLength(1));
      expect(artCalls, 1);
    });

    test('a dead source preserves the existing map, never throws',
        () async {
      final dio = Dio();
      dio.httpClientAdapter = _ThrowingAdapter();
      final client = TheAudioDBClient(dio, null, _noWait());
      final key = albumEnrichmentKey('Test Artist', 'Test Album');
      final existing = {
        key: const AlbumEnrichment(
          year: 2020,
          styles: ['Rock'],
          sources: ['Discogs'],
        ),
      };
      final out = await TheAudioDBEnricher(client).enrichAlbums(
        [_album('Test Album', 'Test Artist')],
        existing,
        <String, TrackEnrichment>{},
      );
      expect(out[key]?.year, 2020);
      expect(out[key]?.sources, ['Discogs']);
      expect(out[key]?.artUrl, isNull);
      expect(out[key]?.discography, isEmpty);
    });

    test('skips the artist thumbnail when Last.fm art already exists',
        () async {
      var thumbCalls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((options) {
        if (options.path.contains('search.php')) thumbCalls++;
        return _route(options);
      });
      final client = TheAudioDBClient(dio, null, _noWait());
      final key = albumEnrichmentKey('Test Artist', 'Test Album');
      final out = await TheAudioDBEnricher(client).enrichAlbums(
        [
          _album('Test Album', 'Test Artist',
              artUrl: 'https://example.test/lastfm.jpg'),
        ],
        <String, AlbumEnrichment>{},
        <String, TrackEnrichment>{},
      );
      expect(thumbCalls, 0);
      expect(out[key]?.artistThumbUrl, isNull);
      expect(out[key]?.artUrl, 'https://example.test/art.jpg');
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
