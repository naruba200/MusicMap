// JSON round-trips + defaults for the core models (music_models.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:music_man/data/models/music_models.dart';

void main() {
  group('Track JSON', () {
    test('round-trips all fields', () {
      const t = Track(
        title: 'Song',
        artist: 'Artist',
        album: 'Alb',
        imageUrl: 'img.jpg',
        durationMs: 123000,
        platformTrackId: 'xyz',
      );
      final back = Track.fromJson(t.toJson());
      expect(back.title, 'Song');
      expect(back.artist, 'Artist');
      expect(back.album, 'Alb');
      expect(back.imageUrl, 'img.jpg');
      expect(back.durationMs, 123000);
      expect(back.platformTrackId, 'xyz');
    });

    test('null fields are omitted and default on read', () {
      const t = Track(title: 'Song', artist: 'Artist');
      final json = t.toJson();
      expect(json.containsKey('album'), isFalse);
      final back = Track.fromJson(json);
      expect(back.album, isNull);
      expect(back.durationMs, isNull);
    });

    test('missing title/artist fall back to placeholders', () {
      final back = Track.fromJson(const {});
      expect(back.title, 'Unknown title');
      expect(back.artist, 'Unknown artist');
    });
  });

  group('PlaylistInfo JSON', () {
    test('round-trips', () {
      const info = PlaylistInfo(
        platformId: 'deezer',
        id: '42',
        name: 'Mix',
        description: 'desc',
        coverUrl: 'cover.jpg',
        owner: 'me',
        trackCount: 17,
      );
      final back = PlaylistInfo.fromJson(info.toJson());
      expect(back.platformId, 'deezer');
      expect(back.id, '42');
      expect(back.name, 'Mix');
      expect(back.trackCount, 17);
      expect(back.owner, 'me');
    });
  });

  group('DiscoverySettings JSON', () {
    test('round-trips moods/genres/fresh', () {
      const s = DiscoverySettings(
        songCount: 50,
        albumCount: 20,
        moods: {'Chill'},
        genres: {'Rock', 'Metal'},
        freshFinds: true,
      );
      final back = DiscoverySettings.fromJson(s.toJson());
      expect(back.songCount, 50);
      expect(back.albumCount, 20);
      expect(back.moods, {'Chill'});
      expect(back.genres, {'Rock', 'Metal'});
      expect(back.freshFinds, isTrue);
    });

    test('empty JSON yields the spec defaults', () {
      final back = DiscoverySettings.fromJson(const {});
      expect(back.songCount, 30);
      expect(back.albumCount, 10);
      expect(back.moods, isEmpty);
      expect(back.genres, isEmpty);
      expect(back.freshFinds, isFalse);
    });

    test('copyWith overrides only the given fields', () {
      const s = DiscoverySettings(songCount: 30, albumCount: 10);
      final c = s.copyWith(songCount: 75, freshFinds: true);
      expect(c.songCount, 75);
      expect(c.albumCount, 10);
      expect(c.freshFinds, isTrue);
    });
  });

  group('SavedPlaylist JSON', () {
    test('round-trips info, tracks, settings and timestamps', () {
      final saved = SavedPlaylist(
        info: const PlaylistInfo(
            platformId: 'deezer', id: '7', name: 'Mix', trackCount: 1),
        tracks: const [Track(title: 'T', artist: 'A')],
        settings: const DiscoverySettings(songCount: 30, albumCount: 10),
        importedAt: DateTime.utc(2026, 10, 1, 12),
        lastScannedAt: DateTime.utc(2026, 10, 2, 12),
      );
      final back = SavedPlaylist.fromJson(saved.toJson());
      expect(back.info.id, '7');
      expect(back.tracks.single.title, 'T');
      expect(back.settings.songCount, 30);
      expect(back.importedAt, DateTime.utc(2026, 10, 1, 12));
      expect(back.lastScannedAt, DateTime.utc(2026, 10, 2, 12));
    });
  });
}
