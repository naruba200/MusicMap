// Tests for the full-song resolver (see
// lib/data/fullsong/full_song_resolver.dart): full-song sources in
// priority order (own stream > Audius > Jamendo > YTM finder >
// Spotify metadata re-resolve > Deezer/iTunes links), in-app beats
// outbound, ALWAYS artist+title (title-only only when the artist is
// polluted), every attempted source logged, successes cached,
// failures never cached. No live API is called: every source is
// answered by one canned Dio adapter, distinguished by host/path,
// and Spotify search is a canned callback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/discover/audius_client.dart';
import 'package:music_man/data/discover/jamendo_client.dart';
import 'package:music_man/data/export/visionos_player_client.dart';
import 'package:music_man/data/export/youtube_export.dart';
import 'package:music_man/data/fallback/fallback_sources.dart';
import 'package:music_man/data/fullsong/full_song_resolver.dart';
import 'package:music_man/data/fullsong/resolution_log.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/platforms/music_platform.dart';

/// One canned adapter for every full-song source, routed by host/path.
/// [itunes] maps an iTunes `term` to its `results` list; [deezer] maps
/// a Deezer `q` to its `data` list. Audius / Jamendo / YouTube answers
/// are fixed per adapter instance (tests that need different answers
/// build a different adapter). [requests] counts every fetch, so
/// cache tests can prove a second resolve made no new calls.
class _FullSongAdapter implements HttpClientAdapter {
  final Map<String, List<Map<String, dynamic>>> itunes;
  final Map<String, List<Map<String, dynamic>>> deezer;
  final List<Map<String, dynamic>> audiusTracks;
  final int audiusDelayMs;
  final List<Map<String, dynamic>> jamendoTracks;
  final String? youtubeTitle;
  final String? youtubeVideoId;
  final bool throwDeezer;

  /// Canned youtubei/v1/player envelope for the VISIONOS rung (null
  /// = the endpoint answers `{}`: no audio URLs). [throwPlayer]
  /// makes the player call fail with a connection error instead.
  final Map<String, dynamic>? playerResponse;
  final bool throwPlayer;
  int requests = 0;

  _FullSongAdapter({
    this.itunes = const {},
    this.deezer = const {},
    this.audiusTracks = const [],
    this.audiusDelayMs = 0,
    this.jamendoTracks = const [],
    this.youtubeTitle,
    this.youtubeVideoId,
    this.throwDeezer = false,
    this.playerResponse,
    this.throwPlayer = false,
  });

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests++;
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
    } else if (host == 'www.youtube.com' && path == '/youtubei/v1/player') {
      if (throwPlayer) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          error: 'boom',
        );
      }
      body = playerResponse ?? {};
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
    {bool withJamendo = false,
    bool withYoutube = true,
    bool withVisionOs = true,
    Future<List<Track>> Function(String query)? spotifySearch,
    ResolutionLog? log}) {
  final dio = _dio(adapter);
  return FullSongResolver(
    fallbacks: FallbackSources(dio),
    audius: AudiusClient(dio, hostOverride: 'https://audius.test'),
    jamendo: withJamendo ? JamendoClient(dio, clientId: 'test-id') : null,
    youtube: withYoutube ? YouTubeVideoResolver(dio) : null,
    visionOs: withVisionOs ? VisionOsPlayerClient(dio) : null,
    spotifySearch: spotifySearch,
    log: log,
  );
}

/// Canned VISIONOS player envelope with one audio format per entry.
Map<String, dynamic> _playerEnvelope(
  List<Map<String, dynamic>> audioFormats, {
  String status = 'OK',
}) =>
    {
      'playabilityStatus': {'status': status},
      'streamingData': {'adaptiveFormats': audioFormats},
    };

Map<String, dynamic> _playerAudio(int itag, String url) => {
      'itag': itag,
      'mimeType': 'audio/webm; codecs="opus"',
      'bitrate': 100000,
      'url': url,
    };

const _track = Track(artist: 'Singer', title: 'Song');

