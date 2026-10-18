// App settings persisted in Hive (platform choice, count defaults).

import 'package:hive_flutter/hive_flutter.dart';

import '../../core/constants.dart';

class SettingsRepository {
  static const String boxName = 'settings';
  final Box _box;

  SettingsRepository(this._box);

  static Future<SettingsRepository> open() async {
    final box = await Hive.openBox(boxName);
    return SettingsRepository(box);
  }

  String get selectedPlatformId =>
      _box.get('platform', defaultValue: PlatformIds.spotify) as String;
  Future<void> setSelectedPlatformId(String id) =>
      _box.put('platform', id);

  int get defaultSongCount =>
      _box.get('songCount', defaultValue: defaultSongCount) as int;
  Future<void> setDefaultSongCount(int n) => _box.put('songCount', n);

  int get defaultAlbumCount =>
      _box.get('albumCount', defaultValue: defaultAlbumCount) as int;
  Future<void> setDefaultAlbumCount(int n) => _box.put('albumCount', n);
}
