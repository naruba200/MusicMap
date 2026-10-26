// Tests for the hybrid "Play full song" race (see
// lib/data/fullsong/full_song_resolver.dart): concurrent platform
// lookups, first STRICT match wins, wrong titles rejected, a failing
// source never blocks the others, Jamendo skipped without a client_id,
// in-app vs outbound routing, and preview fallback when nothing
// matches strictly. No live API is called: every source is answered by
// one canned Dio adapter, distinguished by host/path.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/audius_client.dart';
import 'package:music_man/data/discover/jamendo_client.dart';
import 'package:music_man/data/export/youtube_export.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/fullsong/full_song_resolver.dart';
import 'package:music_man/data/models/music_models.dart';

/// One canned adapter for every full-song source, routed by host/path.
/// [itunes] maps an iTunes `term` to its `results` list; [deezer] maps
/// a Deezer `q` to its `data` list. Audius / Jamendo / YouTube answers
/// are fixed per adapter instance (tests that need different answers
/// build a different adapter).
class _FullSongAdapter implements HttpClientAdapter {
  final Map<String, List<Map<String, dynamic>>> itunes;
  final Map<String, List<Map<String, dynamic>>> deezer;
  final List<Map<String, dynamic>> audiusTracks;
  final int audiusDelayMs;
  final List<Map<String, dynamic>> jamendoTracks;
  final String? youtubeTitle;
  final String? youtubeVideoId;
  final bool throwDeezer;

