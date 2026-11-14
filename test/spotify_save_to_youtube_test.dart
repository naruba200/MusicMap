// Save to YouTube tests (push 4, fixture-based, no network): the
// Save-button gating helper, and the extracted result sheet rendering
// chunk buttons + the unmatched list for a finished resolution.

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:music_man/data/export/youtube_export.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/widgets/spotify_youtube_review.dart';
import 'package:music_man/presentation/widgets/youtube_export_sheet.dart';

const _fixture = ExportResolution(songs: [
  ResolvedSong(
      track: Track(artist: 'Singer A', title: 'Found 1'), videoId: 'vid1'),
  ResolvedSong(
      track: Track(artist: 'Singer A', title: 'Found 2'), videoId: 'vid2'),
  ResolvedSong(
      track: Track(artist: 'Singer B', title: 'Missing Song'),
      videoId: null),
]);

void main() {
  group('canSaveToYouTube', () {
    test('false with no resolution', () {
      expect(canSaveToYouTube(null), isFalse);
    });

    test('false when nothing matched', () {
      const resolution = ExportResolution(songs: [
        ResolvedSong(
            track: Track(artist: 'A', title: 'Missing'), videoId: null),
      ]);
      expect(canSaveToYouTube(resolution), isFalse);
    });

    test('true when at least one song matched', () {
      const resolution = ExportResolution(songs: [
        ResolvedSong(
            track: Track(artist: 'A', title: 'Found'), videoId: 'vid1'),
        ResolvedSong(
            track: Track(artist: 'B', title: 'Missing'), videoId: null),
      ]);
      expect(canSaveToYouTube(resolution), isTrue);
    });
  });

  group('showYouTubeExportResultSheet', () {
    testWidgets('shows chunk button and unmatched list', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    showYouTubeExportResultSheet(context, _fixture),
                child: const Text('Show sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Export to YouTube'), findsOneWidget);
      expect(find.text('Open playlist (2 songs)'), findsOneWidget);
      expect(find.text("1 songs couldn't be matched:"), findsOneWidget);
      expect(find.text('Missing Song'), findsOneWidget);
      expect(
        find.text('Tap Save in YouTube / YouTube Music to keep this playlist.'),
        findsOneWidget,
      );
    });

    testWidgets('says so when nothing matched', (tester) async {
      const empty = ExportResolution(songs: [
        ResolvedSong(
            track: Track(artist: 'A', title: 'Missing'), videoId: null),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () =>
                    showYouTubeExportResultSheet(context, empty),
                child: const Text('Show sheet'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Show sheet'));
      await tester.pumpAndSettle();

      expect(
        find.text('No songs could be matched to YouTube videos.'),
        findsOneWidget,
      );
      expect(find.textContaining('Open playlist'), findsNothing);
    });
  });
}
