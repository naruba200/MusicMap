// LRCLIB lyrics lookup (Phase 5, push 1).
//
// LRCLIB (https://lrclib.net) is a free, no-key lyrics database. Read
// endpoints need no authentication, but a meaningful User-Agent is
// required. Lookup is by track metadata: artist, title, album and
// duration in seconds (GET /api/get). A track the database does not
// know returns 404, which this client maps to null — never an error.
//
// Failure tolerance (plan §0): this lookup NEVER throws. Any network
// error, timeout, rate limit or malformed payload yields null, so a
// dead lyrics service degrades the lyrics view to its honest empty
// state instead of breaking the track view. Plain Dio, no retry
// interceptor, short timeouts (set by the caller). Call caps: the
// lyrics view fetches on demand for one track at a time, and results
// are Hive-cached for 30 days (see lyrics_cache.dart).

import 'package:dio/dio.dart';

/// One LRCLIB lyric result. Either [plainLyrics] or [syncedLyrics]
/// (or both) is present for a real match; [instrumental] marks a
/// track LRCLIB knows has no vocals at all.
class LrclibLyrics {
  final int? id;
  final String? trackName;
  final String? artistName;
  final String? albumName;
  final double? durationSec;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  const LrclibLyrics({
    this.id,
    this.trackName,
    this.artistName,
    this.albumName,
    this.durationSec,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  /// True when there is actually something to show (lyrics text, or
  /// the honest instrumental fact). A result with neither is treated
  /// as "no lyrics" by callers.
  bool get hasContent =>
      instrumental ||
      (plainLyrics != null && plainLyrics!.trim().isNotEmpty) ||
      (syncedLyrics != null && syncedLyrics!.trim().isNotEmpty);

  /// Synced lines parsed from [syncedLyrics], or empty when there are
  /// none. Plain lyrics are preferred for display (see LyricsScreen);
  /// these exist so a synced-only match still shows its text.
  List<SyncedLyricLine> get syncedLines =>
      parseSyncedLyrics(syncedLyrics);

  /// Display text: plain lyrics first, else the synced lines' text
  /// without timestamps, else null (caller shows the empty state).
  String? get displayText {
    final plain = plainLyrics?.trim();
    if (plain != null && plain.isNotEmpty) return plain;
    final lines = syncedLines;
    if (lines.isEmpty) return null;
    return lines.map((l) => l.text).join('\n');
  }

  factory LrclibLyrics.fromJson(Map json) => LrclibLyrics(
        id: (json['id'] as num?)?.toInt(),
        trackName: json['trackName'] as String? ?? json['name'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        durationSec: (json['duration'] as num?)?.toDouble(),
        instrumental: json['instrumental'] as bool? ?? false,
        plainLyrics: json['plainLyrics'] as String?,
        syncedLyrics: json['syncedLyrics'] as String?,
      );

  Map<String, dynamic> toJson() => {
        if (id != null) 'id': id,
        if (trackName != null) 'trackName': trackName,
        if (artistName != null) 'artistName': artistName,
        if (albumName != null) 'albumName': albumName,
        if (durationSec != null) 'duration': durationSec,
        'instrumental': instrumental,
        if (plainLyrics != null) 'plainLyrics': plainLyrics,
        if (syncedLyrics != null) 'syncedLyrics': syncedLyrics,
      };
}

/// One LRC timestamped line: [timeSec] from the start of the track.
class SyncedLyricLine {
  final double timeSec;
  final String text;

  const SyncedLyricLine({required this.timeSec, required this.text});
}

/// Parses LRC text (`[mm:ss.xx] lyric` per line) into timestamped
/// lines. Metadata tags (`[ti:...]`, `[ar:...]`, `[length:...]`) and
/// malformed lines are skipped, never fatal. A line carrying several
/// timestamps keeps the first and strips the rest from its text.
List<SyncedLyricLine> parseSyncedLyrics(String? lrc) {
  if (lrc == null || lrc.trim().isEmpty) return const [];
  final lines = <SyncedLyricLine>[];
  final stamp = RegExp(r'^\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]\s*');
  final extraStamp =
      RegExp(r'^\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]\s*');
  for (final raw in lrc.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final match = stamp.firstMatch(line);
    if (match == null) continue;
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    final frac = match.group(3);
    var millis = 0;
    if (frac != null) {
      // .5 = 500ms, .34 = 340ms, .123 = 123ms.
      millis = int.parse(frac.padRight(3, '0'));
    }
    var text = line.substring(match.end);
    while (extraStamp.hasMatch(text)) {
      text = text.replaceFirst(extraStamp, '');
    }
    lines.add(SyncedLyricLine(
      timeSec: minutes * 60 + seconds + millis / 1000,
      text: text,
    ));
  }
  return lines;
}

class LrclibClient {
  final Dio _dio;

  LrclibClient(this._dio);

  static const String baseUrl = 'https://lrclib.net';

  /// Required by LRCLIB: every request carries a User-Agent naming
  /// the app. Without it the service may reject the request.
  static const String userAgent =
      'MusicMan/1.0.0 (https://github.com/naruba200/MusicMap)';

  /// Lyrics for one track, or null when LRCLIB has none (404), the
  /// track is unknown, or anything at all goes wrong. Never throws.
  Future<LrclibLyrics?> fetchLyrics({
    required String artist,
    required String title,
    String? album,
    int? durationSec,
  }) async {
    try {
      final params = <String, dynamic>{
        'artist_name': artist,
        'track_name': title,
      };
      if (album != null && album.trim().isNotEmpty) {
        params['album_name'] = album;
      }
      if (durationSec != null && durationSec > 0) {
        params['duration'] = durationSec;
      }
      final res = await _dio.get(
        '$baseUrl/api/get',
        queryParameters: params,
        options: Options(headers: {'User-Agent': userAgent}),
      );
      if (res.data is! Map) return null;
      final lyrics =
          LrclibLyrics.fromJson((res.data as Map).cast<String, dynamic>());
      return lyrics.hasContent ? lyrics : null;
    } catch (_) {
      return null;
    }
  }
}
