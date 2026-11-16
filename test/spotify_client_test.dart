// Spotify internal-API client tests (fixture-based, no network):
// TOTP against the RFC 6238 vectors, token minting + caching, client
// token, playlist metadata/tracks parsing, restricted-item counting,
// and the session-expired failure contract.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/platforms/music_platform.dart';
import 'package:music_man/data/spotify/spotify_client.dart';
import 'package:music_man/data/spotify/spotify_session.dart';
import 'package:music_man/data/spotify/spotify_totp.dart';

class MemorySpotifyStore implements SpotifySecureStore {
  final map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    map.remove(key);
  }
}

class FakeSpotifyAdapter implements HttpClientAdapter {
  /// Recorded requests: 'GET host/path'.
  final requests = <String>[];

  /// Status to answer the token endpoint with (200 = success).
  int tokenStatus = 200;

  /// Status to answer api-partner with (200 = success).
  int graphQlStatus = 200;

  /// Headers of the last token-endpoint call (Cookie check).
  Map<String, dynamic>? lastTokenHeaders;

  /// Body of the last client-token call (device_id check).
  Map<String, dynamic>? lastClientTokenBody;

  /// Decoded JSON body of the last api-partner call (operation + hash
  /// checks for the search tests).
  Map<String, dynamic>? lastGraphQlRequest;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final host = options.uri.host;
    final path = options.uri.path;
    requests.add('${options.method} $host$path');
    final Map<String, dynamic> payload;
    var status = 200;
    var contentType = 'application/json';

