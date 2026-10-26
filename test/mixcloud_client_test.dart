// Mixcloud client tests (fixture-based, no network): show/tag parsing,
// feed + search + tag-shows endpoints, length formatting, and the
// provider failure-swallow.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/mixcloud_client.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';

class FakeMixcloudAdapter implements HttpClientAdapter {
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
    if (path == '/popular/' || path == '/popular/hot/') {
      payload = {
        'data': _shows,
        'paging': {'next': null},
      };
    } else if (path == '/search/') {
      if (query['type'] == 'tag') {
        payload = {
          'data': [
            {
              'name': 'Funk',
              'key': '/genres/funk/',
              'url': 'https://www.mixcloud.com/genres/funk/',
            },
          ],
        };
      } else {
        payload = {
          'data': _shows.sublist(0, 1),
        };
      }
    } else if (path == '/genres/funk/cloudcasts/') {
      payload = {
        'data': _shows,
      };
    } else {
      payload = {'data': []};
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}

  static const _shows = [
    {
      'key': '/dj1/mix-one/',
      'name': 'Mix One',
      'url': 'https://www.mixcloud.com/dj1/mix-one/',
      'user': {'name': 'DJ One', 'username': 'dj1'},
      'pictures': {'medium': 'm1.jpg'},
      'audio_length': 3720,
      'tags': [
        {'name': 'Funk'},
        {'name': 'Disco'},
      ],
    },
    {
      'key': '/dj2/mix-two/',
      'name': 'Mix Two',
      'url': 'https://www.mixcloud.com/dj2/mix-two/',
      'user': {'username': 'dj2'},
      // No pictures: imageUrl stays null, never a crash.
      'audio_length': 180,
      'tags': [],
    },
  ];
}

class ThrowingMixcloudClient extends MixcloudClient {
  ThrowingMixcloudClient() : super(Dio());

  @override
  Future<List<MixcloudShow>> popular({bool hot = false}) async {
    throw DioException(requestOptions: RequestOptions(path: '/x'));
  }
}

void main() {
  late MixcloudClient client;

  setUp(() {
    final dio = Dio();
    dio.httpClientAdapter = FakeMixcloudAdapter();
    client = MixcloudClient(dio);
  });

  test('popular parses shows, users, pictures, lengths and tags',
      () async {
    final shows = await client.popular();
    expect(shows.length, 2);
    final first = shows.first;
    expect(first.name, 'Mix One');
    expect(first.userName, 'DJ One');
    expect(first.imageUrl, 'm1.jpg');
    expect(first.audioLengthSec, 3720);
    expect(first.tags, ['Funk', 'Disco']);
    // Username fallback when no display name; null image is fine.
    expect(shows[1].userName, 'dj2');
    expect(shows[1].imageUrl, isNull);
  });

  test('searchShows and tagShows hit their endpoints', () async {
    expect((await client.searchShows('funk')).single.name, 'Mix One');
    final tags = await client.searchTags('fun');
    expect(tags.single.name, 'Funk');
    expect(tags.single.key, '/genres/funk/');
    expect((await client.tagShows('/genres/funk/')).length, 2);
  });

  test('formatLength renders mm:ss and h:mm:ss', () {
    expect(MixcloudClient.formatLength(90), '01:30');
    expect(MixcloudClient.formatLength(3720), '1:02:00');
    expect(MixcloudClient.formatLength(0), '00:00');
  });

  test('feed provider swallows failure into an empty error load',
      () async {
    final container = ProviderContainer(overrides: [
      mixcloudClientProvider.overrideWithValue(ThrowingMixcloudClient()),
    ]);
    addTearDown(container.dispose);
    final load =
        await container.read(mixcloudFeedProvider('popular').future);
    expect(load.items, isEmpty);
    expect(load.error, isNotNull);
  });
}
