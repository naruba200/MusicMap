// Bandsintown artist events (Phase 5, push 2 — LAST, code path only).
//
// Bandsintown's API is gated: using it requires accepting its terms
// AND Bandsintown's written consent plus an app ID issued for this
// app (see docs/phase5-notes.md for the user-side steps). This file
// therefore ships DORMANT: the code ships the placeholder
// `bandsintownAppId` (see lib/core/constants.dart) and makes NO
// network call at all until a real app ID is set locally — the
// events screen shows a setup hint instead (same pattern as the
// Jamendo tab). Nothing here fakes consent or claims access the app
// does not have, and no event data is ever invented.
//
// When configured, reads are: GET
// https://rest.bandsintown.com/artists/{artist}/events
//   ?app_id={appId}&date=upcoming
// Failure tolerance (plan §0): every failure returns [], never
// throws, and never aborts anything else. Plain Dio, no retry
// interceptor, short timeouts (set by the caller). Call caps: one
// call per artist, artists capped by the caller.

import 'package:dio/dio.dart';

/// True when [appId] is a real app ID rather than the placeholder
/// (or empty). Only then may the client touch the network.
bool isBandsintownConfigured(String appId) =>
    appId.trim().isNotEmpty && !appId.startsWith('YOUR_');

/// One upcoming Bandsintown event for an artist.
class BandsintownEvent {
  final String artist;
  final String? datetime; // ISO string as returned, e.g. 2026-11-05T20:00:00
  final String? venueName;
  final String? venueCity;
  final String? venueRegion;
  final String? venueCountry;
  final String? url; // Bandsintown event page
  final String? ticketUrl;
  final List<String> lineup;
  final String? description;

  const BandsintownEvent({
    required this.artist,
    this.datetime,
    this.venueName,
    this.venueCity,
    this.venueRegion,
    this.venueCountry,
    this.url,
    this.ticketUrl,
    this.lineup = const [],
    this.description,
  });

  /// "Venue, City, Country" with missing parts dropped.
  String get placeLine {
    final parts = <String>[];
    if (venueName != null && venueName!.isNotEmpty) {
      parts.add(venueName!);
    }
    if (venueCity != null && venueCity!.isNotEmpty) {
      parts.add(venueCity!);
    }
    if (venueRegion != null && venueRegion!.isNotEmpty) {
      parts.add(venueRegion!);
    }
    if (venueCountry != null && venueCountry!.isNotEmpty) {
      parts.add(venueCountry!);
    }
    return parts.join(', ');
  }

  /// "2026-11-05 20:00" from an ISO datetime, else the raw value.
  String get dateLine {
    final d = datetime;
    if (d == null || d.isEmpty) return 'Date to be announced';
    final noZone = d.split(RegExp(r'[+-]\d{2}:\d{2}$')).first;
    final trimmed = noZone.length >= 16 ? noZone.substring(0, 16) : noZone;
    return trimmed.replaceFirst('T', ' ');
  }

  factory BandsintownEvent.fromJson(String artist, Map json) {
    final venue = json['venue'] as Map?;
    final offers = json['offers'] as List?;
    String? ticketUrl;
    for (final offer in offers ?? []) {
      final url = (offer as Map?)?['url'];
      if (url is String && url.isNotEmpty) {
        ticketUrl = url;
        break;
      }
    }
    final lineup = <String>[];
    for (final name in (json['lineup'] as List? ?? [])) {
      if (name is String && name.isNotEmpty) lineup.add(name);
    }
    return BandsintownEvent(
      artist: artist,
      datetime: json['datetime'] as String?,
      venueName: venue?['name'] as String?,
      venueCity: venue?['city'] as String?,
      venueRegion: venue?['region'] as String?,
      venueCountry: venue?['country'] as String?,
      url: json['url'] as String?,
      ticketUrl: ticketUrl,
      lineup: lineup,
      description: json['description'] as String?,
    );
  }
}

/// Parses a Bandsintown events response: a list of event objects.
/// Anything else (an error object, a single object, garbage) yields
/// [] — an unusable response is an empty event list, not a crash.
List<BandsintownEvent> parseBandsintownEvents(String artist, dynamic json) {
  if (json is! List) return const [];
  return [
    for (final item in json)
      if (item is Map) BandsintownEvent.fromJson(artist, item),
  ];
}

class BandsintownClient {
  final Dio _dio;
  final String appId;

  BandsintownClient(this._dio, {required this.appId});

  static const String baseUrl = 'https://rest.bandsintown.com';

  /// Upcoming events for one artist, or [] when unconfigured, when
  /// the artist has none, or when anything goes wrong. Never throws.
  Future<List<BandsintownEvent>> upcomingEvents(String artist) async {
    if (!isBandsintownConfigured(appId)) return const [];
    try {
      final res = await _dio.get(
        '$baseUrl/artists/${Uri.encodeComponent(artist)}/events',
        queryParameters: {'app_id': appId, 'date': 'upcoming'},
      );
      return parseBandsintownEvents(artist, res.data);
    } catch (_) {
      return const [];
    }
  }
}