    if (host == 'gist.githubusercontent.com') {
      // The real gist serves text/plain, so Dio leaves res.data a
      // String — the client must JSON-decode it itself.
      contentType = 'text/plain; charset=utf-8';
      return ResponseBody.fromString(
        jsonEncode([
          {'s': 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 'v': 61},
        ]),
        200,
        headers: {Headers.contentTypeHeader: [contentType]},
      );
    } else if (host == 'open.spotify.com' && path == '/api/server-time') {
      payload = {'serverTime': 1794626761};
    } else if (host == 'open.spotify.com' && path == '/api/token') {
      lastTokenHeaders = Map<String, dynamic>.from(options.headers);
      status = tokenStatus;
      if (status == 200) {
        payload = {
          'accessToken': 'web-token-1',
          'accessTokenExpirationTimestampMs':
              DateTime.now().millisecondsSinceEpoch + 3600000,
          'isAnonymous': false,
          'clientId': 'd8a5ed958d274c2e8ee717e6a4b0971d',
        };
      } else {
        payload = {
          'error': {'status': 401, 'message': 'Unauthorized request'},
        };
      }
    } else if (host == 'clienttoken.spotify.com') {
      lastClientTokenBody = _requestJson(options);
      payload = {
        'granted_token': {
          'token': 'ctoken-1',
          'expires_after_seconds': 1216800,
        },
      };
    } else if (host == 'api-partner.spotify.com') {
      status = graphQlStatus;
      if (status == 200) {
        lastGraphQlRequest = _requestJson(options);
        payload = _graphQlPayload(_requestJson(options));
      } else {
        payload = {
          'error': {'status': 401, 'message': 'Missing/invalid/expired access token'},
        };
      }
    } else {
      payload = {};
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      status,
      headers: {Headers.contentTypeHeader: [contentType]},
    );
  }

  Map<String, dynamic> _requestJson(RequestOptions options) {
    final data = options.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String) return jsonDecode(data) as Map<String, dynamic>;
    return {};
  }

  Map<String, dynamic> _graphQlPayload(Map<String, dynamic> request) {
    final operation = request['operationName'] as String?;
    if (operation == 'searchTracks') {
      // Verified shape (Spotube plugin search_200.json): items nest
      // the track under `item`, NOT the playlist's `itemV2` key.
      return {
        'data': {
          'searchV2': {
            'tracksV2': {
              'items': [
                {
                  'item': {
                    'data': {
                      '__typename': 'Track',
                      'name': 'Song',
                      'artists': {
                        'items': [
                          {'profile': {'name': 'Singer'}},
                        ],
                      },
                      'albumOfTrack': {
                        'name': 'Album',
                        'coverArt': {
                          'sources': [
                            {
                              'url': 'https://cover.test/s.jpg',
                              'width': 300
                            },
                          ],
                        },
                      },
                      'trackDuration': {'totalMilliseconds': 210000},
                      'uri': 'spotify:track:xyz',
                      'id': 'xyz',
                    },
                  },
                },
                {
                  'item': {
                    'data': {'__typename': 'RestrictedContent'},
                  },
                },
              ],
            },
          },
        },
      };
    }
    if (operation == 'fetchPlaylistWithGatedEntityRelations') {
      return {
        'data': {
          'playlistV2': {
            '__typename': 'Playlist',
            'name': 'osu! Bangers',
            'description': 'Best songs <b>bold</b> here',
            'images': {
              'items': [
                {
                  'sources': [
                    {
                      'url': 'https://cover.test/pl.jpg',
                      'width': 640,
                      'height': 640,
                    },
                  ],
                },
              ],
            },
            'ownerV2': {
              'data': {'name': 'CuratorName'},
            },
            'uri': 'spotify:playlist:1RzNon113Yc4MkC6OOXwIB',
            'content': {'totalCount': 320},
          },
        },
      };
    }
    // Contents query, paged by variables.offset.
    final variables = request['variables'] as Map? ?? {};
    final offset = (variables['offset'] as num?)?.toInt() ?? 0;
    final items = offset == 0 ? _pageOne : _pageTwo;
    return {
      'data': {
        'playlistV2': {
          'content': {'items': items, 'totalCount': 5},
        },
      },
    };
  }

  @override
  void close({bool force = false}) {}

  static const _pageOne = [
    {
      'itemV2': {
        'data': {
          '__typename': 'Track',
          'name': 'circles!',
          'artists': {
            'items': [
              {'profile': {'name': 'nekodex'}},
            ],
          },
          'albumOfTrack': {
            'name': 'circles!',
            'coverArt': {
              'sources': [
                {'url': 'https://cover.test/a.jpg', 'width': 300},
              ],
            },
          },
          'trackDuration': {'totalMilliseconds': 200000},
          'uri': 'spotify:track:aaa',
          'id': 'aaa',
        },
      },
    },
    {
      'itemV2': {
        'data': {
          '__typename': 'Track',
          'name': 'Ascension to Heaven',
          'artists': {
            'items': [
              {'profile': {'name': 'XI'}},
            ],
          },
          // No albumOfTrack; duration under `duration` (fallback path).
          'duration': {'totalMilliseconds': 180000},
          'uri': 'spotify:track:bbb',
        },
      },
    },
    {
      'itemV2': {
        'data': {'__typename': 'RestrictedContent'},
      },
    },
  ];

  static const _pageTwo = [
    {
      'itemV2': {
        'data': {
          '__typename': 'Track',
          'name': 'Sound Chimera',
          'artists': {
            'items': [
              {'profile': {'name': 'Laur'}},
              {'profile': {'name': 'Second'}},
            ],
          },
          'albumOfTrack': {'name': 'Alchemy'},
          'trackDuration': {'totalMilliseconds': 240000},
          'uri': 'spotify:track:ccc',
        },
      },
    },
    {
      'itemV2': {
        'data': {'__typename': 'Episode', 'name': 'Some Podcast'},
      },
    },
  ];
}

