// Openwhyd client tests (fixture-based, no network): export parsing,
// artist/title splitting, source-platform URL resolution, pagination,
// link parsing, and the provider failure-swallow.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/openwhyd_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';

class FakeOpenwhydAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final path = options.uri.path;
    final after = options.uri.queryParameters['after'];
    final dynamic payload;
    if (path.endsWith('/playlist/1')) {
      // Two pages when pageSize is 2: page 1 full, page 2 short.
      if (after == null) {
        payload = [_post1, _post2];
      } else {
        payload = [_post3];
      }
    } else if (path.endsWith('/playlist/2')) {
      // Map-with-tracks shape (defensive branch).
      payload = {
        'tracks': [_post1]
      };
    } else {
      payload = <dynamic>[];
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}

  static const _post1 = {
    '_id': 'aaa',
    'name': 'Mitski - Your Best American Girl',
    'eId': '/yt/If8ChYjdFdE',
    'img': 'https://i.ytimg.com/vi/If8ChYjdFdE/default.jpg',
  };

  static const _post2 = {
    '_id': 'bbb',
    'name': 'Artist With - Dashes - In Title',
    'eId': '/sc/deadoceans/mitski-your-best-american-girl-3'
        '#https://api.soundcloud.com/tracks/249475048',
    'img': 'https://i1.sndcdn.com/art.jpg',
  };

  static const _post3 = {
    '_id': 'ccc',
    'name': 'No Separator At All',
    'eId': '/dz/12345',
  };
}

class ThrowingOpenwhydClient extends OpenwhydClient {
  ThrowingOpenwhydClient() : super(Dio());

  @override
  Future<OpenwhydPlaylistData> playlist(String user, String playlistId,
      {int pageSize = 200}) async {
    throw DioException(requestOptions: RequestOptions(path: '/x'));
  }
}

void main() {
  late OpenwhydClient client;

  setUp(() {
    final dio = Dio();
    dio.httpClientAdapter = FakeOpenwhydAdapter();
    client = OpenwhydClient(dio);
  });

  test('playlist import paginates and splits artist/title', () async {
    final data = await client.playlist('adrien', '1', pageSize: 2);
    expect(data.tracks.length, 3);
    expect(data.tracks[0].artist, 'Mitski');
    expect(data.tracks[0].title, 'Your Best American Girl');
    // Split on the FIRST ' - ' only.
    expect(data.tracks[1].artist, 'Artist With');
    expect(data.tracks[1].title, 'Dashes - In Title');
    // No separator: whole name is the title, artist unknown.
    expect(data.tracks[2].artist, 'Unknown artist');
    expect(data.tracks[2].title, 'No Separator At All');
    // No in-app playback for Openwhyd; eId kept for "open original".
    expect(data.tracks[0].streamUrl, isNull);
    expect(data.tracks[0].platformTrackId, '/yt/If8ChYjdFdE');
    expect(data.info.owner, 'adrien');
  });

  test('map-with-tracks shape parses too', () async {
    final data = await client.playlist('adrien', '2');
    expect(data.tracks.single.title, 'Your Best American Girl');
  });

  test('empty export throws', () async {
    await expectLater(
        client.playlist('adrien', '999'), throwsA(isA<Exception>()));
  });

  test('originalUrl resolves yt/sc/dz/vi and falls back to src.id', () {
    expect(
        OpenwhydClient.originalUrl({'eId': '/yt/If8ChYjdFdE'}),
        'https://youtube.com/watch?v=If8ChYjdFdE');
    expect(
        OpenwhydClient.originalUrl({
          'eId': '/sc/deadoceans/slug#https://api.soundcloud.com/tracks/1'
        }),
        'https://soundcloud.com/deadoceans/slug');
    expect(OpenwhydClient.originalUrl({'eId': '/dz/12345'}),
        'https://www.deezer.com/track/12345');
    expect(OpenwhydClient.originalUrl({'eId': '/vi/987'}),
        'https://vimeo.com/987');
    expect(
        OpenwhydClient.originalUrl({
          'eId': '/xx/unknown',
          'src': {'id': 'https://example.com/track'}
        }),
        'https://example.com/track');
    expect(OpenwhydClient.originalUrl({'eId': '/xx/unknown'}), isNull);
  });

  test('parsePlaylistLink accepts user/playlist links only', () {
    final ref = OpenwhydClient.parsePlaylistLink(
        'https://openwhyd.org/adrien/playlist/61');
    expect(ref, isNotNull);
    expect(ref!.user, 'adrien');
    expect(ref.playlistId, '61');
    expect(OpenwhydClient.parsePlaylistLink('https://openwhyd.org/adrien'),
        isNull);
    expect(
        OpenwhydClient.parsePlaylistLink(
            'https://example.com/adrien/playlist/61'),
        isNull);
  });

  test('playlist provider swallows failure into an error load', () async {
    final container = ProviderContainer(overrides: [
      openwhydClientProvider.overrideWithValue(ThrowingOpenwhydClient()),
    ]);
    addTearDown(container.dispose);
    final load =
        await container.read(openwhydPlaylistProvider('adrien::1').future);
    expect(load.tracks, isEmpty);
    expect(load.error, isNotNull);
    // A malformed key is an error load, never a throw.
    final bad =
        await container.read(openwhydPlaylistProvider('nonsense').future);
    expect(bad.error, isNotNull);
  });
}
