import 'package:flutter_test/flutter_test.dart';
import 'package:music_map/data/lastfm/lastfm_client.dart';

void main() {
  group('SimilarTrack.fromJson', () {
    test('parses artist object, title and match', () {
      final t = SimilarTrack.fromJson({
        'name': 'Get Lucky',
        'match': '0.85',
        'artist': {'name': 'Daft Punk'},
      });
      expect(t.title, 'Get Lucky');
      expect(t.artist, 'Daft Punk');
      expect(t.match, closeTo(0.85, 0.001));
    });

    test('handles string artist and missing match', () {
      final t = SimilarTrack.fromJson({'name': 'X', 'artist': 'Y'});
      expect(t.artist, 'Y');
      expect(t.match, 0);
    });
  });

  group('TagTrack.fromJson', () {
    test('parses listeners as int', () {
      final t = TagTrack.fromJson({
        'name': 'Blinding Lights',
        'listeners': '1234567',
        'artist': {'name': 'The Weeknd'},
      });
      expect(t.listeners, 1234567);
    });
  });

  group('TrackAlbumInfo.fromJson', () {
    test('picks the largest image', () {
      final info = TrackAlbumInfo.fromJson({
        'track': {
          'album': {
            'title': 'Discovery',
            'artist': 'Daft Punk',
            'image': [
              {'#text': 'small.jpg', 'size': 'small'},
              {'#text': '', 'size': 'medium'},
              {'#text': 'big.jpg', 'size': 'extralarge'},
            ],
          },
        },
      });
      expect(info.album, 'Discovery');
      expect(info.imageUrl, 'big.jpg');
    });

    test('missing album yields nulls', () {
      final info = TrackAlbumInfo.fromJson({'track': {}});
      expect(info.album, isNull);
      expect(info.imageUrl, isNull);
    });
  });

  group('LastFmException', () {
    test('toString returns the message', () {
      expect(const LastFmException('boom').toString(), 'boom');
    });
  });
}
