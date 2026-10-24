// Hive-backed video-ID cache for YouTube export (FR-29). Kept separate
// from youtube_export.dart so the resolver and its tests stay free of
// Hive: hits store {videoId}, misses store {missedAt} and are retried
// only after 7 days.

import 'package:hive_flutter/hive_flutter.dart';

import 'youtube_export.dart';

class HiveVideoIdCache implements VideoIdCache {
  static const boxName = 'youtube_video_ids';

  final Box _box;

  HiveVideoIdCache(this._box);

  static Future<HiveVideoIdCache> open() async {
    final box = await Hive.openBox(boxName);
    return HiveVideoIdCache(box);
  }

  @override
  String? lookup(String key) {
    final value = _box.get(key);
    if (value is Map) {
      final id = value['videoId'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  @override
  void storeHit(String key, String videoId) =>
      _box.put(key, {'videoId': videoId});

  @override
  void storeMiss(String key, DateTime now) =>
      _box.put(key, {'missedAt': now.toIso8601String()});

  @override
  bool shouldRetryMiss(String key, DateTime now) {
    final value = _box.get(key);
    if (value is! Map) return true;
    if (value['videoId'] is String) return false;
    final raw = value['missedAt'];
    final missed = raw is String ? DateTime.tryParse(raw) : null;
    return shouldRetryMissAfter(missed, now);
  }
}
