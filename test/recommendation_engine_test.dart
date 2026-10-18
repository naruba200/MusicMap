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

  group('boosts', () {
    List<ScoredTrack> one(double score) => [
          ScoredTrack(track: _t('A', 'T'), score: score, reasons: const [])
        ];

    test('modifier boost multiplies by (1 + 0.5 * tagHits)', () {
      final key = RecommendationEngine.normalizeKey('A', 'T');
      final boosted = RecommendationEngine.applyModifierBoost(
          one(2.0), [{key}, {key}, {'other - x'}]);
      expect(boosted.single.score, closeTo(4.0, 1e-9)); // 2 hits
      final single = RecommendationEngine.applyModifierBoost(one(2.0), [{key}]);
      expect(single.single.score, closeTo(3.0, 1e-9)); // 1 hit
    });

    test('fresh boost multiplies trending candidates by 1.3', () {
      final key = RecommendationEngine.normalizeKey('A', 'T');
      final boosted = RecommendationEngine.applyFreshBoost(one(2.0), {key});
      expect(boosted.single.score, closeTo(2.6, 1e-9));
      final untouched =
          RecommendationEngine.applyFreshBoost(one(2.0), {'zzz - q'});
      expect(untouched.single.score, 2.0);
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
  });
}
