// Spotify import review tests (push 3, fixture-based, no network):
// the honest readable-count label, the YouTube-match summary, and the
// review widget's resolve → summary → onResolved flow (youtubei search
// faked by FakeSearchAdapter from youtube_export_test.dart).

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/data/export/youtube_export.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/providers.dart';
import 'package:music_man/presentation/widgets/spotify_youtube_review.dart';

import 'youtube_export_test.dart';

void main() {
  // The widget test injects InMemoryVideoIdCache: the widget's
  // production Hive open does real file I/O, which never completes
  // under the widget-test binding's fake async.
  group('readableCountLabel', () {
    test('names the readable count and the restricted remainder', () {
      expect(
        readableCountLabel(
          total: 320,
          readable: 311,
          platformName: 'Spotify',
        ),
        '311 of 320 tracks readable — 9 restricted by Spotify',
      );
    });

    test('returns null when the whole playlist was read', () {
      expect(
        readableCountLabel(
          total: 320,
          readable: 320,
          platformName: 'Spotify',
        ),
        isNull,
      );
    });

    test('returns null when the total is unknown', () {
      expect(
        readableCountLabel(
          total: 0,
          readable: 0,
          platformName: 'Spotify',
        ),
        isNull,
      );
    });

    test('returns null when readable exceeds the total', () {
      expect(
        readableCountLabel(
          total: 10,
          readable: 12,
          platformName: 'Deezer',
        ),
        isNull,
      );
    });
  });

  group('youTubeMatchSummary', () {
    test('names matched, total, and unmatched', () {
      expect(
        youTubeMatchSummary(matched: 287, total: 311),
        '287 of 311 found on YouTube — 24 unmatched',
      );
    });

    test('all matched still names the zero unmatched', () {
      expect(
        youTubeMatchSummary(matched: 5, total: 5),
        '5 of 5 found on YouTube — 0 unmatched',
      );
    });

    test('none matched', () {
      expect(
        youTubeMatchSummary(matched: 0, total: 3),
        '0 of 3 found on YouTube — 3 unmatched',
      );
    });
  });

  group('SpotifyYouTubeReview widget', () {
    testWidgets('resolves tracks and reports matched/unmatched',
        (tester) async {
      final dio = Dio()..httpClientAdapter = FakeSearchAdapter();
      ExportResolution? reported;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dioProvider.overrideWithValue(dio)],
          child: MaterialApp(
            home: Scaffold(
              body: SpotifyYouTubeReview(
                tracks: const [
                  Track(artist: 'Singer A', title: 'Found Song'),
                  Track(artist: 'Singer B', title: 'Missing Song'),
                ],
                cache: InMemoryVideoIdCache(),
                onResolved: (r) => reported = r,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Check YouTube matches'), findsOneWidget);
      await tester.tap(find.text('Check YouTube matches'));
      await tester.pumpAndSettle();

      expect(
        find.text('1 of 2 found on YouTube — 1 unmatched'),
        findsOneWidget,
      );
      expect(find.text('Check again'), findsOneWidget);
      expect(reported, isNotNull);
      expect(reported!.resolved.length, 1);
      expect(reported!.unmatched.length, 1);
      expect(reported!.unmatched.single.title, 'Missing Song');
    });

    testWidgets('button is disabled with no tracks', (tester) async {
      final dio = Dio()..httpClientAdapter = FakeSearchAdapter();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [dioProvider.overrideWithValue(dio)],
          child: MaterialApp(
            home: Scaffold(
              body: SpotifyYouTubeReview(
                tracks: const [],
                cache: InMemoryVideoIdCache(),
                onResolved: _noop,
              ),
            ),
          ),
        ),
      );

      final button = tester.widget<OutlinedButton>(
        find.byType(OutlinedButton),
      );
      expect(button.onPressed, isNull);
    });
  });
}

void _noop(ExportResolution _) {}
