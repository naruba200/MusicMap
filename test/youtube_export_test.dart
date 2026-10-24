// YouTube export tests (M6, FR-28..FR-31, fixture-based, no network):
// chunking, URL format, card + shelf search parsing, cache hits,
// 7-day miss retry, unmatched handling, and cancellation.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/export/youtube_export.dart';
import 'package:music_man/data/models/music_models.dart';

Track _track(String artist, String title) =>
    Track(artist: artist, title: title);

Map<String, dynamic> _cardEnvelope(String videoId) => {
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
                                'text': 'Some Song',
                                'navigationEndpoint': {
                                  'watchEndpoint': {'videoId': videoId}
                                }
                              }
                            ]
                          }
                        }
                      }
                    ]
                  }
                }
              }
            }
          ]
        }
      }
    };

Map<String, dynamic> _shelfEnvelope(String videoId) => {
      'contents': {
        'tabbedSearchResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {
                    'contents': [
                      {
                        'musicShelfRenderer': {
                          'contents': [
                            {
                              'musicResponsiveListItemRenderer': {
                                'playlistItemData': {'videoId': videoId}
                              }
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
              }
            }
          ]
        }
      }
    };

Map<String, dynamic> _emptyEnvelope() => {
      'contents': {
        'tabbedSearchResultsRenderer': {
          'tabs': [
            {
              'tabRenderer': {
                'content': {
                  'sectionListRenderer': {'contents': []}
                }
              }
            }
          ]
        }
      }
    };

/// Routes canned youtubei search responses by query, counting requests.
class FakeSearchAdapter implements HttpClientAdapter {
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    await requestStream?.drain<void>();
    final raw = options.data;
    final body = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : (raw as Map).cast<String, dynamic>();
    final query = body['query'] as String? ?? '';
    final Map<String, dynamic> payload;
    if (query.contains('Missing Song')) {
      payload = _emptyEnvelope();
    } else if (query.contains('Shelf Song')) {
      payload = _shelfEnvelope('shelfVid1');
    } else {
      payload = _cardEnvelope('abc123XYZ-_');
    }
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {Headers.contentTypeHeader: ['application/json']},
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('chunking', () {
    List<ResolvedSong> resolved(int count, {Set<int> unmatched = const {}}) {
      return [
        for (var i = 0; i < count; i++)
          ResolvedSong(
            track: _track('Artist', 'Song $i'),
            videoId: unmatched.contains(i) ? null : 'v$i',
          ),
      ];
    }

    test('single chunk for 50 songs', () {
      final chunks = buildExportChunks(resolved(50));
      expect(chunks.length, 1);
      expect(chunks.single.label, 'Part 1 (songs 1–50)');
      expect(chunks.single.videoIds.length, 50);
      expect(chunks.single.url,
          'https://www.youtube.com/watch_videos?video_ids=${List.generate(50, (i) => 'v$i').join(',')}');
    });

    test('51 songs split into 50 + 1 with correct labels', () {
      final chunks = buildExportChunks(resolved(51));
      expect(chunks.length, 2);
      expect(chunks[0].label, 'Part 1 (songs 1–50)');
      expect(chunks[1].label, 'Part 2 (songs 51–51)');
      expect(chunks[1].videoIds, ['v50']);
    });

    test('120 songs split into 50 + 50 + 20', () {
      final chunks = buildExportChunks(resolved(120));
      expect(chunks.map((c) => c.label).toList(), [
        'Part 1 (songs 1–50)',
        'Part 2 (songs 51–100)',
        'Part 3 (songs 101–120)',
      ]);
      expect(chunks.map((c) => c.videoIds.length).toList(), [50, 50, 20]);
    });

    test('unmatched songs are excluded from URLs but reported', () {
      final songs = resolved(3, unmatched: {1});
      final resolution = ExportResolution(songs: songs);
      expect(resolution.chunks.single.videoIds, ['v0', 'v2']);
      expect(resolution.unmatched.map((t) => t.title).toList(), ['Song 1']);
    });

    test('empty input produces no chunks', () {
      expect(buildExportChunks([]), isEmpty);
    });
  });

  group('search parsing', () {
    test('card top hit, live-verified shape', () {
      expect(
        YouTubeVideoResolver.parseSearchVideoId(
            _cardEnvelope('56CJ2daZB-Y')),
        '56CJ2daZB-Y',
      );
    });

    test('falls back to the first shelf item videoId', () {
      expect(
        YouTubeVideoResolver.parseSearchVideoId(_shelfEnvelope('shelfVid1')),
        'shelfVid1',
      );
    });

    test('no video in the envelope yields null', () {
      expect(
        YouTubeVideoResolver.parseSearchVideoId(_emptyEnvelope()),
        isNull,
      );
    });
  });

  group('resolver + cache', () {
    late FakeSearchAdapter adapter;
    late YouTubeVideoResolver resolver;
    late InMemoryVideoIdCache cache;

    setUp(() {
      final dio = Dio();
      adapter = FakeSearchAdapter();
      dio.httpClientAdapter = adapter;
      cache = InMemoryVideoIdCache();
      resolver = YouTubeVideoResolver(dio, cache: cache);
    });

    test('cache hit avoids a second network request', () async {
      final track = _track('Artist A', 'Song One');
      expect(await resolver.resolve(track), 'abc123XYZ-_');
      expect(await resolver.resolve(track), 'abc123XYZ-_');
      expect(adapter.requests, 1);
    });

    test('miss is not retried within 7 days, but is after 8 days', () async {
      final track = _track('Unknown', 'Missing Song');
      final day0 = DateTime(2026, 10, 24);
      expect(await resolver.resolve(track, now: day0), isNull);
      expect(adapter.requests, 1);
      expect(await resolver.resolve(track, now: day0.add(
        const Duration(days: 6, hours: 23),
      )), isNull);
      expect(adapter.requests, 1);
      expect(await resolver.resolve(track, now: day0.add(
        const Duration(days: 8),
      )), isNull);
      expect(adapter.requests, 2);
    });

    test('resolveAll reports unmatched and progress', () async {
      final tracks = [
        _track('Artist A', 'Song One'),
        _track('Unknown', 'Missing Song'),
        _track('Artist B', 'Shelf Song'),
      ];
      final progress = <int>[];
      final resolution = await resolver.resolveAll(
        tracks,
        onProgress: (done, _) => progress.add(done),
      );
      expect(resolution.cancelled, isFalse);
      expect(resolution.resolved.map((s) => s.videoId).toList(),
          ['abc123XYZ-_', 'shelfVid1']);
      expect(resolution.unmatched.map((t) => t.title).toList(),
          ['Missing Song']);
      expect(progress.last, 3);
    });

    test('cancellation stops resolution and flags it', () async {
      final resolution = await resolver.resolveAll(
        [_track('Artist A', 'Song One')],
        isCancelled: () => true,
      );
      expect(resolution.cancelled, isTrue);
      expect(resolution.songs, isEmpty);
      expect(adapter.requests, 0);
    });
  });

  test('miss retry rule is 7 days', () {
    final missed = DateTime(2026, 10, 24);
    expect(
      shouldRetryMissAfter(null, missed),
      isTrue,
    );
    expect(
      shouldRetryMissAfter(missed, missed.add(const Duration(days: 6))),
      isFalse,
    );
    expect(
      shouldRetryMissAfter(missed, missed.add(const Duration(days: 7))),
      isTrue,
    );
  });
}
