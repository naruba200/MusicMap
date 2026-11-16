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
      _box.get('platform', defaultValue: PlatformIds.deezer) as String;
  Future<void> setSelectedPlatformId(String id) =>
      _box.put('platform', id);

  int get songCount =>
      _box.get('songCount', defaultValue: defaultSongCount) as int;
  Future<void> setDefaultSongCount(int n) => _box.put('songCount', n);

  int get albumCount =>
      _box.get('albumCount', defaultValue: defaultAlbumCount) as int;
  Future<void> setDefaultAlbumCount(int n) => _box.put('albumCount', n);

  /// Optional ListenBrainz username (Phase 3). Null when unset or
  /// blank — the ListenBrainz layer is completely inactive then.
  /// No key, no OAuth: only public recommendation data is read.
  String? get listenBrainzUsername {
    final value = _box.get('listenBrainzUsername');
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Appearance (Phase A redesign): the named theme and the design
  /// variant, stored as their enum names. Validation lives with the
  /// enums (unknown stored values fall back to the defaults), so the
  /// raw strings are returned as-is here.
  String get themeName =>
      _box.get('theme', defaultValue: 'editorial') as String;
  Future<void> setThemeName(String name) => _box.put('theme', name);

  String get design =>
      _box.get('design', defaultValue: 'compact') as String;
  Future<void> setDesign(String name) => _box.put('design', name);

  /// Save a username, or clear it (null / blank deletes the key).
  Future<void> setListenBrainzUsername(String? username) {
    final trimmed = username?.trim() ?? '';
    if (trimmed.isEmpty) return _box.delete('listenBrainzUsername');
    return _box.put('listenBrainzUsername', trimmed);
  }
}
