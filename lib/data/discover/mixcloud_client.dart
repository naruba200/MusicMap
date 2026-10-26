// Mixcloud discovery client (Phase 4, push 4).
//
// Mixcloud is DJ mixes, radio shows and podcasts. Reads need no auth
// (https://api.mixcloud.com, JSON over HTTPS). This client is a
// shows/mixes browser ONLY: it deliberately does NOT feed the song
// generator at all — a two-hour DJ mix is not a seed track, and the
// plan (§4) forbids it. Shows open in the Mixcloud app/browser via the
// existing outbound helper; there is no in-app Mixcloud playback
// (Mixcloud serves streams through its widget/embed, not a public
// stream URL), and this file never guesses one.
//
// Failure tolerance (plan §0): errors propagate to the provider layer,
// which converts them into an empty load with an error label. Plain Dio,
// no retry interceptor, short timeouts (set on the provider's Dio).
// Call caps: every list is one page, capped by `limit`.

import 'package:dio/dio.dart';

/// One Mixcloud show (a "cloudcast"): a mix, radio show or podcast.
class MixcloudShow {
  final String key;
  final String name;
  final String url;
  final String? userName;
  final String? imageUrl;
  final int? audioLengthSec;
  final List<String> tags;

  const MixcloudShow({
    required this.key,
    required this.name,
    required this.url,
    this.userName,
    this.imageUrl,
    this.audioLengthSec,
    this.tags = const [],
  });

  factory MixcloudShow.fromJson(Map json) {
    final user = json['user'] as Map?;
    final pictures = json['pictures'] as Map?;
    final tags = <String>[];
    for (final tag in (json['tags'] as List? ?? [])) {
      final name = (tag as Map?)?['name'];
      if (name is String && name.isNotEmpty) tags.add(name);
    }
    return MixcloudShow(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? 'Untitled show',
      url: json['url'] as String? ?? '',
      userName: user?['name'] as String? ?? user?['username'] as String?,
      imageUrl: pictures?['medium'] as String? ??
          pictures?['large'] as String? ??
          pictures?['thumbnail'] as String?,
      audioLengthSec: (json['audio_length'] as num?)?.toInt(),
      tags: tags,
    );
  }
}

/// One Mixcloud tag, for the tag browser.
class MixcloudTag {
  final String name;
  final String key;
  final String url;

  const MixcloudTag(
      {required this.name, required this.key, required this.url});

  factory MixcloudTag.fromJson(Map json) => MixcloudTag(
        name: json['name'] as String? ?? '',
        key: json['key'] as String? ?? '',
        url: json['url'] as String? ?? '',
      );
}

class MixcloudClient {
  final Dio _dio;

  MixcloudClient(this._dio);

  static const String baseUrl = 'https://api.mixcloud.com';
  static const int pageLimit = 20;

  /// Site-wide popular shows, or the hot list when [hot] is true.
  Future<List<MixcloudShow>> popular({bool hot = false}) async {
    final res = await _dio.get(
      '$baseUrl/popular/${hot ? 'hot/' : ''}',
      queryParameters: {'limit': pageLimit},
    );
    return parseShows(res.data);
  }

  /// Newly published shows.
  Future<List<MixcloudShow>> latest() async {
    final res = await _dio.get(
      '$baseUrl/new/',
      queryParameters: {'limit': pageLimit},
    );
    return parseShows(res.data);
  }

  /// Show search by free text.
  Future<List<MixcloudShow>> searchShows(String query,
      {int limit = pageLimit}) async {
    final res = await _dio.get(
      '$baseUrl/search/',
      queryParameters: {'q': query, 'type': 'cloudcast', 'limit': limit},
    );
    return parseShows(res.data);
  }

  /// Tag search by free text.
  Future<List<MixcloudTag>> searchTags(String query,
      {int limit = pageLimit}) async {
    final res = await _dio.get(
      '$baseUrl/search/',
      queryParameters: {'q': query, 'type': 'tag', 'limit': limit},
    );
    final items = _dataList(res.data);
    return [
      for (final item in items)
        if (item is Map) MixcloudTag.fromJson(item),
    ];
  }

  /// Shows for a tag, by its key (e.g. '/genres/funk/'). The tag's
  /// `cloudcasts` connection is the tag's show list.
  Future<List<MixcloudShow>> tagShows(String tagKey,
      {int limit = pageLimit}) async {
    final key = tagKey.endsWith('/') ? tagKey : '$tagKey/';
    final res = await _dio.get(
      '$baseUrl${key}cloudcasts/',
      queryParameters: {'limit': limit},
    );
    return parseShows(res.data);
  }

  /// Parses a Mixcloud list response (a map with a `data` list).
  static List<MixcloudShow> parseShows(dynamic json) {
    final items = _dataList(json);
    return [
      for (final item in items)
        if (item is Map) MixcloudShow.fromJson(item),
    ];
  }

  static List _dataList(dynamic json) {
    if (json is Map) {
      final data = json['data'];
      if (data is List) return data;
    }
    return const [];
  }

  /// 'mm:ss' (or 'h:mm:ss' past an hour) for a show length in seconds.
  static String formatLength(int seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
