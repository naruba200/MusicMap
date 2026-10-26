// YouTube Music full-import tests (Phase 4a, fixture-based, no network):
// when a WEB_REMIX page 1 hits the 100-track cap, the adapter must walk
// the same playlist via TVHTML5, merge by videoId (WEB_REMIX entries win),
// and flag a cut-short import with truncated instead of silently
// returning the first 100 tracks.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/platforms/youtube_music_platform.dart';

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

/// One TVHTML5 tile: a single-string title + watchEndpoint videoId.
Map<String, dynamic> _tile(String videoId, Map<String, dynamic> title) => {
      'tileRenderer': {
        'metadata': {
          'tileMetadataRenderer': {'title': title}
        },
        'onSelectCommand': {
          'watchEndpoint': {'videoId': videoId}
        },
      }
    };

Map<String, dynamic> _simpleTitle(String text) => {'simpleText': text};

Map<String, dynamic> _runsTitle(String text) => {
      'runs': [
        {'text': text}
      ]
    };

/// Routes canned youtubei responses by request host + body, the way the
/// adapter splits them: music.youtube.com = WEB_REMIX, www.youtube.com =
/// TVHTML5.
class FakeFullImportAdapter implements HttpClientAdapter {
  /// When true, every TVHTML5 call fails (HTTP 500) — the adapter must
  /// fall back to WEB_REMIX paging.
  final bool tvFails;

  /// When true, every TVHTML5 page carries a next token with fresh
  /// tiles, so the walk must stop at the page cap, flagged truncated.
  final bool tvEndless;

  var _endlessPage = 0;

  FakeFullImportAdapter({this.tvFails = false, this.tvEndless = false});

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
    if (options.uri.host == 'www.youtube.com') {
      if (tvFails) {
        return ResponseBody.fromString('{}', 500, headers: {
          Headers.contentTypeHeader: ['application/json'],
        });
      }
      if (tvEndless) {
        _endlessPage++;
        final tiles = List.generate(
            15,
            (i) => _tile('tv$_endlessPage-$i',
                _simpleTitle('Endless Artist - Endless Song')));
        // First page uses the renderer shape, later pages the
        // continuation shape — exactly like the real client.
        if (body.containsKey('browseId')) {
          return _ok(_tvFirstPage(tiles, 'TVNEXT'));
        }
        return _ok(_tvContinuation(tiles, 'TVNEXT'));
      }
      if (body.containsKey('browseId')) {
        // TV page 1: 15 tiles overlapping the WEB_REMIX first 100,
        // under the playlistVideoListRenderer the adapter searches for.
        final tiles = List.generate(
            15,
            (i) => _tile('v$i', _simpleTitle('TV Artist $i - TV Song $i')));
        return _ok(_tvFirstPage(tiles, 'TV2'));
      }
      // TV page 2: remainder tracks only, exercising title splitting:
      // hyphen split, no separator, en-dash split, runs (not simpleText).
      return _ok(_tvContinuation([
        _tile('v100', _simpleTitle('Artist X - Extra One')),
        _tile('v101', _simpleTitle('No Separator Song')),
        _tile('v102', _simpleTitle('Artist Y \u2013 Dash Song')),
        _tile('v103', _runsTitle('Artist Z - Runs Song')),
      ], null));
    }
    // WEB_REMIX host.
    if (body.containsKey('browseId')) {
      return _ok(_webPage1);
    }
    // Any WEB_REMIX continuation dead-ends on carousels only.
    return _ok(_carouselOnly);
  }

  ResponseBody _ok(Map<String, dynamic> payload) =>
      ResponseBody.fromString(jsonEncode(payload), 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });

  @override
  void close({bool force = false}) {}

  // WEB_REMIX page 1: exactly 100 items, section-list token only
  // (no shelf token) — the live dead-end shape.
  static final _webPage1 = {
    'contents': {
      'twoColumnBrowseResultsRenderer': {
        'secondaryContents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicPlaylistShelfRenderer': {
                  'contents': List.generate(
                      100, (i) => _item('Song $i', 'Artist $i', 'v$i')),
                }
              }
            ],
            ..._token('DEAD_TOKEN'),
          }
        }
      }
    }
  };

  static final _carouselOnly = {
    'continuationContents': {
      'sectionListContinuation': {
        'contents': [
          {'musicCarouselShelfRenderer': {}}
        ]
      }
    }
  };

  Map<String, dynamic> _tvFirstPage(
      List<Map<String, dynamic>> tiles, String token) {
    final node = <String, dynamic>{'contents': tiles}..addAll(_token(token));
    return {
      'contents': {
        'tvBrowseRenderer': {
          'content': {
            'twoColumnRenderer': {
              'rightColumn': {'playlistVideoListRenderer': node}
            }
          }
        }
      }
    };
  }

  Map<String, dynamic> _tvContinuation(
      List<Map<String, dynamic>> tiles, String? token) {
    final node = <String, dynamic>{'contents': tiles};
    if (token != null) node.addAll(_token(token));
    return {
      'continuationContents': {'playlistVideoListContinuation': node}
    };
  }
}