void main() {
  // RFC 6238 test secret: base32 for ASCII "12345678901234567890".
  const rfcSecret = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';

  group('base32Decode', () {
    test('decodes the RFC secret to the ASCII bytes', () {
      expect(
        utf8.decode(base32Decode(rfcSecret)),
        '12345678901234567890',
      );
    });

    test('tolerates lowercase and padding', () {
      expect(
        utf8.decode(base32Decode('gezdgnbvgy3tqojqgezdgnbvgy3tqojq====')),
        '12345678901234567890',
      );
    });

    test('throws on characters outside the alphabet', () {
      expect(() => base32Decode('GEZDGNBV*Y3TQOJQ'), throwsFormatException);
    });
  });

  group('generateTotp', () {
    test('matches the RFC 6238 SHA1 vectors (8 digits)', () {
      const vectors = {
        59: '94287082',
        1111111109: '07081804',
        1111111111: '14050471',
        1234567890: '89005924',
        2000000000: '69279037',
        20000000000: '65353130',
      };
      for (final entry in vectors.entries) {
        expect(
          generateTotp(rfcSecret, unixSeconds: entry.key, digits: 8),
          entry.value,
        );
      }
    });

    test('is deterministic and 6 digits by default', () {
      final first = generateTotp(rfcSecret, unixSeconds: 1794626761);
      final second = generateTotp(rfcSecret, unixSeconds: 1794626761);
      expect(first, second);
      expect(first, matches(RegExp(r'^\d{6}$')));
    });
  });

  group('SpotifyInternalClient', () {
    late FakeSpotifyAdapter adapter;
    late MemorySpotifyStore store;
    late SpotifyInternalClient client;

    setUp(() {
      final dio = Dio();
      adapter = FakeSpotifyAdapter();
      dio.httpClientAdapter = adapter;
      store = MemorySpotifyStore();
      client = SpotifyInternalClient(dio, SpotifySession(store));
    });

    Future<void> seedSignedIn() async {
      await store.write(SpotifySession.spDcKey, 'cookie-value');
    }

    test('accessToken mints from the cookie and caches in memory', () async {
      await seedSignedIn();
      final first = await client.accessToken();
      final second = await client.accessToken();
      expect(first, 'web-token-1');
      expect(second, 'web-token-1');
      expect(
        adapter.requests
            .where((r) => r.contains('/api/token'))
            .length,
        1,
      );
      // The sp_dc cookie goes out on the token call.
      expect(lastTokenCookie(adapter), contains('sp_dc=cookie-value'));
      // The minted token + expiry are persisted for the next launch.
      expect(await store.read(SpotifySession.accessTokenKey), 'web-token-1');
      expect(
        await store.read(SpotifySession.accessTokenExpiresAtKey),
        isNotNull,
      );
    });

    test('accessToken re-mints when the stored token expired', () async {
      await seedSignedIn();
      await store.write(SpotifySession.accessTokenKey, 'old-token');
      await store.write(
        SpotifySession.accessTokenExpiresAtKey,
        (DateTime.now().millisecondsSinceEpoch - 1000).toString(),
      );
      expect(await client.accessToken(), 'web-token-1');
      expect(
        adapter.requests.where((r) => r.contains('/api/token')).length,
        1,
      );
    });

    test('accessToken throws authExpired and clears the session on 401',
        () async {
      await seedSignedIn();
      adapter.tokenStatus = 401;
      await expectLater(
        client.accessToken(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.authExpired, 'authExpired', isTrue),
        ),
      );
      // The dead cookie is gone, so the next attempt re-logs-in.
      expect(await store.read(SpotifySession.spDcKey), isNull);
    });

    test('accessToken without a cookie throws authExpired', () async {
      await expectLater(
        client.accessToken(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.authExpired, 'authExpired', isTrue),
        ),
      );
    });

    test('clientToken mints with a 32-hex device id and caches', () async {
      final first = await client.clientToken();
      final second = await client.clientToken();
      expect(first, 'ctoken-1');
      expect(second, 'ctoken-1');
      expect(
        adapter.requests
            .where((r) => r.contains('clienttoken.spotify.com'))
            .length,
        1,
      );
      final deviceId = (adapter.lastClientTokenBody?['client_data']
              as Map?)?['js_sdk_data']?['device_id'] as String?;
      expect(deviceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(
        adapter.lastClientTokenBody?['client_data']?['client_id'],
        SpotifyInternalClient.webPlayerClientId,
      );
    });

    test('fetchPlaylistInfo parses name, description, cover, owner, total',
        () async {
      await seedSignedIn();
      final info = await client.fetchPlaylistInfo('1RzNon113Yc4MkC6OOXwIB');
      expect(info.platformId, 'spotify');
      expect(info.id, '1RzNon113Yc4MkC6OOXwIB');
      expect(info.name, 'osu! Bangers');
      expect(info.description, 'Best songs bold here');
      expect(info.coverUrl, 'https://cover.test/pl.jpg');
      expect(info.owner, 'CuratorName');
      expect(info.trackCount, 320);
    });

    test('fetchPlaylistTracks counts restricted items, pages by offset',
        () async {
      await seedSignedIn();
      final page = await client.fetchPlaylistTracks(
        '1RzNon113Yc4MkC6OOXwIB',
        offset: 0,
      );
      expect(page.tracks.length, 2);
      expect(page.restrictedCount, 1);
      expect(page.totalCount, 5);
      expect(page.hasMore, isTrue);
      expect(page.nextOffset, 3);

      final first = page.tracks.first;
      expect(first.title, 'circles!');
      expect(first.artist, 'nekodex');
      expect(first.album, 'circles!');
      expect(first.imageUrl, 'https://cover.test/a.jpg');
      expect(first.durationMs, 200000);
      expect(first.platformTrackId, 'spotify:track:aaa');

      final second = page.tracks[1];
      expect(second.title, 'Ascension to Heaven');
      expect(second.album, isNull);
      expect(second.durationMs, 180000);

      final lastPage = await client.fetchPlaylistTracks(
        '1RzNon113Yc4MkC6OOXwIB',
        offset: 3,
      );
      expect(lastPage.tracks.length, 1);
      expect(lastPage.tracks.first.artist, 'Laur, Second');
      expect(lastPage.restrictedCount, 1); // the Episode item
      expect(lastPage.hasMore, isFalse);
      expect(lastPage.nextOffset, 5);
    });

    test('fetchPlaylist reads every page and sums the restricted count',
        () async {
      await seedSignedIn();
      final data = await client.fetchPlaylist('1RzNon113Yc4MkC6OOXwIB');
      expect(data.tracks.length, 3);
      expect(data.restrictedCount, 2);
      expect(data.readableCount, 3);
      // The contents total wins over the metadata total.
      expect(data.info.trackCount, 5);
      expect(data.tracks.map((t) => t.title).toList(), [
        'circles!',
        'Ascension to Heaven',
        'Sound Chimera',
      ]);
    });

    test('searchTracks parses the searchV2 fixture (item, not itemV2)',
        () async {
      await seedSignedIn();
      final tracks = await client.searchTracks('Singer Song');
      // The RestrictedContent item is skipped, never presented.
      expect(tracks.length, 1);
      final track = tracks.first;
      expect(track.title, 'Song');
      expect(track.artist, 'Singer');
      expect(track.album, 'Album');
      expect(track.imageUrl, 'https://cover.test/s.jpg');
      expect(track.durationMs, 210000);
      expect(track.platformTrackId, 'spotify:track:xyz');
      // The verified contract: searchTracks operation, its own
      // persisted-query hash (NOT the playlist hash), and the
      // searchTerm variable.
      final request = adapter.lastGraphQlRequest!;
      expect(request['operationName'], 'searchTracks');
      expect(
        ((request['extensions'] as Map?)?['persistedQuery'] as Map?)?['sha256Hash'],
        'bc1ca2fcd0ba1013a0fc88e6cc4f190af501851e3dafd3e1ef85840297694428',
      );
      expect(
        (request['variables'] as Map?)?['searchTerm'], 'Singer Song');
      expect((request['variables'] as Map?)?['limit'], 20);
    });

    test('searchTracks 401 clears the session and throws authExpired',
        () async {
      await seedSignedIn();
      adapter.graphQlStatus = 401;
      await expectLater(
        client.searchTracks('Singer Song'),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.authExpired, 'authExpired', isTrue),
        ),
      );
      expect(await store.read(SpotifySession.spDcKey), isNull);
    });

    test('GraphQL 401 clears the session and throws authExpired', () async {
      await seedSignedIn();
      adapter.graphQlStatus = 401;
      await expectLater(
        client.fetchPlaylistInfo('1RzNon113Yc4MkC6OOXwIB'),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.authExpired, 'authExpired', isTrue),
        ),
      );
      expect(await store.read(SpotifySession.spDcKey), isNull);
    });
  });
}

String lastTokenCookie(FakeSpotifyAdapter adapter) {
  final cookie = adapter.lastTokenHeaders?['Cookie'];
  return cookie is String ? cookie : '';
}
