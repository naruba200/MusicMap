// Repository tests against a real Hive box in a temp dir (no platform
// channels involved: the repos receive their Box by injection).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:music_man/data/engine/recommendation_engine.dart';
import 'package:music_man/data/models/music_models.dart';
import 'package:music_man/data/repositories/favorites_repository.dart';
import 'package:music_man/data/repositories/history_repository.dart';
import 'package:music_man/data/repositories/playlist_repository.dart';
import 'package:music_man/data/repositories/settings_repository.dart';

void main() {
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('music_man_repo_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  Future<Box> freshBox(String name) async {
    final box = await Hive.openBox(name);
    await box.clear();
    return box;
  }

  group('FavoritesRepository', () {
    late FavoritesRepository repo;

    setUp(() async => repo = FavoritesRepository(await freshBox('fav')));

    test('toggle adds then removes, reporting the new state', () {
      const t = Track(title: 'Song', artist: 'Artist');
      expect(repo.toggle(t), isTrue);
      expect(repo.isFavorite('Artist', 'Song'), isTrue);
      expect(repo.toggle(t), isFalse);
      expect(repo.isFavorite('Artist', 'Song'), isFalse);
    });

    test('keys are normalized: case and suffix variants dedupe', () {
      repo.toggle(const Track(title: 'Song', artist: 'Artist'));
      expect(repo.isFavorite('artist', 'song (remastered)'), isTrue);
      expect(repo.getAll().length, 1);
    });

    test('getAll returns tracks only; favoritedArtists dedupes', () {
      repo.toggle(const Track(title: 'One', artist: 'A'));
      repo.toggle(const Track(title: 'Two', artist: 'A'));
      repo.toggle(const Track(title: 'Three', artist: 'B'));
      expect(repo.getAll().length, 3);
      expect(repo.favoritedArtists().toSet(), {'A', 'B'});
    });

    test('album favorites live alongside tracks without mixing', () {
      repo.toggle(const Track(title: 'Song', artist: 'Artist'));
      final album = AlbumRec(
          name: 'Alb', artist: 'Artist', songCount: 2, bestScore: 1, songs: []);
      expect(repo.toggleAlbum(album), isTrue);
      expect(repo.isAlbumFavorite('Artist', 'Alb'), isTrue);
      expect(repo.getAll().length, 1); // still only the track
      expect(repo.getAlbums().single.name, 'Alb');
      expect(repo.toggleAlbum(album), isFalse);
      expect(repo.getAlbums(), isEmpty);
    });

    test('remove deletes by artist+title', () {
      repo.toggle(const Track(title: 'Song', artist: 'Artist'));
      repo.remove('Artist', 'Song');
      expect(repo.isFavorite('Artist', 'Song'), isFalse);
    });
  });

  group('HistoryRepository', () {
    late HistoryRepository repo;

    setUp(() async => repo = HistoryRepository(await freshBox('hist')));

    HistoryRun run(String id, int day) => HistoryRun(
          id: id,
          timestamp: DateTime.utc(2026, 10, day),
          seedName: 'Seed $id',
          isSurprise: false,
          resultJson: const {'songs': []},
        );

    test('getAll returns newest first', () async {
      await repo.add(run('a', 1));
      await repo.add(run('b', 3));
      await repo.add(run('c', 2));
      expect(repo.getAll().map((r) => r.id), ['b', 'c', 'a']);
    });

    test('remove and clear', () async {
      await repo.add(run('a', 1));
      await repo.remove('a');
      expect(repo.getAll(), isEmpty);
      await repo.add(run('b', 2));
      await repo.clear();
      expect(repo.getAll(), isEmpty);
    });

    test('malformed entries are skipped, not fatal', () async {
      final box = await Hive.openBox('hist');
      await box.put('bad', {'bogus': true});
      await repo.add(run('ok', 1));
      expect(repo.getAll().map((r) => r.id), ['ok']);
    });
  });

  group('SettingsRepository', () {
    late SettingsRepository repo;

    setUp(() async => repo = SettingsRepository(await freshBox('set')));

    test('defaults come from the spec presets', () {
      expect(repo.songCount, 30);
      expect(repo.albumCount, 10);
      expect(repo.selectedPlatformId, 'deezer');
    });

    test('setters persist', () async {
      await repo.setDefaultSongCount(75);
      await repo.setDefaultAlbumCount(20);
      await repo.setSelectedPlatformId('youtube_music');
      expect(repo.songCount, 75);
      expect(repo.albumCount, 20);
      expect(repo.selectedPlatformId, 'youtube_music');
    });
  });

  group('PlaylistRepository', () {
    late PlaylistRepository repo;

    setUp(() async => repo = PlaylistRepository(await freshBox('pl')));

    SavedPlaylist saved(String id, {int scannedDay = 1}) => SavedPlaylist(
          info: PlaylistInfo(
              platformId: 'deezer', id: id, name: 'Mix $id', trackCount: 1),
          tracks: const [Track(title: 'T', artist: 'A')],
          settings: const DiscoverySettings(songCount: 30, albumCount: 10),
          importedAt: DateTime.utc(2026, 10, 1),
          lastScannedAt: DateTime.utc(2026, 10, scannedDay),
        );

    test('save/get round-trips; missing key returns null', () async {
      expect(repo.get('deezer', 'nope'), isNull);
      await repo.save(saved('7'));
      final back = repo.get('deezer', '7');
      expect(back, isNotNull);
      expect(back!.info.name, 'Mix 7');
      expect(back.tracks.single.title, 'T');
    });

    test('getAll sorts by lastScannedAt, newest first', () async {
      await repo.save(saved('old', scannedDay: 1));
      await repo.save(saved('new', scannedDay: 5));
      expect(repo.getAll().map((p) => p.info.id), ['new', 'old']);
    });

    test('updateSettings replaces settings but keeps tracks', () async {
      await repo.save(saved('7'));
      await repo.updateSettings(
          'deezer',
          '7',
          const DiscoverySettings(
              songCount: 99, albumCount: 10, genres: {'Metal'}));
      final back = repo.get('deezer', '7');
      expect(back!.settings.songCount, 99);
      expect(back.settings.genres, {'Metal'});
      expect(back.tracks.single.title, 'T');
    });

    test('remove deletes the entry', () async {
      await repo.save(saved('7'));
      await repo.remove('deezer', '7');
      expect(repo.get('deezer', '7'), isNull);
    });
  });
}
