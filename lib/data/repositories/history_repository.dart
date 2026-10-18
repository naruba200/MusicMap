// Past recommendation runs, persisted in Hive (FR-13). Tapping a run
// re-opens its cached results — no re-fetch.
//
// The result is stored as raw JSON (see GenerationResult.toJson) to avoid
// an import cycle with the generation provider.

import 'package:hive_flutter/hive_flutter.dart';

/// One completed generation run.
class HistoryRun {
  final String id;
  final DateTime timestamp;
  final String seedName;
  final String? seedPlaylistId;
  final String? seedPlatformId;
  final bool isSurprise;
  final Map<String, dynamic> resultJson;

  const HistoryRun({
    required this.id,
    required this.timestamp,
    required this.seedName,
    this.seedPlaylistId,
    this.seedPlatformId,
    required this.isSurprise,
    required this.resultJson,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'seedName': seedName,
        if (seedPlaylistId != null) 'seedPlaylistId': seedPlaylistId,
        if (seedPlatformId != null) 'seedPlatformId': seedPlatformId,
        'isSurprise': isSurprise,
        'result': resultJson,
      };

  factory HistoryRun.fromJson(Map<String, dynamic> json) => HistoryRun(
        id: json['id'] as String? ?? '',
        timestamp:
            DateTime.tryParse(json['timestamp'] as String? ?? '') ??
                DateTime.fromMillisecondsSinceEpoch(0),
        seedName: json['seedName'] as String? ?? 'Recommendations',
        seedPlaylistId: json['seedPlaylistId'] as String?,
        seedPlatformId: json['seedPlatformId'] as String?,
        isSurprise: json['isSurprise'] as bool? ?? false,
        resultJson: (json['result'] as Map).cast<String, dynamic>(),
      );
}

class HistoryRepository {
  static const boxName = 'history';

  final Box _box;

  HistoryRepository(this._box);

  static Future<HistoryRepository> open() async {
    final box = await Hive.openBox(boxName);
    return HistoryRepository(box);
  }

  Future<void> add(HistoryRun run) => _box.put(run.id, run.toJson());

  /// Newest first.
  List<HistoryRun> getAll() {
    final runs = <HistoryRun>[];
    for (final value in _box.values) {
      if (value is Map) {
        try {
          runs.add(
              HistoryRun.fromJson(value.cast<String, dynamic>()));
        } catch (_) {
          // ignore malformed entries
        }
      }
    }
    runs.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return runs;
  }

  Future<void> remove(String id) => _box.delete(id);

  Future<void> clear() => _box.clear();

  /// Full export payload for FR-14b.
  List<Map<String, dynamic>> exportJson() => [
        for (final value in _box.values)
          if (value is Map) value.cast<String, dynamic>(),
      ];
}
