// Tests for the resolution log (see
// lib/data/fullsong/resolution_log.dart): in-memory ring buffer,
// last ~100 attempts, newest last; the notifier wrapper re-emits the
// list for the Playback log screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/fullsong/resolution_log.dart';
import 'package:music_man/data/models/music_models.dart';

ResolutionEntry _entry(String title, {String detail = ''}) =>
    ResolutionEntry.forTrack(
      Track(artist: 'Singer', title: title),
      attempts: [
        SourceAttempt(
          source: 'audius',
          outcome: SourceOutcome.noMatch,
          detail: detail,
        ),
      ],
      result: 'No full stream found',
    );

void main() {
  group('ResolutionLog ring buffer', () {
    test('records entries in order with track key + attempts', () {
      final log = ResolutionLog();
      log.record(_entry('Song', detail: 'No title match'));
      expect(log.entries, hasLength(1));
      final entry = log.entries.single;
      expect(entry.trackKey, 'singer - song');
      expect(entry.title, 'Song');
      expect(entry.artist, 'Singer');
      expect(entry.result, 'No full stream found');
      expect(entry.attempts.single.source, 'audius');
      expect(entry.attempts.single.outcome, SourceOutcome.noMatch);
      expect(entry.attempts.single.detail, 'No title match');
    });

    test('caps at 100 entries, dropping the oldest', () {
      final log = ResolutionLog();
      for (var i = 0; i < 105; i++) {
        log.record(_entry('Song $i'));
      }
      expect(log.entries, hasLength(100));
      expect(log.entries.first.title, 'Song 5');
      expect(log.entries.last.title, 'Song 104');
    });

    test('clear empties the log', () {
      final log = ResolutionLog();
      log.record(_entry('Song'));
      log.clear();
      expect(log.entries, isEmpty);
    });
  });

  group('ResolutionLogNotifier', () {
    test('record re-emits the entry list; clear re-emits empty', () {
      final notifier = ResolutionLogNotifier();
      expect(notifier.state, isEmpty);
      notifier.record(_entry('Song'));
      expect(notifier.state, hasLength(1));
      expect(notifier.state.single.title, 'Song');
      notifier.clear();
      expect(notifier.state, isEmpty);
    });

    test('a record made straight into the shared log re-emits state',
        () {
      // Regression test for the blank Playback log: the resolver
      // records straight into notifier.log, bypassing
      // notifier.record. The state must still update, or the screen
      // (which watches the state) stays empty while the buffer fills.
      final notifier = ResolutionLogNotifier();
      expect(notifier.state, isEmpty);
      notifier.log.record(_entry('Song'));
      expect(notifier.state, hasLength(1));
      expect(notifier.state.single.title, 'Song');
      notifier.log.clear();
      expect(notifier.state, isEmpty);
    });
  });

  group('SourceOutcome labels', () {
    test('every outcome has a human label', () {
      expect(SourceOutcome.matched.label, 'Matched');
      expect(SourceOutcome.noMatch.label, 'No match');
      expect(SourceOutcome.networkError.label, 'Network error');
      expect(SourceOutcome.noDirectUrl.label, 'No direct audio URL');
      expect(
          SourceOutcome.drmUnplayable.label, 'Audio cannot play in-app');
      expect(SourceOutcome.sessionRejected.label, 'Session rejected');
      expect(SourceOutcome.skipped.label, 'Skipped');
    });
  });
}
