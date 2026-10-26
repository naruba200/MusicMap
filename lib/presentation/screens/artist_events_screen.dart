// Upcoming events for the user's favourited artists (Phase 5,
// push 2 — Bandsintown code path, dormant until configured).
//
// Until a real Bandsintown app ID is set (which needs Bandsintown's
// written consent — see docs/phase5-notes.md), this screen shows a
// setup hint and makes no network calls at all. When configured it
// loads upcoming events per artist (artists capped, one call each,
// failures swallowed per artist), grouped by artist. Event rows open
// the Bandsintown event page (or ticket link) via the existing
// outbound helper; nothing here changes recommendations.

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../core/constants.dart';
import '../../data/events/bandsintown_client.dart';
import '../../data/platforms/open_in_app.dart';

class ArtistEventsScreen extends StatelessWidget {
  final List<String> artists;
  final String appId;
  final BandsintownClient? client;

  const ArtistEventsScreen({
    super.key,
    required this.artists,
    this.appId = bandsintownAppId,
    this.client,
  });

  static const int maxArtists = 10;

  Future<Map<String, List<BandsintownEvent>>> _load() async {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final api = client ?? BandsintownClient(dio, appId: appId);
    final result = <String, List<BandsintownEvent>>{};
    for (final artist in artists.take(maxArtists)) {
      final events = await api.upcomingEvents(artist);
      if (events.isNotEmpty) result[artist] = events;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Upcoming events')),
      body: !isBandsintownConfigured(appId)
          ? const _SetupHint()
          : artists.isEmpty
              ? const _EmptyState(
                  message: 'Favorite some artists first — their '
                      'upcoming events will show up here.')
              : FutureBuilder<Map<String, List<BandsintownEvent>>>(
                  future: _load(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState ==
                        ConnectionState.waiting) {
                      return const Center(
                          child: CircularProgressIndicator());
                    }
                    final grouped = snapshot.data ?? {};
                    if (grouped.isEmpty) {
                      return const _EmptyState(
                          message: 'No upcoming events found for '
                              'your favourited artists right now — '
                              'or Bandsintown could not be reached. '
                              'Nothing else in the app is affected.');
                    }
                    return ListView(
                      children: [
                        for (final entry in grouped.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 16, 16, 4),
                            child: Text(entry.key,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium),
                          ),
                          for (final event in entry.value)
                            _EventRow(event: event),
                        ],
                      ],
                    );
                  },
                ),
    );
  }
}

class _SetupHint extends StatelessWidget {
  const _SetupHint();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.event_outlined, size: 56),
            SizedBox(height: 16),
            Text('Events are not set up yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            SizedBox(height: 8),
            Text(
              'Artist events come from Bandsintown, and using its API '
              'needs Bandsintown\'s written consent plus an app ID '
              'issued for this app. Until that exists, this screen '
              'stays dormant on purpose — it makes no calls and '
              'claims no access.\n\n'
              'User steps (see docs/phase5-notes.md): accept the '
              'Bandsintown API terms, contact Bandsintown with the '
              'intended use, and put the issued app ID in '
              'bandsintownAppId (lib/core/constants.dart) locally — '
              'never commit a real one.',
              style: TextStyle(height: 1.5),
            ),
          ],
        ),
      );
}

class _EmptyState extends StatelessWidget {
  final String message;

  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(message, textAlign: TextAlign.center),
        ),
      );
}

class _EventRow extends StatelessWidget {
  final BandsintownEvent event;

  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = event.url ?? event.ticketUrl;
    return ListTile(
      title: Text(event.dateLine),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (event.placeLine.isNotEmpty) Text(event.placeLine),
          if (event.lineup.isNotEmpty)
            Text('Lineup: ${event.lineup.join(', ')}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
      trailing: link == null
          ? null
          : IconButton(
              icon: const Icon(Icons.open_in_new),
              tooltip: 'Open event',
              onPressed: () async {
                await openLinkInAppFirst(Uri.parse(link));
              },
            ),
    );
  }
}
