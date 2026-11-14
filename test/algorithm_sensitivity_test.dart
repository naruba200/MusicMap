// Sensitivity tests for the recommendation inputs the user asked about
// (2026-11-14): do recommendations actually change when (a) the account
// has liked songs vs none, (b) the mood changes, (c) the genre changes?
//
// What the code really does (read, not guessed):
// - Mood/genre chips map to Last.fm tags (tagForLabel) whose top tracks
//   become tag seeds (selectTagSeeds) and a modifier pool (buildTagPool)
//   injected into the final list by blendWithInjections (~1/2 quota).
// - Liked songs feed generation ONLY through Fresh Finds
//   (settings.freshFinds): favorited artists' top tracks head the
//   fresh pool (GenerationNotifier._buildFreshPool) and are appended to
//   the modifier pool with reason 'Based on your favorites'. With Fresh
//   Finds off, likes do not change generation at all.
// These tests pin the pure-engine half of each path with fixed fake
// data: same core input, different tag/fresh inputs -> different output.

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/lastfm/lastfm_client.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/presentation/providers/generation_provider.dart';

List<ScoredTrack> _core(int n) => [
      for (var i = 0; i < n; i++)
        ScoredTrack(
          track: Track(artist: 'Core Artist $i', title: 'Core Song $i'),
          score: 10.0 - i,
          reasons: const ['Similar to Seed'],
        ),
    ];

List<TagTrack> _tagTracks(String tag, int n) => [
      for (var i = 0; i < n; i++)
        TagTrack(
          artist: '$tag Artist $i',
          title: '$tag Song $i',
          listeners: 1000 - i,
        ),
    ];

List<ScoredTrack> _blend({
  required List<ScoredTrack> core,
  List<ScoredTrack> modifierPool = const [],
  List<TagTrack> chartTracks = const [],
  int total = 10,
}) =>
    RecommendationEngine.blendWithInjections(
      core: core,
      modifierPool: modifierPool,
      chartTracks: chartTracks,
      total: total,
      seedKeys: const {},
    );

Set<String> _keys(List<ScoredTrack> list) => {
      for (final s in list)
        RecommendationEngine.normalizeKey(s.track.artist, s.track.title),
    };

void main() {
  group('mood changes the recommendations', () {
    test('different moods build different tag pools', () {
      // Real labels, real mapping: Chill -> 'chill', Happy -> 'happy'.
      expect(tagForLabel('Chill'), 'chill');
      expect(tagForLabel('Happy'), 'happy');

      final chillPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'chill': _tagTracks('chill', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'chill': 'chill'},
      );
      final happyPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'happy': _tagTracks('happy', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'happy': 'happy'},
      );
      // The pools must not be the same set of tracks.
      expect(_keys(chillPool), isNot(_keys(happyPool)));
      expect(
        _keys(chillPool).contains('chill artist 0 - chill song 0'),
        isTrue,
      );
      expect(
        _keys(happyPool).contains('happy artist 0 - happy song 0'),
        isTrue,
      );
    });

    test('different moods blend different tracks into the final list', () {
      final core = _core(10);
      final chillPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'chill': _tagTracks('chill', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'chill': 'chill'},
      );
      final happyPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'happy': _tagTracks('happy', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'happy': 'happy'},
      );
      final chillList = _blend(core: core, modifierPool: chillPool);
      final happyList = _blend(core: core, modifierPool: happyPool);
      expect(_keys(chillList), isNot(_keys(happyList)));
      expect(_keys(chillList).contains('chill artist 0 - chill song 0'),
          isTrue);
      expect(_keys(happyList).contains('chill artist 0 - chill song 0'),
          isFalse);
      expect(_keys(happyList).contains('happy artist 0 - happy song 0'),
          isTrue);
    });
  });

  group('genre changes the recommendations', () {
    test('different genres build different tag pools', () {
      // Real labels, real mapping: J-Pop -> 'j-pop', Rock -> 'rock'.
      expect(tagForLabel('J-Pop'), 'j-pop');
      expect(tagForLabel('Rock'), 'rock');

      final jpopPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'j-pop': _tagTracks('j-pop', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'j-pop': 'j-pop'},
      );
      final rockPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'rock': _tagTracks('rock', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'rock': 'rock'},
      );
      expect(_keys(jpopPool), isNot(_keys(rockPool)));
      expect(
        _keys(jpopPool).contains('j-pop artist 0 - j-pop song 0'),
        isTrue,
      );
      expect(
        _keys(rockPool).contains('rock artist 0 - rock song 0'),
        isTrue,
      );
    });

    test('different genres blend different tracks into the final list', () {
      final core = _core(10);
      final jpopPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'j-pop': _tagTracks('j-pop', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'j-pop': 'j-pop'},
      );
      final rockPool = RecommendationEngine.buildTagPool(
        tagSeeds: RecommendationEngine.selectTagSeeds({
          'rock': _tagTracks('rock', 6),
        }).seeds,
        similarBySeed: const {},
        tagOfKey: {'rock': 'rock'},
      );
      final jpopList = _blend(core: core, modifierPool: jpopPool);
      final rockList = _blend(core: core, modifierPool: rockPool);
      expect(_keys(jpopList), isNot(_keys(rockList)));
      expect(_keys(jpopList).contains('j-pop artist 0 - j-pop song 0'),
          isTrue);
      expect(_keys(rockList).contains('j-pop artist 0 - j-pop song 0'),
          isFalse);
      expect(_keys(rockList).contains('rock artist 0 - rock song 0'),
          isTrue);
    });
  });

  group('liked songs change the recommendations (Fresh Finds)', () {
    test('a learned fresh pool injects favorited-artist tracks, '
        'a plain chart does not', () {
      // The fresh pool _buildFreshPool returns: learned tracks (from
      // favorited artists) ahead of the global chart when likes exist,
      // the plain chart when they do not.
      final learned = GenerationNotifier.mergeLearnedFreshPool(
        learned: _tagTracks('liked', 4),
        chart: _tagTracks('chart', 6),
      );
      final plain = GenerationNotifier.mergeLearnedFreshPool(
        learned: const [],
        chart: _tagTracks('chart', 6),
      );
      expect(learned.first.title, 'liked Song 0');
      expect(learned.map((t) => t.title), contains('chart Song 0'));
      expect(plain.map((t) => t.title), isNot(contains('liked Song 0')));

      final core = _core(10);
      final withLikes = _blend(core: core, chartTracks: learned);
      final withoutLikes = _blend(core: core, chartTracks: plain);
      expect(_keys(withLikes), isNot(_keys(withoutLikes)));
      expect(_keys(withLikes).contains('liked artist 0 - liked song 0'),
          isTrue);
      expect(_keys(withoutLikes).contains('liked artist 0 - liked song 0'),
          isFalse);
    });
  });
}
