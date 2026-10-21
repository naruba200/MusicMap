import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';

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
    ScoredTrack pool(String title, [String reason = 'Popular in rock']) =>
        ScoredTrack(track: _t('Pool', title), score: 1, reasons: [reason]);
    TagTrack tt(String artist, String title, [int listeners = 100]) =>
        TagTrack(artist: artist, title: title, listeners: listeners);
    List<ScoredTrack> coreOf(int n) =>
        [for (var i = 0; i < n; i++) s('Core$i', 'Song$i', (n - i) * 10.0)];
    int withReason(List<ScoredTrack> list, String reason) =>
        list.where((e) => e.reasons.contains(reason)).length;

    test('no pools returns the core top-N untouched', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(5),
        modifierPool: const [],
        chartTracks: const [],
        total: 3,
        seedKeys: const {},
      );
      expect(out.length, 3);
      expect(out.map((e) => e.track.title), ['Song0', 'Song1', 'Song2']);
      expect(out.map((e) => e.score), [50.0, 40.0, 30.0]);
    });

    test('tag pool fills ~1/2 of the list, reasons preserved', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(6),
        modifierPool: [for (var i = 0; i < 6; i++) pool('Tag$i')],
        chartTracks: const [],
        total: 6,
        seedKeys: const {},
      );
      expect(out.length, 6);
      expect(withReason(out, 'Popular in rock'), 3); // (6/2).round()
      expect(out.first.track.title, 'Song0'); // core opens
    });

    test('seed-playlist and core tracks are never injected', () {
      final seedKey = RecommendationEngine.normalizeKey('Seed', 'Mine');
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(6),
        modifierPool: [
          ScoredTrack(
              track: _t('Seed', 'Mine'), score: 1, reasons: const ['x']),
          ScoredTrack(
              track: _t('Core0', 'Song0'), score: 1, reasons: const ['x']),
          pool('Fresh Pick'),
        ],
        chartTracks: const [],
        total: 6,
        seedKeys: {seedKey},
      );
      final injected = out.where((e) => e.track.artist == 'Pool').toList();
      expect(injected.length, 1);
      expect(injected.single.track.title, 'Fresh Pick');
      final keys = out
          .map((e) => RecommendationEngine.normalizeKey(
              e.track.artist, e.track.title))
          .toList();
      expect(keys.toSet().length, keys.length); // no duplicates anywhere
    });

    test('combined cap is 3/5 and fresh yields first', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(30),
        modifierPool: [for (var i = 0; i < 30; i++) pool('Tag$i')],
        chartTracks: [for (var i = 0; i < 30; i++) tt('C$i', 'Chart$i')],
        total: 30,
        seedKeys: const {},
      );
      expect(out.length, 30);
      expect(withReason(out, 'Popular in rock'), 15); // (30/2).round()
      expect(withReason(out, 'Trending now'), 3); // 6, cut to cap 18 - 15
      expect(out.where((e) => e.reasons.contains('seed')).length, 12);
    });

    test('pools backfill when the core runs short', () {
      final out = RecommendationEngine.blendWithInjections(
        core: coreOf(2),
        modifierPool: [for (var i = 0; i < 6; i++) pool('Tag$i')],
        chartTracks: const [],
        total: 6,
        seedKeys: const {},
      );
      expect(out.length, 6);
      expect(withReason(out, 'Popular in rock'), 4); // 3 quota + 1 backfill
    });
  });

  group('selectTagSeeds', () {
    TagTrack tt(String artist, String title) =>
        TagTrack(artist: artist, title: title, listeners: 100);

    test('round-robin across tags by rank', () {
      final sel = RecommendationEngine.selectTagSeeds({
        'aaa': [tt('A', 'A1'), tt('A', 'A2'), tt('A', 'A3')],
        'bbb': [tt('B', 'B1'), tt('B', 'B2'), tt('B', 'B3')],
      });
      expect(sel.seeds.map((t) => t.title),
          ['A1', 'B1', 'A2', 'B2', 'A3', 'B3']);
      expect(sel.tagOfKey[RecommendationEngine.normalizeKey('B', 'B2')],
          'bbb');
    });

    test('per-tag and total caps apply', () {
      final sel = RecommendationEngine.selectTagSeeds(
        {
          'aaa': [for (var i = 0; i < 10; i++) tt('A', 'A$i')],
          'bbb': [for (var i = 0; i < 10; i++) tt('B', 'B$i')],
        },
        maxSeeds: 5,
        perTag: 2,
      );
      expect(sel.seeds.length, 4); // 2 per tag, cap binds before maxSeeds
    });

    test('a track in two tags is seeded once, under the first tag', () {
      final sel = RecommendationEngine.selectTagSeeds({
        'aaa': [tt('X', 'Same')],
        'bbb': [tt('X', 'Same'), tt('B', 'B1')],
      });
      expect(sel.seeds.map((t) => t.title), ['Same', 'B1']);
      expect(sel.tagOfKey[RecommendationEngine.normalizeKey('X', 'Same')],
          'aaa');
    });
  });

  group('buildTagPool', () {
    test('tag seeds head the pool, similars follow scored', () {
      final seeds = [_t('S1', 'Seed One'), _t('S2', 'Seed Two')];
      final pool = RecommendationEngine.buildTagPool(
        tagSeeds: seeds,
        similarBySeed: const {
          0: [
            SimilarTrack(artist: 'X', title: 'Sim X', match: 0.9),
            SimilarTrack(artist: 'Y', title: 'Sim Y', match: 0.5),
          ],
          1: [SimilarTrack(artist: 'X', title: 'Sim X', match: 0.8)],
        },
        tagOfKey: {
          RecommendationEngine.normalizeKey('S1', 'Seed One'): 'rock',
          RecommendationEngine.normalizeKey('S2', 'Seed Two'): 'rock',
        },
      );
      expect(pool.map((e) => e.track.title),
          ['Seed One', 'Seed Two', 'Sim X', 'Sim Y']);
      expect(pool[0].reasons, ['Popular in rock']);
      // Sim X: rank 0 under both seeds -> 1/(1+0) + 1/(1+0) = 2.0
      expect(pool[2].score, closeTo(2.0, 1e-9));
      expect(pool[0].score, greaterThan(pool[2].score)); // head sits above
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
