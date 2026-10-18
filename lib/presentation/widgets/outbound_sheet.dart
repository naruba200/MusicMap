// Per-track outbound links (no OAuth needed anywhere in v1):
// Spotify via search URL, Deezer via search URL.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/music_models.dart';

String spotifySearchUrl(Track track) =>
    'https://open.spotify.com/search/${Uri.encodeComponent('${track.artist} ${track.title}')}';

String deezerSearchUrl(Track track) =>
    'https://www.deezer.com/search/${Uri.encodeComponent('${track.artist} ${track.title}')}';

Future<void> _open(String url, BuildContext context) async {
  final uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open link.')),
      );
    }
  }
}

/// Bottom sheet: "Open in Spotify" / "Open in Deezer".
void showOutboundSheet(BuildContext context, Track track) {
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Open in Spotify'),
            subtitle: Text('${track.artist} – ${track.title}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(ctx);
              _open(spotifySearchUrl(track), context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.play_circle_outline),
            title: const Text('Open in Deezer'),
            subtitle: Text('${track.artist} – ${track.title}',
                maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(ctx);
              _open(deezerSearchUrl(track), context);
            },
          ),
        ],
      ),
    ),
  );
}
