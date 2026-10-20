// YouTube Music paging tests (fixture-based, no network): the adapter
// must (a) prefer the shelf's own continuation token on page 1,
// (b) read track pages from BOTH continuation shapes observed live
// (2026-10-20), and (c) stop cleanly when a continuation yields only
// related-content carousels.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/platforms/youtube_music_platform.dart';

Map<String, dynamic> _item(String title, String artist, String videoId) => {
      'musicResponsiveListItemRenderer': {
        'flexColumns': [
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {'text': title}
                ]
              }
            }
          },
          {
            'musicResponsiveListItemFlexColumnRenderer': {
              'text': {
                'runs': [
                  {'text': artist}
                ]
              }
            }
          },
        ],
        'playlistItemData': {'videoId': videoId},
      }
    };

Map<String, dynamic> _token(String value) => {
      'continuations': [
        {
          'nextContinuationData': {'continuation': value}
        }
      ]
    };

/// Routes canned youtubei responses by request body.
class FakeYouTubeAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    final raw = options.data;
    final body = raw is String
        ? jsonDecode(raw) as Map<String, dynamic>
        : (raw as Map).cast<String, dynamic>();
    final Map<String, dynamic> payload;
    if (body.containsKey('browseId')) {
      payload = _page1;
    } else {
      payload = switch (body['continuation']) {
        'SHELF_TOKEN' => _shelfContinuation,
        'SECTION_TOKEN' => _sectionWithShelf,
        _ => _carouselOnly,
      };
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

  // Page 1: shelf carries its own token AND the section list has a
  // different one — the shelf's must win.
  static final _page1 = {
    'contents': {
      'twoColumnBrowseResultsRenderer': {
        'secondaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicPlaylistShelfRenderer': {
                  'contents': [_item('One', 'Artist A', 'v1')],
                  ..._token('SHELF_TOKEN'),
                }
              }
            ],
            ..._token('SECTION_TOKEN'),
          }
        }
      }
    }
  };

  // Shape 1: shelf continuation with items directly + its own next token.
  static final _shelfContinuation = {
    'continuationContents': {
      'musicPlaylistShelfContinuation': {
        'contents': [_item('Two', 'Artist B', 'v2')],
        ..._token('NEXT_TOKEN'),
      }
    }
  };

  // Shape 2: section continuation wrapping a fresh shelf.
  static final _sectionWithShelf = {
    'continuationContents': {
      'sectionListContinuation': {
        'contents': [
          {
            'musicPlaylistShelfRenderer': {
              'contents': [_item('Three', 'Artist C', 'v3')],
            }
          }
        ]
      }
    }
  };

  // A continuation that yields only carousels: no shelf, paging ends.
  static final _carouselOnly = {
    'continuationContents': {
      'sectionListContinuation': {
        'contents': [
          {'musicCarouselShelfRenderer': {}}
        ]
      }
    }
  };
}

void main() {
  late YouTubeMusicPlatform platform;

  setUp(() {
    final dio = Dio();
    dio.httpClientAdapter = FakeYouTubeAdapter();
    platform = YouTubeMusicPlatform(dio);
  });

  test('page 1 prefers the shelf continuation token', () async {
    final page = await platform.fetchPlaylistTracks('PLx');
    expect(page.tracks.single.title, 'One');
    expect(page.hasMore, isTrue);
    expect(page.cursor, 'SHELF_TOKEN');
  });

  test('shape 1: musicPlaylistShelfContinuation pages onward', () async {
    final page = await platform.fetchPlaylistTracks('PLx', cursor: 'SHELF_TOKEN');
    expect(page.tracks.single.title, 'Two');
    expect(page.hasMore, isTrue);
    expect(page.cursor, 'NEXT_TOKEN');
  });

  test('shape 2: sectionListContinuation wrapping a shelf', () async {
    final page =
        await platform.fetchPlaylistTracks('PLx', cursor: 'SECTION_TOKEN');
    expect(page.tracks.single.title, 'Three');
    expect(page.hasMore, isFalse); // no further token anywhere
  });

  test('carousel-only continuation ends paging without error', () async {
    final page = await platform.fetchPlaylistTracks('PLx', cursor: 'NEXT_TOKEN');
    expect(page.tracks, isEmpty);
    expect(page.hasMore, isFalse);
  });
}
