// Jamendo client tests (fixture-based, no network): track/playlist
// parsing, playlist import, radios + best-effort stream, link parsing,
// and the provider placeholder + failure behaviour.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/jamendo_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';

class FakeJamendoAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final path = options.uri.path;
    final query = options.uri.queryParameters;
    final Map<String, dynamic> payload;
    // NOTE: '/playlists/tracks/' must be checked BEFORE '/tracks/',
    // because it also ends with '/tracks/'. The old order shadowed
    // the playlist branch, so playlist('42') received the bare track
    // list, the client's playlist-wrapper extraction found no
    // 'tracks' key, and the import came back with 0 tracks.
    if (path.endsWith('/playlists/tracks/')) {
      payload = {
        'headers': {'status': 'success'},
        'results': [
          {'id': 42, 'name': 'My Mix', 'tracks': _tracks},
        ],
      };
    } else if (path.endsWith('/tracks/')) {
      payload = {
        'headers': {'status': 'success'},
        'results': _tracks,
      };
    } else if (path.endsWith('/playlists/')) {
      if (query['id'] == '42') {
        payload = {
          'headers': {'status': 'success'},
          'results': [
            {
              'id': 42,
              'name': 'My Mix',
              'user_name': 'Curator',
            },
          ],
        };
      } else if (query['id'] == '404') {
        payload = {
          'headers': {'status': 'success'},
          'results': [],
        };
      } else {
        payload = {
          'headers': {'status': 'success'},
          'results': [
            {
              'id': 7,
              'name': 'Found Mix',
              'user_name': 'Someone',
            },
          ],
        };
      }
    } else if (path.endsWith('/radios/')) {
      payload = {
        'headers': {'status': 'success'},
        'results': [
          {'id': 5, 'name': 'Chill Radio', 'image': 'radio.jpg'},
          {'id': 6, 'dispname': 'Rock FM'},
        ],
      };
    } else if (path.endsWith('/radios/stream/')) {
      if (query['id'] == '5') {
        payload = {
          'headers': {'status': 'success'},
          'results': [
            {'id': 5, 'stream': 'https://stream.test/chill.mp3'},
          ],
        };
      } else {
        // No stream field: best-effort lookup must return null, not throw.
        payload = {
          'headers': {'status': 'success'},
          'results': [
            {'id': 6},
          ],
        };
      }
    } else {
      payload = {'headers': {'status': 'success'}, 'results': []};
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}

  static const _tracks = [
    {
      'id': 11,
      'name': 'First Song',
      'artist_name': 'Artist One',
      'album_name': 'Album One',
      'album_image': 'a1.jpg',
      'audio': 'https://audio.test/11.mp3',
      'duration': 200,
    },
    {
      'id': 12,
      'name': 'Second Song',
      'artist_name': 'Artist Two',
      'album_name': 'Album Two',
      'album_image': 'a2.jpg',
      'audio': 'https://audio.test/12.mp3',
      'duration': 95,
    },
  ];
}

class ThrowingJamendoClient extends JamendoClient {
  ThrowingJamendoClient() : super(Dio(), clientId: 'test-id');

  @override
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    throw DioException(requestOptions: RequestOptions(path: '/x'));
  }
}

void main() {
  late JamendoClient client;

  setUp(() {
    final dio = Dio();
    dio.httpClientAdapter = FakeJamendoAdapter();
    client = JamendoClient(dio, clientId: 'test-id');
  });

  test('searchTracks parses streams, durations and artwork', () async {
    final tracks = await client.searchTracks('summer');
    expect(tracks.length, 2);
    final first = tracks.first;
    expect(first.title, 'First Song');
    expect(first.artist, 'Artist One');
    expect(first.album, 'Album One');
    expect(first.imageUrl, 'a1.jpg');
    expect(first.durationMs, 200000);
    expect(first.streamUrl, 'https://audio.test/11.mp3');
    expect(first.previewUrl, isNull);
    expect(first.platformTrackId, '11');
  });

  test('playlist import returns metadata plus tracks', () async {
    final data = await client.playlist('42');
    expect(data.info.name, 'My Mix');
    expect(data.info.owner, 'Curator');
    expect(data.info.id, '42');
    expect(data.tracks.length, 2);
    expect(data.tracks.first.title, 'First Song');
  });

  test('playlist import throws on an unknown id', () async {
    await expectLater(client.playlist('404'), throwsA(isA<Exception>()));
  });

  test('searchPlaylists maps playlist entries', () async {
    final playlists = await client.searchPlaylists('mix');
    expect(playlists.single.name, 'Found Mix');
    expect(playlists.single.id, '7');
  });

  test('radios parse names, images and the dispname fallback', () async {
    final radios = await client.radios();
    expect(radios.length, 2);
    expect(radios.first.name, 'Chill Radio');
    expect(radios.first.imageUrl, 'radio.jpg');
    expect(radios[1].name, 'Rock FM');
  });

  test('radioStreamUrl returns a stream or null, never throws', () async {
    expect(await client.radioStreamUrl('5'),
        'https://stream.test/chill.mp3');
    expect(await client.radioStreamUrl('6'), isNull);
  });

  test('parsePlaylistLink accepts links and bare ids', () {
    expect(
        JamendoClient.parsePlaylistLink(
            'https://www.jamendo.com/playlist/4242/summer-mix'),
        '4242');
    expect(JamendoClient.parsePlaylistLink('4242'), '4242');
    expect(
        JamendoClient.parsePlaylistLink('https://www.jamendo.com/track/1'),
        isNull);
    expect(
        JamendoClient.parsePlaylistLink('https://example.com/playlist/1'),
        isNull);
  });

  test('placeholder client_id yields a setup error load, not a call',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final load = await container.read(jamendoSearchProvider('x').future);
    expect(load.items, isEmpty);
    expect(load.error, contains('client_id'));
  });

  test('search provider swallows failure into an empty error load',
      () async {
    final container = ProviderContainer(overrides: [
      jamendoClientIdProvider.overrideWithValue('test-id'),
      jamendoClientProvider.overrideWithValue(ThrowingJamendoClient()),
    ]);
    addTearDown(container.dispose);
    final load = await container.read(jamendoSearchProvider('x').future);
    expect(load.items, isEmpty);
    expect(load.error, isNotNull);
  });
}