YouTubeMusicPlatform _platform({bool tvFails = false, bool tvEndless = false}) {
  final dio = Dio();
  dio.httpClientAdapter =
      FakeFullImportAdapter(tvFails: tvFails, tvEndless: tvEndless);
  return YouTubeMusicPlatform(dio);
}

void main() {
  test('full import merges WEB_REMIX 100 with TVHTML5 remainder', () async {
    final page = await _platform().fetchPlaylistTracks('PLx');
    expect(page.hasMore, isFalse);
    expect(page.truncated, isFalse);
    expect(page.tracks.length, 104);
    // WEB_REMIX entries win for the overlapping first 100.
    expect(page.tracks[0].title, 'Song 0');
    expect(page.tracks[0].artist, 'Artist 0');
    expect(page.tracks[99].title, 'Song 99');
    // TVHTML5 remainder, in TV order, titles split on the separator.
    expect(page.tracks[100].title, 'Extra One');
    expect(page.tracks[100].artist, 'Artist X');
    expect(page.tracks[100].platformTrackId, 'v100');
    // No separator: whole string stays the title, artist unknown.
    expect(page.tracks[101].title, 'No Separator Song');
    expect(page.tracks[101].artist, 'Unknown artist');
    // En-dash separator splits too.
    expect(page.tracks[102].title, 'Dash Song');
    expect(page.tracks[102].artist, 'Artist Y');
    // Runs-style title (no simpleText) parses as well.
    expect(page.tracks[103].title, 'Runs Song');
    expect(page.tracks[103].artist, 'Artist Z');
    // No duplicates across the merge.
    final ids = page.tracks.map((t) => t.platformTrackId).toSet();
    expect(ids.length, page.tracks.length);
  });

  test('TV failure falls back to WEB_REMIX; dead-end flags truncated',
      () async {
    final platform = _platform(tvFails: true);
    final page1 = await platform.fetchPlaylistTracks('PLx');
    expect(page1.tracks.length, 100);
    expect(page1.hasMore, isTrue);
    expect(page1.cursor, 'DEAD_TOKEN');
    expect(page1.truncated, isFalse);
    final deadEnd =
        await platform.fetchPlaylistTracks('PLx', cursor: 'DEAD_TOKEN');
    expect(deadEnd.tracks, isEmpty);
    expect(deadEnd.hasMore, isFalse);
    expect(deadEnd.truncated, isTrue);
  });

  test('TV page cap stops cleanly and flags truncated', () async {
    final page = await _platform(tvEndless: true).fetchPlaylistTracks('PLx');
    expect(page.hasMore, isFalse);
    expect(page.truncated, isTrue);
    // 100 WEB_REMIX tracks + 67 TV pages x 15 fresh tiles (the endless
    // fixture never overlaps WEB_REMIX ids, so nothing dedupes).
    expect(page.tracks.length, 100 + 67 * 15);
    final ids = page.tracks.map((t) => t.platformTrackId).toSet();
    expect(ids.length, page.tracks.length);
  });
}
