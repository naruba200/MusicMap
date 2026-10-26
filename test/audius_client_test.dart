// Audius client tests (fixture-based, no network): trending/search
// parsing, playlist import order + caps, link parsing, and the provider
// failure-swallow (a dead Audius yields an empty load with an error label,
// never a throw).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/audius_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/discover_provider.dart';

class FakeAudiusAdapter implements HttpClientAdapter {
  final List<List<String>> batchRequests = [];

  /// When true, the /v1/tracks batch lookup fabricates a track for any
  /// unknown id (simulating a huge catalogue for the 100-track cap
  /// test). When false — the default — it returns only tracks that
  /// actually exist, so a dead playlist id is dropped, not fabricated.
  /// The old unconditional fabrication is what made the dead-id test
  /// fail: id 3 was invented as 'T3' instead of being dropped.
  bool _fabricateUnknownIds = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final path = options.uri.path;
    final Map<String, dynamic> payload;
    if (path.endsWith('/tracks/trending')) {
      payload = {'data': _trending};
    } else if (path.endsWith('/tracks/search')) {
      payload = {'data': _trending.sublist(0, 1)};
    } else if (path.endsWith('/playlists/search')) {
      payload = {
        'data': [
          {
            'id': 77,
            'playlist_name': 'Found Mix',
            'description': 'desc',
            'user': {'name': 'Curator', 'handle': 'curator'},
            'artwork': {'480x480': 'pl.jpg'},
            'playlist_contents': [
              {'track_id': 1},
              {'track_id': 2},
            ],
          },
        ],
      };
    } else if (path.endsWith('/playlists/9')) {
      _fabricateUnknownIds = false;
      payload = {
        'data': {
          'id': 9,
          'playlist_name': 'My Playlist',
          'description': 'desc',
          'user': {'name': 'Owner', 'handle': 'owner'},
          'artwork': {'480x480': 'cover.jpg'},
          // Deliberately reversed vs the batch order below, plus a
          // dead id (3) the batch lookup never returns.
          'playlist_contents': [
            {'track_id': 2},
            {'track_id': 3},
            {'track_id': 1},
          ],
        },
      };
    } else if (path.endsWith('/playlists/100')) {
      _fabricateUnknownIds = true;
      payload = {
        'data': {
          'id': 100,
          'playlist_name': 'Huge Playlist',
          'user': {'name': 'Owner', 'handle': 'owner'},
          'artwork': {'480x480': 'cover.jpg'},
          'playlist_contents': [
            for (var i = 1; i <= 105; i++) {'track_id': i},
          ],
        },
      };
    } else if (path.endsWith('/v1/tracks')) {
      final ids = options.uri.queryParametersAll['id'] ?? [];
      batchRequests.add(ids);
      final data = <dynamic>[];
      for (final id in ids) {
        final match =
            _trending.where((t) => '${t['id']}' == id).toList();
        if (match.isNotEmpty) {
          data.add(match.first);
        } else if (_fabricateUnknownIds) {
          // Caps-test simulation only: invent a catalogue entry.
          data.add({
            'id': int.parse(id),
            'title': 'T$id',
            'duration': 60,
            'user': {'name': 'A'},
            'artwork': {},
          });
        }
        // Otherwise the id is dead: the lookup never returns it, so
        // the client must drop it (never fabricate it).
      }
      payload = {'data': data};
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

  static const _trending = [
    {
      'id': 1,
      'title': 'First Track',
      'duration': 180,
      'user': {'name': 'Artist One', 'handle': 'artistone'},
      'artwork': {'150x150': 'a1.jpg'},
    },
    {
      'id': 2,
      'title': 'Second Track',
      'duration': 95,
      // No display name: handle is the artist fallback.
      'user': {'handle': 'artisttwo'},
      'artwork': {'480x480': 'a2.jpg'},
    },
  ];
}

class ThrowingAudiusClient extends AudiusClient {
  ThrowingAudiusClient() : super(Dio(), hostOverride: 'https://x.test');

  @override
  Future<List<Track>> trending(
      {String genre = 'all', int limit = 20}) async {
    throw DioException(requestOptions: RequestOptions(path: '/x'));
  }
}

void main() {
  late AudiusClient client;
  late FakeAudiusAdapter adapter;

  setUp(() {
    final dio = Dio();
    adapter = FakeAudiusAdapter();
    dio.httpClientAdapter = adapter;
    client = AudiusClient(dio, hostOverride: 'https://discovery.test');
  });

  test('trending parses artist, artwork, duration and stream URL', () async {
    final tracks = await client.trending();
    expect(tracks.length, 2);
    final first = tracks.first;
    expect(first.title, 'First Track');
    expect(first.artist, 'Artist One');
    expect(first.imageUrl, 'a1.jpg');
    expect(first.durationMs, 180000);
    expect(first.platformTrackId, '1');
    expect(first.streamUrl,
        'https://discovery.test/v1/tracks/1/stream?app_name=MusicMan');
    // No previewUrl: full streams live on streamUrl, not the preview field.
    expect(first.previewUrl, isNull);
    // Missing display name falls back to the handle.
    expect(tracks[1].artist, 'artisttwo');
  });

  test('playlist import keeps playlist order and drops dead ids', () async {
    final data = await client.playlist('9');
    expect(data.info.name, 'My Playlist');
    expect(data.info.owner, 'Owner');
    expect(data.info.coverUrl, 'cover.jpg');
    expect(data.info.trackCount, 3);
    // Playlist order (2, then 1); dead id 3 dropped, not fabricated.
    expect(data.tracks.map((t) => t.platformTrackId).toList(), ['2', '1']);
  });

  test('playlist import caps at 100 tracks in 50-id batches', () async {
    final data = await client.playlist('100');
    expect(data.tracks.length, 100);
    expect(adapter.batchRequests.length, 2);
    expect(adapter.batchRequests.expand((b) => b).length, 100);
  });

  test('searchPlaylists maps playlist entries', () async {
    final playlists = await client.searchPlaylists('mix');
    expect(playlists.single.name, 'Found Mix');
    expect(playlists.single.id, '77');
    expect(playlists.single.trackCount, 2);
  });

  test('parsePlaylistLink accepts links, albums and bare ids', () {
    expect(
        AudiusClient.parsePlaylistLink(
            'https://audius.co/curator/playlist/summer-mix-123456'),
        '123456');
    expect(
        AudiusClient.parsePlaylistLink(
            'https://audius.co/artist/album/debut-album-987'),
        '987');
    expect(AudiusClient.parsePlaylistLink('424242'), '424242');
    expect(AudiusClient.parsePlaylistLink('https://audius.co/curator'),
        isNull);
    expect(
        AudiusClient.parsePlaylistLink(
            'https://audius.co/curator/playlist/no-numeric-suffix'),
        isNull);
    expect(
        AudiusClient.parsePlaylistLink(
            'https://example.com/playlist/name-123'),
        isNull);
  });

  test('trending provider swallows failure into an empty error load',
      () async {
    final container = ProviderContainer(overrides: [
      audiusClientProvider.overrideWithValue(ThrowingAudiusClient()),
    ]);
    addTearDown(container.dispose);
    final load = await container.read(audiusTrendingProvider('all').future);
    expect(load.items, isEmpty);
    expect(load.error, isNotNull);
  });
}

