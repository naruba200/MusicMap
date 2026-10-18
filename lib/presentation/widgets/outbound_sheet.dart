// Per-track and per-album outbound links (no OAuth needed anywhere in v1):
// each platform is reached via its search URL.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/models/music_models.dart';

String _q(String s) => Uri.encodeComponent(s);

String spotifySearchUrl(String query) =>
    'https://open.spotify.com/search/${_q(query)}';
String deezerSearchUrl(String query) =>
    'https://www.deezer.com/search/${_q(query)}';
String youTubeSearchUrl(String query) =>
    'https://www.youtube.com/results?search_query=${_q(query)}';
String youTubeMusicSearchUrl(String query) =>
    'https://music.youtube.com/search?q=${_q(query)}';

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

/// Bottom sheet: "Open in Spotify / Deezer / YouTube / YouTube Music".
void showOutboundSheet(BuildContext context, Track track) {
  final query = '${track.artist} ${track.title}';
  _showSheet(context, query);
}

/// Bottom sheet for an album: searches "artist album" on each platform.
void showAlbumOutboundSheet(
    BuildContext context, String artist, String album) {
  _showSheet(context, '$artist $album');
}

void _showSheet(BuildContext context, String query) {
  final options = [
    ('Spotify', spotifySearchUrl(query)),
    ('Deezer', deezerSearchUrl(query)),
    ('YouTube', youTubeSearchUrl(query)),
    ('YouTube Music', youTubeMusicSearchUrl(query)),
  ];
  showModalBottomSheet(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, url) in options)
            ListTile(
              leading: const Icon(Icons.play_circle_outline),
              title: Text('Open in $label'),
              subtitle: Text(query,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(ctx);
                _open(url, context);
              },
            ),
        ],
      ),
    ),
  );
}
