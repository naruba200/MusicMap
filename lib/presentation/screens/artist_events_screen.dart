// Upcoming events for the user's favourited artists (Phase 5,
// push 2: Bandsintown code path, dormant until configured).
//
// Until a real Bandsintown app ID is set (which needs Bandsintown's
// written consent (see docs/phase5-notes.md), this screen shows a
// setup hint and makes no network calls at all. When configured it
// loads upcoming events per artist (artists capped, one call each,
// failures swallowed per artist), grouped by artist. Event rows open
// the Bandsintown event page (or ticket link) via the existing
// outbound helper; nothing here changes recommendations.

import 'package:dio/dio.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/appearance.dart';
import '../../core/constants.dart';
import '../../data/events/bandsintown_client.dart';
import '../../data/platforms/open_in_app.dart';
import '../widgets/editorial_widgets.dart';

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
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Upcoming events')),
      body: !isBandsintownConfigured(appId)
          ? _SetupHint(theme: theme)
          : artists.isEmpty
              ? const EditorialEmptyState(
                  message: 'Favorite some artists first, their '
                      'upcoming events will show up here.')
              : FutureBuilder<Map<String, List<BandsintownEvent>>>(
                  future: _load(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState ==
                        ConnectionState.waiting) {
                      return const EditorialLoadingState(
                          message: 'Loading upcoming events');
                    }
                    final grouped = snapshot.data ?? {};
                    if (grouped.isEmpty) {
                      return EditorialEmptyState(
                        message: artists.length == 1
                            ? 'No upcoming events for ${artists.first} '
                                'right now.'
                            : 'No upcoming events for your favourited '
                                'artists right now, or Bandsintown '
                                'could not be reached. Nothing else in '
                                'the app is affected.',
                      );
                    }
                    return ListView(
                      padding:
                          const EdgeInsets.only(top: 8, bottom: 16),
                      children: [
                        for (final entry in grouped.entries) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                                16, 16, 16, 8),
                            child: Text(entry.key,
                                style: theme.textTheme.titleMedium),
                          ),
                          Divider(
                              height: 1,
                              color: theme.colorScheme.outline),
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
  final ThemeData theme;

  const _SetupHint({required this.theme});

  @override
  Widget build(BuildContext context) {
    final scheme = theme.colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Events are not set up yet',
              style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Text(
            'Artist events come from Bandsintown, and using its API '
            'needs Bandsintown\'s written consent plus an app ID '
            'issued for this app. Until that exists, this screen '
            'stays dormant on purpose: it makes no calls and '
            'claims no access.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Divider(height: 1, color: scheme.outline),
          const SizedBox(height: 16),
          Text(
            'To turn it on, accept the Bandsintown API terms, '
            'contact Bandsintown with the intended use, and put the '
            'issued app ID in bandsintownAppId '
            '(lib/core/constants.dart) locally. Never commit a real one.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final BandsintownEvent event;

  const _EventRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final complex = Theme.of(context)
            .extension<MusicManDesignTokens>()
            ?.design ==
        AppDesign.complex;
    final link = event.url ?? event.ticketUrl;
    // The venue in detail lines in Complex: venue, city and region,
    // country, lineup, and the listing description each on its own
    // line. Compact keeps the single place line.
    final venueLines = <String>[];
    if (complex) {
      if (event.venueName != null && event.venueName!.isNotEmpty) {
        venueLines.add(event.venueName!);
      }
      final cityParts = [
        if (event.venueCity != null && event.venueCity!.isNotEmpty)
          event.venueCity!,
        if (event.venueRegion != null && event.venueRegion!.isNotEmpty)
          event.venueRegion!,
        if (event.venueCountry != null && event.venueCountry!.isNotEmpty)
          event.venueCountry!,
      ];
      if (cityParts.isNotEmpty) venueLines.add(cityParts.join(', '));
    } else if (event.placeLine.isNotEmpty) {
      venueLines.add(event.placeLine);
    }
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outline)),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(event.dateLine),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in venueLines) Text(line),
            if (event.lineup.isNotEmpty)
              Text('Lineup: ${event.lineup.join(', ')}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant)),
            if (complex &&
                event.description != null &&
                event.description!.isNotEmpty)
              Text(event.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant)),
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
      ),
    );
  }
}