  _FullSongAdapter({
    this.itunes = const {},
    this.deezer = const {},
    this.audiusTracks = const [],
    this.audiusDelayMs = 0,
    this.jamendoTracks = const [],
    this.youtubeTitle,
    this.youtubeVideoId,
    this.throwDeezer = false,
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final host = options.uri.host;
    final path = options.uri.path;
    Map<String, dynamic> body;
    if (host == 'itunes.apple.com') {
      final term = options.queryParameters['term'] as String? ?? '';
      body = {'results': itunes[term] ?? const []};
    } else if (host == 'api.deezer.com') {
      if (throwDeezer) {
        throw DioException(requestOptions: options, error: 'boom');
      }
      final q = options.queryParameters['q'] as String? ?? '';
      body = {'data': deezer[q] ?? const []};
    } else if (host == 'audius.test' && path.endsWith('/v1/tracks/search')) {
      if (audiusDelayMs > 0) {
        await Future.delayed(Duration(milliseconds: audiusDelayMs));
      }
      body = {'data': audiusTracks};
    } else if (host == 'api.jamendo.com' && path == '/v3.0/tracks/') {
      body = {'results': jamendoTracks};
    } else if (host == 'music.youtube.com') {
      if (youtubeTitle != null && youtubeVideoId != null) {
        body = {
          'contents': {
            'tabbedSearchResultsRenderer': {
              'tabs': [
                {
                  'tabRenderer': {
                    'content': {
                      'sectionListRenderer': {
                        'contents': [
                          {
                            'musicCardShelfRenderer': {
                              'title': {
                                'runs': [
                                  {
                                    'text': youtubeTitle,
                                    'navigationEndpoint': {
                                      'watchEndpoint': {
                                        'videoId': youtubeVideoId,
                                      },
                                    },
                                  },
                                ],
                              },
                            },
                          },
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        };
      } else {
        body = {'contents': {}};
      }
    } else {
      body = {};
    }
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Dio _dio(_FullSongAdapter adapter) {
  final dio = Dio();
  dio.httpClientAdapter = adapter;
  return dio;
}

FullSongResolver _resolver(_FullSongAdapter adapter,
    {bool withJamendo = false, bool withYoutube = true}) {
  final dio = _dio(adapter);
  return FullSongResolver(
    fallbacks: FallbackSources(dio),
    audius: AudiusClient(dio, hostOverride: 'https://audius.test'),
    jamendo: withJamendo ? JamendoClient(dio, clientId: 'test-id') : null,
    youtube: withYoutube ? YouTubeVideoResolver(dio) : null,
  );
}

const _track = Track(artist: 'Singer', title: 'Song');

void main() {
  group('full song race', () {
    test('first strict match wins over a fast wrong result', () async {
      // Deezer answers immediately but with the WRONG title, so its
      // link lookup yields null; Audius answers 30ms later with an
      // exact title match. The race must return Audius, not the fast
      // wrong result (and not wait for a wrong result to "win").
      final resolver = _resolver(_FullSongAdapter(
        deezer: {
          'Singer Song': [
            {
              'artist': {'name': 'Singer'},
              'title': 'Other Song',
              'link': 'https://www.deezer.com/track/1',
            },
          ],
          'Song': const [],
        },
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'some-uploader'},
          },
        ],
        audiusDelayMs: 30,
      ));
      final match = await resolver.resolve(_track);
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.audius);
      expect(match.playInApp, isTrue);
      expect(match.streamUrl,
          'https://audius.test/v1/tracks/7/stream?app_name=MusicMan');
    });

    test('wrong-title results are rejected everywhere', () async {
      final resolver = _resolver(_FullSongAdapter(
        itunes: {
          'Singer Song': [
            {
              'artistName': 'Singer',
              'trackName': 'Other Song',
              'trackViewUrl': 'https://music.apple.com/song/1',
            },
          ],
          'Song': const [],
        },
        deezer: {
          'Singer Song': [
            {
              'artist': {'name': 'Singer'},
              'title': 'Different Song',
              'link': 'https://www.deezer.com/track/2',
            },
          ],
          'Song': const [],
        },
        audiusTracks: [
          {
            'id': '9',
            'title': 'Not Song',
            'user': {'name': 'some-uploader'},
          },
        ],
        youtubeTitle: 'Totally Different',
        youtubeVideoId: 'zzzz',
      ));
      expect(await resolver.resolve(_track), isNull);
    });

    test('a failing source does not block the others', () async {
      final resolver = _resolver(_FullSongAdapter(
        throwDeezer: true,
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'some-uploader'},
          },
        ],
      ));
      final match = await resolver.resolve(_track);
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.audius);
    });

    test('Jamendo is skipped when no client_id is set', () async {
      // Only Jamendo would match this track, but the resolver was
      // built without a Jamendo client (the no-client_id case), so
      // the Jamendo answer must never be reached.
      final resolver = _resolver(
        _FullSongAdapter(
          jamendoTracks: [
            {
              'id': 42,
              'name': 'Song',
              'artist_name': 'Singer',
              'audio': 'https://audio.jamendo.com/song.mp3',
            },
          ],
        ),
        withJamendo: false,
      );
      expect(await resolver.resolve(_track), isNull);
    });

    test('Jamendo match plays in-app when a client_id is set', () async {
      final resolver = _resolver(
        _FullSongAdapter(
          jamendoTracks: [
            {
              'id': 42,
              'name': 'Song',
              'artist_name': 'Singer',
              'audio': 'https://audio.jamendo.com/song.mp3',
            },
          ],
        ),
        withJamendo: true,
      );
      final match = await resolver.resolve(_track);
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.jamendo);
      expect(match.playInApp, isTrue);
      expect(match.streamUrl, 'https://audio.jamendo.com/song.mp3');
    });

    test('YouTube title matching strips artist prefix and suffix',
        () async {
      final resolver = _resolver(
        _FullSongAdapter(
          youtubeTitle: 'Singer - Song (Official Video)',
          youtubeVideoId: 'abc123',
        ),
        withJamendo: false,
      );
      final match = await resolver.resolve(_track);
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isFalse);
      expect(match.externalUrl, 'https://www.youtube.com/watch?v=abc123');
    });

    test('YouTube wrong title is rejected', () async {
      final resolver = _resolver(
        _FullSongAdapter(
          youtubeTitle: 'Other Song (Official Video)',
          youtubeVideoId: 'abc123',
        ),
        withJamendo: false,
      );
      expect(await resolver.resolve(_track), isNull);
    });

    test('youtubeTitleMatches: exact, prefixed, and rejected cases', () {
      expect(
          FullSongResolver.youtubeTitleMatches('Song', _track), isTrue);
      expect(
          FullSongResolver.youtubeTitleMatches(
              'Singer - Song (Official Video)', _track),
          isTrue);
      expect(
          FullSongResolver.youtubeTitleMatches('Other Song', _track),
          isFalse);
      // A channel-prefixed title for a polluted artist is rejected:
      // the channel name is not the artist and cannot verify the match.
      expect(
          FullSongResolver.youtubeTitleMatches('Some Channel - Song',
              const Track(artist: 'Unknown artist', title: 'Song')),
          isFalse);
      expect(
          FullSongResolver.youtubeTitleMatches('Song (Official Video)',
              const Track(artist: 'Unknown artist', title: 'Song')),
          isTrue);
    });

    test('service routes in-app, outbound, fallback, and openFailed',
        () async {
      // In-app route (Audius).
      final inApp = <String>[];
      final service = FullSongService(_resolver(_FullSongAdapter(
        audiusTracks: [
          {'id': '7', 'title': 'Song', 'user': {'name': 'uploader'}},
        ],
      )));
      var action = await service.act(
        _track,
        onInApp: (t, url, source) async {
          inApp.add('$source:$url');
        },
        onExternal: (_) async => true,
        onPreviewFallback: (_) async {},
      );
      expect(action, FullSongAction.playInApp);
      expect(inApp, [
        'audius:https://audius.test/v1/tracks/7/stream?app_name=MusicMan',
      ]);

      // Outbound route (YouTube) with a successful launch.
      final opened = <Uri>[];
      final ytService = FullSongService(_resolver(_FullSongAdapter(
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
      )));
      action = await ytService.act(
        _track,
        onInApp: (_, __, ___) async {},
        onExternal: (uri) async {
          opened.add(uri);
          return true;
        },
        onPreviewFallback: (_) async {},
      );
      expect(action, FullSongAction.openExternal);
      expect(opened, [Uri.parse('https://www.youtube.com/watch?v=abc123')]);

      // Outbound launch failure is reported, not swallowed.
      var fallbackCalled = false;
      action = await ytService.act(
        _track,
        onInApp: (_, __, ___) async {},
        onExternal: (_) async => false,
        onPreviewFallback: (_) async {
          fallbackCalled = true;
        },
      );
      expect(action, FullSongAction.openFailed);
      expect(fallbackCalled, isFalse);

      // No strict match anywhere -> preview fallback.
      var previewCalled = false;
      final emptyService =
          FullSongService(_resolver(_FullSongAdapter(), withYoutube: true));
      action = await emptyService.act(
        _track,
        onInApp: (_, __, ___) async {},
        onExternal: (_) async => true,
        onPreviewFallback: (_) async {
          previewCalled = true;
        },
      );
      expect(action, FullSongAction.previewFallback);
      expect(previewCalled, isTrue);
    });
  });
}
