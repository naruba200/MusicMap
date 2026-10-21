// Deezer adapter tests (fixture-based, no network): playlist info and
// track parsing, index pagination, and the error envelope.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/platforms/deezer_platform.dart';
import 'package:music_man/data/platforms/music_platform.dart';

class FakeDeezerAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final path = options.uri.path;
    final Map<String, dynamic> payload;
    if (path.endsWith('/tracks')) {
      final index = options.queryParameters['index'] as int? ?? 0;
      payload = index == 0 ? _page1 : _page2;
    } else if (path.endsWith('/err')) {
      payload = {
        'error': {'message': 'Playlist not found'}
      };
    } else {
      payload = _info;
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}

  static const _info = {
    'id': 123,
    'title': 'My Mix',
    'description': 'desc',
    'picture_big': 'cover.jpg',
    'creator': {'name': 'Owner'},
    'nb_tracks': 3,
  };

  static const _page1 = {
    'data': [
      {
        'id': 1,
        'title': 'First',
        'duration': 180,
        'artist': {'name': 'Artist One'},
        'album': {'title': 'Album One', 'cover_big': 'a1.jpg'},
      },
      {
        'id': 2,
        'title': 'Second',
        'duration': 95,
        'artist': {'name': 'Artist Two'},
        'album': {'title': 'Album Two', 'cover_big': 'a2.jpg'},
      },
    ],
    'total': 3,
    'next': 'https://api.deezer.com/playlist/123/tracks?index=2',
  };

  static const _page2 = {
    'data': [
      {
        'id': 3,
        'title': 'Third',
        'duration': 200,
        'artist': {'name': 'Artist Three'},
        'album': {'title': 'Album Three', 'cover_big': 'a3.jpg'},
      },
    ],
    'total': 3,
  };
}

void main() {
  late DeezerPlatform platform;

  setUp(() {
    final dio = Dio();
    dio.httpClientAdapter = FakeDeezerAdapter();
    platform = DeezerPlatform(dio);
  });

  test('fetchPlaylistInfo maps the Deezer fields', () async {
    final info = await platform.fetchPlaylistInfo('123');
    expect(info.platformId, 'deezer');
    expect(info.id, '123');
    expect(info.name, 'My Mix');
    expect(info.coverUrl, 'cover.jpg');
    expect(info.owner, 'Owner');
    expect(info.trackCount, 3);
  });

  test('fetchPlaylistInfo throws on the Deezer error envelope', () async {
    await expectLater(
        platform.fetchPlaylistInfo('err'), throwsA(isA<PlatformException>()));
  });

  test('tracks parse fully and paginate by index', () async {
    final page1 = await platform.fetchPlaylistTracks('123');
    expect(page1.tracks.length, 2);
    final t = page1.tracks.first;
    expect(t.title, 'First');
    expect(t.artist, 'Artist One');
    expect(t.album, 'Album One');
    expect(t.imageUrl, 'a1.jpg');
    expect(t.durationMs, 180000); // seconds -> ms
    expect(t.platformTrackId, '1');
    expect(page1.hasMore, isTrue);
    expect(page1.cursor, 2);

    final page2 = await platform.fetchPlaylistTracks('123', cursor: page1.cursor);
    expect(page2.tracks.single.title, 'Third');
    expect(page2.hasMore, isFalse);
  });
}
