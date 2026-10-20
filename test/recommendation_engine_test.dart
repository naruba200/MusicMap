import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/engine/recommendation_engine.dart';
import 'package:music_map/data/lastfm/lastfm_client.dart';
import 'package:music_map/data/models/music_models.dart';

Track _t(String artist, String title, {String? album}) =>
    Track(artist: artist, title: title, album: album);

void main() {
  group('normalizeKey', () {
    test('lowercases and trims', () {
      expect(RecommendationEngine.normalizeKey('Daft Punk', '  Get Lucky '),
          'daft punk - get lucky');
    });

    test('strips remaster-style suffixes', () {
      expect(
          RecommendationEngine.normalizeKey('Queen', 'Bohemian Rhapsody - Remastered'),
          'queen - bohemian rhapsody');
      expect(
          RecommendationEngine.normalizeKey('Queen', 'Bohemian Rhapsody (Remastered)'),
          'queen - bohemian rhapsody');
    });
  });

  group('primaryArtist', () {
    test('takes the part before feat.', () {
      expect(RecommendationEngine.primaryArtist('A feat. B'), 'A');
      expect(RecommendationEngine.primaryArtist('A ft B'), 'A');
      expect(RecommendationEngine.primaryArtist('A featuring B'), 'A');
    });

    test('leaves plain artists alone (incl. & bands)', () {
      expect(RecommendationEngine.primaryArtist('Earth, Wind & Fire'),
          'Earth, Wind & Fire');
      expect(RecommendationEngine.primaryArtist('Daft Punk'), 'Daft Punk');
    });
  });

  group('selectSeeds', () {
    test('S = min(30, max(10, ceil(n/15)))', () {
      List<Track> nTracks(int n) =>
          [for (var i = 0; i < n; i++) _t('Artist $i', 'Title $i')];
      expect(RecommendationEngine.selectSeeds(nTracks(30)).seeds.length, 10);
      expect(RecommendationEngine.selectSeeds(nTracks(500)).seeds.length, 30);
      expect(RecommendationEngine.selectSeeds(nTracks(150)).seeds.length, 10);
      expect(RecommendationEngine.selectSeeds(nTracks(200)).seeds.length, 14);
    });

    test('small playlists keep all tracks; min 5 to proceed', () {
      final sel = RecommendationEngine.selectSeeds(
          [for (var i = 0; i < 7; i++) _t('A$i', 'T$i')]);
      expect(sel.seeds.length, 7);
      expect(sel.meetsMinimum, isTrue);
      expect(
          RecommendationEngine.selectSeeds(
              [for (var i = 0; i < 4; i++) _t('A$i', 'T$i')]).meetsMinimum,
          isFalse);
    });

    test('dedupes repeated tracks and drops unusable', () {
      final sel = RecommendationEngine.selectSeeds([
        _t('A', 'Same'),
        _t('a', 'same'), // dup after normalization
        _t('', 'NoArtist'),
        _t('NoTitle', ''),
        _t('B', 'Other'),
        _t('C', 'Third'),
        _t('D', 'Fourth'),
        _t('E', 'Fifth'),
      ]);
      expect(sel.usableCount, 5);
      expect(sel.seeds.length, 5);
    });

    test('samples evenly across the playlist', () {
      final tracks = [for (var i = 0; i < 30; i++) _t('A$i', 'T$i')];
      final seeds = RecommendationEngine.selectSeeds(tracks).seeds;
      expect(seeds.first.title, 'T0');
      expect(seeds.last.title, 'T29');
      expect(seeds.length, 10);
    });
  });

  group('scoreCandidates', () {
    test('weights by 1/(1+rank) and sums across seeds', () {
      final seeds = [_t('S1', 'Seed One'), _t('S2', 'Seed Two')];
      final scored = RecommendationEngine.scoreCandidates(
        seeds: seeds,
        similarBySeed: {
          0: const [
            SimilarTrack(artist: 'A', title: 'Hit', match: 0.9),
            SimilarTrack(artist: 'B', title: 'Deep', match: 0.5),
          ],
          1: const [
            SimilarTrack(artist: 'A', title: 'Hit', match: 0.8),
          ],
        },
      );
      expect(scored.length, 2);
      expect(scored[0].track.title, 'Hit');
      expect(scored[0].score, closeTo(2.0, 1e-9)); // 1 + 1
      expect(scored[1].score, closeTo(0.5, 1e-9)); // 1/2
      expect(scored[0].reasons, ['Seed One', 'Seed Two']);
    });

    test('never recommends a seed track', () {
      final seeds = [_t('A', 'Hit')];
      final scored = RecommendationEngine.scoreCandidates(
        seeds: seeds,
        similarBySeed: {
          0: const [SimilarTrack(artist: 'a', title: 'hit ', match: 1.0)],
        },
      );
      expect(scored, isEmpty);
    });
  });

  group('blendWithInjections', () {
    ScoredTrack s(String artist, String title, double score) => ScoredTrack(
        track: _t(artist, title), score: score, reasons: const ['seed']);
    TagTrack tt(String artist, String title, [int listeners = 100]) =>
        TagTrack(artist: artist, title: title, listeners: listeners);
    List<ScoredTrack> coreOf(int n) =>
        [for (var i = 0; i < n; i++) s('Core$i', 'Song$i', (n - i) * 10.0)];
    int withReason(List<ScoredTrack> list, String reason) =>
        list.where((e) => e.reasons.contains(reason)).length;

    test('no injections returns the core top-N untouched', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(5),
        modifierByTag: const {},
        chartTracks: const [],
        total: 3,
        seedKeys: const {},
      );
      expect(out.length, 3);
      expect(out.map((e) => e.track.title), ['Song0', 'Song1', 'Song2']);
      expect(out.map((e) => e.score), [50.0, 40.0, 30.0]);
    });

    test('modifier tracks fill ~1/3 of the list with their tag reason', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(6),
        modifierByTag: {
          'rock': [tt('M1', 'Mod One'), tt('M2', 'Mod Two'), tt('M3', 'Mod 3')]
        },
        chartTracks: const [],
        total: 6,
        seedKeys: const {},
      );
      expect(out.length, 6);
      expect(withReason(out, 'Popular in rock'), 2); // (6/3).round()
      expect(
          out.where((e) => e.reasons.contains('Popular in rock')).map((e) => e.track.title),
          ['Mod One', 'Mod Two']);
      expect(out.first.track.title, 'Song0'); // core opens
    });

    test('seed-playlist and core tracks are never injected', () {
      final seedKey = RecommendationEngine.normalizeKey('Seed', 'Mine');
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(6),
        modifierByTag: {
          'rock': [
            tt('Seed', 'Mine'), // in the seed playlist
            tt('Core0', 'Song0'), // already in the core list
            tt('New', 'Fresh Pick'),
          ]
        },
        chartTracks: const [],
        total: 6,
        seedKeys: {seedKey},
      );
      final injected =
          out.where((e) => e.reasons.contains('Popular in rock')).toList();
      expect(injected.length, 1);
      expect(injected.single.track.title, 'Fresh Pick');
      final keys = out
          .map((e) => RecommendationEngine.normalizeKey(
              e.track.artist, e.track.title))
          .toList();
      expect(keys.toSet().length, keys.length); // no duplicates anywhere
    });

    test('fresh quota is ~1/5 and yields first when the 1/2 cap binds', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(9),
        modifierByTag: {
          'rock': [for (var i = 0; i < 9; i++) tt('M$i', 'Mod$i')]
        },
        chartTracks: [for (var i = 0; i < 9; i++) tt('C$i', 'Chart$i')],
        total: 9,
        seedKeys: const {},
      );
      expect(out.length, 9);
      expect(withReason(out, 'Popular in rock'), 3); // (9/3).round()
      expect(withReason(out, 'Trending now'), 1); // 2, cut to cap 4 - 3
    });

    test('pools backfill when the core runs short', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(2),
        modifierByTag: {
          'rock': [for (var i = 0; i < 6; i++) tt('M$i', 'Mod$i')]
        },
        chartTracks: const [],
        total: 6,
        seedKeys: const {},
      );
      expect(out.length, 6);
      expect(withReason(out, 'Popular in rock'), 4); // 2 quota + 2 backfill
    });

    test('multiple tags contribute round-robin by rank', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(6),
        modifierByTag: {
          'aaa': [tt('A1', 'First A'), tt('A2', 'Second A')],
          'bbb': [tt('B1', 'First B'), tt('B2', 'Second B')],
        },
        chartTracks: const [],
        total: 6,
        seedKeys: const {},
      );
      final injected = out
          .where((e) => e.reasons.single.startsWith('Popular in'))
          .map((e) => e.track.title)
          .toSet();
      expect(injected, {'First A', 'First B'}); // rank 0 of each tag
    });
  });

  group('deriveAlbums', () {
    test('groups by album, ranks by count then best score', () {
      final songs = [
        ScoredTrack(track: _t('A', 'T1', album: 'Alpha'), score: 3.0, reasons: const []),
        ScoredTrack(track: _t('A', 'T2', album: 'Alpha'), score: 1.0, reasons: const []),
        ScoredTrack(track: _t('B', 'T3', album: 'Beta'), score: 5.0, reasons: const []),
        ScoredTrack(track: _t('C', 'T4'), score: 9.0, reasons: const []), // no album
      ];
      final albums = RecommendationEngine.deriveAlbums(songs, 10);
      expect(albums.length, 2);
      expect(albums[0].name, 'Alpha'); // 2 songs beats 1
      expect(albums[0].songCount, 2);
      expect(albums[0].bestScore, closeTo(3.0, 1e-9));
      expect(albums[1].name, 'Beta');
    });
  });

  group('surpriseSongs', () {
    test('merges, dedupes keeping max listeners, ranks desc', () {
      final songs = RecommendationEngine.surpriseSongs(
        topByTag: {
          'rock': const [
            TagTrack(artist: 'A', title: 'Hit', listeners: 100),
            TagTrack(artist: 'B', title: 'Mid', listeners: 50),
          ],
          'pop': const [
            TagTrack(artist: 'A', title: 'Hit', listeners: 200), // dup, higher
          ],
        },
        count: 10,
      );
      expect(songs.length, 2);
      expect(songs[0].track.title, 'Hit');
      expect(songs[0].score, 200);
      expect(songs[0].reasons.single, contains('pop'));
    });

    test('fresh injects chart tracks instead of hard-filtering', () {
      final songs = RecommendationEngine.surpriseSongs(
        topByTag: {
          'rock': [
            for (var i = 0; i < 10; i++)
              TagTrack(artist: 'T$i', title: 'Tag$i', listeners: 100 - i),
          ],
        },
        chartTracks: [
          const TagTrack(artist: 'T0', title: 'Tag0', listeners: 999), // dup
          for (var i = 0; i < 4; i++)
            TagTrack(artist: 'C$i', title: 'Chart$i', listeners: 500 - i),
        ],
        count: 10,
      );
      expect(songs.length, 10);
      // (10/5).round() = 2 chart injections, NOT a filter to overlaps only.
      expect(songs.where((e) => e.reasons.contains('Trending now')).length, 2);
      final keys = songs
          .map((e) => RecommendationEngine.normalizeKey(
              e.track.artist, e.track.title))
          .toList();
      expect(keys.toSet().length, keys.length); // the dup chart track stayed out
    });
  });
}
