import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';

void main() {
  group('SimilarTrack.fromJson', () {
    test('parses artist object, title and match', () {
      final t = SimilarTrack.fromJson({
        'name': 'Get Lucky',
        'match': '0.85',
        'artist': {'name': 'Daft Punk'},
      });
      expect(t.title, 'Get Lucky');
      expect(t.artist, 'Daft Punk');
      expect(t.match, closeTo(0.85, 0.001));
    });

    test('handles string artist and missing match', () {
      final t = SimilarTrack.fromJson({'name': 'X', 'artist': 'Y'});
      expect(t.artist, 'Y');
      expect(t.match, 0);
    });
  });

  group('TagTrack.fromJson', () {
    test('parses listeners as int', () {
      final t = TagTrack.fromJson({
        'name': 'Blinding Lights',
        'listeners': '1234567',
        'artist': {'name': 'The Weeknd'},
      });
      expect(t.listeners, 1234567);
    });
  });

  group('TrackAlbumInfo.fromJson', () {
    test('picks the largest image', () {
      final info = TrackAlbumInfo.fromJson({
        'track': {
          'album': {
            'title': 'Discovery',
            'artist': 'Daft Punk',
            'image': [
              {'#text': 'small.jpg', 'size': 'small'},
              {'#text': '', 'size': 'medium'},
              {'#text': 'big.jpg', 'size': 'extralarge'},
            ],
          },
        },
      });
      expect(info.album, 'Discovery');
      expect(info.imageUrl, 'big.jpg');
    });

    test('missing album yields nulls', () {
      final info = TrackAlbumInfo.fromJson({'track': {}});
      expect(info.album, isNull);
      expect(info.imageUrl, isNull);
    });
  });

  group('LastFmException', () {
    test('toString returns the message', () {
      expect(const LastFmException('boom').toString(), 'boom');
    });
  });

  group('artist endpoints (daily picks)', () {
    // Serves canned Last.fm envelopes and records the method requested.
    late String requestedMethod;
    late LastFmClient client;

    setUp(() {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((method) {
        requestedMethod = method;
        return switch (method) {
          'artist.getTopTracks' => {
              'toptracks': {
                'track': [
                  {
                    'name': 'Idol',
                    'listeners': '424242',
                    'artist': {'name': 'YOASOBI'},
                  }
                ]
              }
            },
          'artist.getTopAlbums' => {
              'topalbums': {
                'album': [
                  {'name': 'THE BOOK', 'artist': 'YOASOBI'}
                ]
              }
            },
          _ => <String, dynamic>{},
        };
      });
      client = LastFmClient(dio: dio, apiKey: 'test-key');
    });

    test('getArtistTopTracks hits artist.getTopTracks + parses toptracks',
        () async {
      final tracks = await client.getArtistTopTracks('YOASOBI');
      expect(requestedMethod, 'artist.getTopTracks');
      expect(tracks.single.title, 'Idol');
      expect(tracks.single.artist, 'YOASOBI');
      expect(tracks.single.listeners, 424242);
    });

    test('getArtistTopAlbums hits artist.getTopAlbums + parses topalbums',
        () async {
      final albums = await client.getArtistTopAlbums('YOASOBI');
      expect(requestedMethod, 'artist.getTopAlbums');
      expect(albums.single.name, 'THE BOOK');
      expect(albums.single.artist, 'YOASOBI');
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
