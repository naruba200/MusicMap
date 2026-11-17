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

  group('TagAlbum.fromJson', () {
    test('parses string artist', () {
      final a = TagAlbum.fromJson({'name': 'Alb', 'artist': 'The Band'});
      expect(a.name, 'Alb');
      expect(a.artist, 'The Band');
    });

    test('parses map artist', () {
      final a = TagAlbum.fromJson({
        'name': 'Alb',
        'artist': {'name': 'The Band'}
      });
      expect(a.artist, 'The Band');
    });
  });

  group('client methods (canned envelopes)', () {
    LastFmClient clientFor(Map<String, dynamic> Function(String) respond,
        {void Function(String)? onMethod}) {
      final dio = Dio();
      dio.httpClientAdapter = _CannedAdapter((method) {
        onMethod?.call(method);
        return respond(method);
      });
      return LastFmClient(dio: dio, apiKey: 'test-key');
    }

    test('getSimilarTracks parses the similartracks envelope', () async {
      String? method;
      final client = clientFor(
        (_) => {
          'similartracks': {
            'track': [
              {
                'name': 'Sim Song',
                'match': '0.77',
                'artist': {'name': 'Sim Artist'}
              }
            ]
          }
        },
        onMethod: (m) => method = m,
      );
      final out = await client.getSimilarTracks('A', 'T');
      expect(method, 'track.getSimilar');
      expect(out.single.title, 'Sim Song');
      expect(out.single.artist, 'Sim Artist');
      expect(out.single.match, closeTo(0.77, 0.001));
    });

    test('getTagTopTracks parses the tracks envelope', () async {
      String? method;
      final client = clientFor(
        (_) => {
          'tracks': {
            'track': [
              {
                'name': 'Tag Hit',
                'listeners': '555',
                'artist': {'name': 'Tag Artist'}
              }
            ]
          }
        },
        onMethod: (m) => method = m,
      );
      final out = await client.getTagTopTracks('rock');
      expect(method, 'tag.getTopTracks');
      expect(out.single.title, 'Tag Hit');
      expect(out.single.listeners, 555);
    });

    test('getTagTopAlbums parses the albums envelope', () async {
      String? method;
      final client = clientFor(
        (_) => {
          'albums': {
            'album': [
              {'name': 'Tag Album', 'artist': 'Tag Artist'}
            ]
          }
        },
        onMethod: (m) => method = m,
      );
      final out = await client.getTagTopAlbums('rock');
      expect(method, 'tag.getTopAlbums');
      expect(out.single.name, 'Tag Album');
      expect(out.single.artist, 'Tag Artist');
    });

    test('getChartTopTracks parses the tracks envelope', () async {
      String? method;
      final client = clientFor(
        (_) => {
          'tracks': {
            'track': [
              {
                'name': 'Chart Hit',
                'listeners': '999',
                'artist': {'name': 'Chart Artist'}
              }
            ]
          }
        },
        onMethod: (m) => method = m,
      );
      final out = await client.getChartTopTracks();
      expect(method, 'chart.getTopTracks');
      expect(out.single.title, 'Chart Hit');
    });

    test('getSimilarTags trims names and drops empties', () async {
      final client = clientFor((_) => {
            'similartags': {
              'tag': [
                {'name': 'rock'},
                {'name': ' metal '},
                {'name': ''},
                {'name': 'indie'},
              ]
            }
          });
      expect(await client.getSimilarTags('rock'), ['rock', 'metal', 'indie']);
    });

    test('getTrackInfo returns album info', () async {
      final client = clientFor((_) => {
            'track': {
              'album': {
                'title': 'Alb',
                'artist': 'Art',
                'image': [
                  {'#text': 'big.jpg', 'size': 'extralarge'}
                ],
              }
            }
          });
      final info = await client.getTrackInfo('Art', 'Song');
      expect(info.album, 'Alb');
      expect(info.imageUrl, 'big.jpg');
    });

    test('getAlbumInfo hits album.getInfo and parses the tracklist',
        () async {
      String? method;
      final client = clientFor(
        (_) => {
          'album': {
            'name': 'Discovery',
            'artist': 'Daft Punk',
            'image': [
              {'#text': 'small.jpg', 'size': 'small'},
              {'#text': 'big.jpg', 'size': 'extralarge'},
            ],
            'tracks': {
              'track': [
                {
                  'name': 'One More Time',
                  'duration': '320',
                  'artist': {'name': 'Daft Punk'},
                },
                {
                  'name': 'Aerodynamic',
                  'duration': '212',
                  'artist': 'Daft Punk',
                },
              ],
            },
          }
        },
        onMethod: (m) => method = m,
      );
      final info = await client.getAlbumInfo('Daft Punk', 'Discovery');
      expect(method, 'album.getInfo');
      expect(info.name, 'Discovery');
      expect(info.artist, 'Daft Punk');
      expect(info.imageUrl, 'big.jpg');
      expect(info.tracks.length, 2);
      expect(info.tracks[0].name, 'One More Time');
      expect(info.tracks[0].durationMs, 320000);
      expect(info.tracks[1].artist, 'Daft Punk');
    });

    test('getAlbumInfo accepts a single track object and empty tracks',
        () async {
      final single = clientFor((_) => {
            'album': {
              'name': 'Solo',
              'artist': 'One',
              'tracks': {
                'track': {'name': 'Only', 'duration': '60'}
              },
            }
          });
      final one = await single.getAlbumInfo('One', 'Solo');
      expect(one.tracks.length, 1);
      expect(one.tracks.single.name, 'Only');
      expect(one.tracks.single.artist, 'One');
      expect(one.tracks.single.durationMs, 60000);

      final empty = clientFor((_) => {
            'album': {'name': 'Blank', 'artist': 'No One'}
          });
      final none = await empty.getAlbumInfo('No One', 'Blank');
      expect(none.tracks, isEmpty);
      expect(none.imageUrl, isNull);
    });

    test('AlbumTrack drops a zero duration and keeps the name', () {
      final t = AlbumTrack.fromJson(
          {'name': 'Intro', 'artist': 'A', 'duration': '0'});
      expect(t.durationMs, isNull);
      expect(t.name, 'Intro');
    });

    test('an error envelope throws LastFmException', () async {
      final client =
          clientFor((_) => {'error': 6, 'message': 'Track not found'});
      await expectLater(client.getSimilarTracks('A', 'Nope'),
          throwsA(isA<LastFmException>()));
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