void main() {
  group('full song resolver: priority', () {
    test('in-app Audius beats a faster YouTube external match', () async {
      // YouTube answers immediately, Audius 30ms later — priority,
      // not arrival order, must win: the in-app stream plays.
      final resolver = _resolver(_FullSongAdapter(
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'Singer'},
          },
        ],
        audiusDelayMs: 30,
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
      ));
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.audius);
      expect(match.playInApp, isTrue);
      expect(match.streamUrl,
          'https://audius.test/v1/tracks/7/stream?app_name=MusicMan');
      expect(result.failure, isNull);
    });

    test('own streamUrl wins without any network call', () async {
      final adapter = _FullSongAdapter();
      final resolver = _resolver(adapter);
      const track = Track(
        artist: 'Indie Artist',
        title: 'Rare Song',
        streamUrl: 'https://audius.test/v1/tracks/7/stream?app_name=MusicMan',
      );
      final result = await resolver.resolve(track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.ownStream);
      expect(result.match!.playInApp, isTrue);
      expect(adapter.requests, 0);
    });

    test('YouTube finder match is external and logs no direct audio URL',
        () async {
      final log = ResolutionLog();
      final resolver = _resolver(
        _FullSongAdapter(
          youtubeTitle: 'Singer - Song (Official Video)',
          youtubeVideoId: 'abc123',
        ),
        withJamendo: false,
        log: log,
      );
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isFalse);
      expect(match.externalUrl, 'https://www.youtube.com/watch?v=abc123');
      final yt = result.attempts
          .firstWhere((a) => a.source == 'youtube');
      expect(yt.outcome, SourceOutcome.noDirectUrl);
      expect(yt.detail, contains('abc123'));
      expect(log.entries, hasLength(1));
      expect(log.entries.single.result, 'YouTube link');
    });

    test('Deezer link is the last external resort', () async {
      final resolver = _resolver(_FullSongAdapter(
        deezer: {
          'Singer Song': [
            {
              'artist': {'name': 'Singer'},
              'title': 'Song',
              'link': 'https://www.deezer.com/track/1',
            },
          ],
          'Song': const [],
        },
      ));
      final result = await resolver.resolve(_track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.deezer);
      expect(result.match!.playInApp, isFalse);
      expect(result.match!.externalUrl, 'https://www.deezer.com/track/1');
    });
  });

  group('full song resolver: VISIONOS rung', () {
    test('VISIONOS success plays YouTube in-app', () async {
      final log = ResolutionLog();
      final resolver = _resolver(
        _FullSongAdapter(
          youtubeTitle: 'Song',
          youtubeVideoId: 'abc123',
          playerResponse: _playerEnvelope([
            _playerAudio(140, 'https://example.test/140'),
            _playerAudio(251, 'https://example.test/251'),
          ]),
        ),
        log: log,
      );
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isTrue);
      expect(match.streamUrl, 'https://example.test/251');
      expect(match.externalUrl, isNull);
      expect(result.failure, isNull);
      expect(log.entries.single.result, 'YouTube stream');
    });

    test('VISIONOS in-app YouTube beats a Deezer external link', () async {
      final resolver = _resolver(_FullSongAdapter(
        deezer: {
          'Singer Song': [
            {
              'artist': {'name': 'Singer'},
              'title': 'Song',
              'link': 'https://www.deezer.com/track/1',
            },
          ],
          'Song': const [],
        },
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
        playerResponse: _playerEnvelope([
          _playerAudio(251, 'https://example.test/251'),
        ]),
      ));
      final result = await resolver.resolve(_track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.youtube);
      expect(result.match!.playInApp, isTrue);
    });

    test('VISIONOS bot-gated falls back to the external handoff + log',
        () async {
      final resolver = _resolver(_FullSongAdapter(
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
        playerResponse: _playerEnvelope([], status: 'LOGIN_REQUIRED'),
      ));
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isFalse);
      expect(match.externalUrl, 'https://www.youtube.com/watch?v=abc123');
      final yt =
          result.attempts.firstWhere((a) => a.source == 'youtube');
      expect(yt.outcome, SourceOutcome.noDirectUrl);
      expect(yt.detail, contains('bot-gated'));
    });

    test('VISIONOS with no audio URL falls back to the external handoff',
        () async {
      final resolver = _resolver(_FullSongAdapter(
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
        playerResponse: _playerEnvelope([]),
      ));
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isFalse);
      final yt =
          result.attempts.firstWhere((a) => a.source == 'youtube');
      expect(yt.outcome, SourceOutcome.noDirectUrl);
      expect(yt.detail, contains('no direct audio URL'));
      expect(yt.detail, isNot(contains('bot-gated')));
    });

    test('VISIONOS network error still falls back to the external handoff',
        () async {
      final resolver = _resolver(_FullSongAdapter(
        youtubeTitle: 'Song',
        youtubeVideoId: 'abc123',
        throwPlayer: true,
      ));
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.youtube);
      expect(match.playInApp, isFalse);
      expect(match.externalUrl, 'https://www.youtube.com/watch?v=abc123');
      final yt =
          result.attempts.firstWhere((a) => a.source == 'youtube');
      expect(yt.outcome, SourceOutcome.networkError);
    });
  });

  group('full song resolver: strict matching', () {
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
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(result.failure, FullSongFailure.noStream);
    });

    test('wrong-artist same-title is REJECTED on Audius too', () async {
      // The old Audius artist exemption is gone: a title match from
      // a different uploader must not play when the artist is clean.
      final resolver = _resolver(_FullSongAdapter(
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'DJ Someone Else'},
          },
        ],
      ));
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      final audius =
          result.attempts.firstWhere((a) => a.source == 'audius');
      expect(audius.outcome, SourceOutcome.noMatch);
      expect(audius.detail, 'Title matched but artist did not match');
    });

    test('polluted artist falls back to title-only and matches', () async {
      const track = Track(artist: 'Unknown artist', title: 'Song');
      final log = ResolutionLog();
      final resolver = _resolver(
        _FullSongAdapter(
          audiusTracks: [
            {
              'id': '7',
              'title': 'Song',
              'user': {'name': 'some-uploader'},
            },
          ],
        ),
        log: log,
      );
      final result = await resolver.resolve(track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.audius);
      expect(result.match!.playInApp, isTrue);
      // The log records the attempt for the polluted-artist track.
      expect(log.entries.single.trackKey,
          'unknown artist - song');
    });

    test('a failing source does not block the others', () async {
      final resolver = _resolver(_FullSongAdapter(
        throwDeezer: true,
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'Singer'},
          },
        ],
      ));
      final result = await resolver.resolve(_track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.audius);
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
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(
        result.attempts.firstWhere((a) => a.source == 'jamendo').outcome,
        SourceOutcome.skipped,
      );
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
      final result = await resolver.resolve(_track);
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.jamendo);
      expect(result.match!.playInApp, isTrue);
      expect(result.match!.streamUrl, 'https://audio.jamendo.com/song.mp3');
    });

    test('YouTube wrong title is rejected', () async {
      final resolver = _resolver(
        _FullSongAdapter(
          youtubeTitle: 'Other Song (Official Video)',
          youtubeVideoId: 'abc123',
        ),
        withJamendo: false,
      );
      expect((await resolver.resolve(_track)).match, isNull);
    });

    test('youtubeTitleMatches: exact, prefixed, and rejected cases', () {
      expect(FullSongResolver.youtubeTitleMatches('Song', _track), isTrue);
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
  });

  group('full song resolver: Spotify metadata re-resolve', () {
    test('Spotify corrects the artist and the re-resolve finds it',
        () async {
      // Phase 1 Audius rejects the track: the uploader is
      // 'DJ Someone', not 'Singer'. Spotify says the canonical
      // artist IS 'DJ Someone', so the re-resolve with the corrected
      // metadata matches — labelled spotify-corrected.
      final resolver = _resolver(
        _FullSongAdapter(
          audiusTracks: [
            {
              'id': '7',
              'title': 'Song',
              'user': {'name': 'DJ Someone'},
            },
          ],
        ),
        spotifySearch: (_) async => [
          const Track(artist: 'DJ Someone', title: 'Song'),
        ],
      );
      final result = await resolver.resolve(_track);
      final match = result.match;
      expect(match, isNotNull);
      expect(match!.source, FullSongSource.audius);
      expect(match.viaSpotify, isTrue);
      expect(match.sourceLabel, 'spotify-corrected');
      expect(match.playInApp, isTrue);
      expect(
        result.attempts.firstWhere((a) => a.source == 'spotify').outcome,
        SourceOutcome.matched,
      );
      expect(
        result.attempts
            .firstWhere((a) => a.source == 'spotify-audius')
            .outcome,
        SourceOutcome.matched,
      );
    });

    test('Spotify search failure degrades gracefully (network)', () async {
      final resolver = _resolver(
        _FullSongAdapter(
          deezer: {
            'Singer Song': [
              {
                'artist': {'name': 'Singer'},
                'title': 'Song',
                'link': 'https://www.deezer.com/track/1',
              },
            ],
            'Song': const [],
          },
        ),
        spotifySearch: (_) async =>
            throw const SocketException('Failed host lookup'),
      );
      final result = await resolver.resolve(_track);
      // The Spotify failure is logged, not fatal: the Deezer link
      // still wins as the external match.
      expect(result.match, isNotNull);
      expect(result.match!.source, FullSongSource.deezer);
      expect(
        result.attempts.firstWhere((a) => a.source == 'spotify').outcome,
        SourceOutcome.networkError,
      );
    });

    test('Spotify session rejection is logged, not fatal', () async {
      final resolver = _resolver(
        _FullSongAdapter(),
        spotifySearch: (_) async => throw const PlatformException(
            'Spotify session expired — sign in to Spotify again.',
            authExpired: true),
      );
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(
        result.attempts.firstWhere((a) => a.source == 'spotify').outcome,
        SourceOutcome.sessionRejected,
      );
      // A rejected session is not a network failure.
      expect(result.failure, FullSongFailure.noStream);
      expect(result.networkSource, isNull);
    });

    test('Spotify found the track but nothing can play it', () async {
      // Canonical track found, re-resolve finds nothing, no link
      // anywhere: the failure is the Spotify-audio case, not a
      // generic "no stream".
      final resolver = _resolver(
        _FullSongAdapter(),
        spotifySearch: (_) async => [
          const Track(artist: 'Singer', title: 'Song'),
        ],
      );
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(result.spotifyFoundTrack, isTrue);
      expect(result.failure, FullSongFailure.spotifyAudioUnavailable);
    });

    test('Spotify is skipped when not signed in', () async {
      final resolver = _resolver(_FullSongAdapter());
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(
        result.attempts.firstWhere((a) => a.source == 'spotify').outcome,
        SourceOutcome.skipped,
      );
    });
  });

  group('full song resolver: cache + log', () {
    test('a successful in-app resolve is cached; a second resolve '
        'makes no new calls', () async {
      final adapter = _FullSongAdapter(
        audiusTracks: [
          {
            'id': '7',
            'title': 'Song',
            'user': {'name': 'Singer'},
          },
        ],
      );
      final resolver = _resolver(adapter);
      final first = await resolver.resolve(_track);
      expect(first.match, isNotNull);
      final afterFirst = adapter.requests;
      expect(afterFirst, greaterThan(0));
      final second = await resolver.resolve(_track);
      expect(second.match, isNotNull);
      expect(second.match!.streamUrl, first.match!.streamUrl);
      expect(adapter.requests, afterFirst);
    });

    test('failures are never cached: a second resolve re-queries',
        () async {
      final adapter = _FullSongAdapter();
      final resolver = _resolver(adapter);
      expect((await resolver.resolve(_track)).match, isNull);
      final afterFirst = adapter.requests;
      expect(afterFirst, greaterThan(0));
      expect((await resolver.resolve(_track)).match, isNull);
      expect(adapter.requests, greaterThan(afterFirst));
    });

    test('a multi-source failure records every source + reason', () async {
      final log = ResolutionLog();
      final resolver = _resolver(_FullSongAdapter(), log: log);
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(result.failure, FullSongFailure.noStream);
      final sources =
          result.attempts.map((a) => a.source).toList();
      expect(
        sources,
        containsAll(
            ['own stream', 'audius', 'jamendo', 'youtube', 'deezer', 'itunes', 'spotify']),
      );
      expect(log.entries, hasLength(1));
      expect(log.entries.single.result, 'No full stream found');
      expect(log.entries.single.title, 'Song');
      expect(log.entries.single.artist, 'Singer');
    });

    test('a network failure names the unreachable source', () async {
      final resolver = _resolver(
        _FullSongAdapter(),
        spotifySearch: (_) async =>
            throw const SocketException('Failed host lookup'),
      );
      final result = await resolver.resolve(_track);
      expect(result.match, isNull);
      expect(result.failure, FullSongFailure.network);
      expect(result.networkSource, 'spotify');
    });
  });

  group('full song service routing', () {
    test('service routes in-app, outbound, noMatch, and openFailed',
        () async {
      // In-app route (Audius).
      final inApp = <String>[];
      final service = FullSongService(_resolver(_FullSongAdapter(
        audiusTracks: [
          {'id': '7', 'title': 'Song', 'user': {'name': 'Singer'}},
        ],
      )));
      var action = await service.act(
        _track,
        onInApp: (t, url, source) async {
          inApp.add('$source:$url');
        },
        onExternal: (_) async => true,
        onNoMatch: (_) async {},
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
        onNoMatch: (_) async {},
      );
      expect(action, FullSongAction.openExternal);
      expect(opened, [Uri.parse('https://www.youtube.com/watch?v=abc123')]);

      // Outbound launch failure is reported, not swallowed.
      var noMatchCalled = false;
      action = await ytService.act(
        _track,
        onInApp: (_, __, ___) async {},
        onExternal: (_) async => false,
        onNoMatch: (_) async {
          noMatchCalled = true;
        },
      );
      expect(action, FullSongAction.openFailed);
      expect(noMatchCalled, isFalse);

      // No strict match anywhere -> noMatch, with the result.
      FullSongResolveResult? seen;
      final emptyService =
          FullSongService(_resolver(_FullSongAdapter(), withYoutube: true));
      action = await emptyService.act(
        _track,
        onInApp: (_, __, ___) async {},
        onExternal: (_) async => true,
        onNoMatch: (result) async {
          seen = result;
        },
      );
      expect(action, FullSongAction.noMatch);
      expect(seen, isNotNull);
      expect(seen!.match, isNull);
      expect(seen!.failure, FullSongFailure.noStream);
    });
  });
}
