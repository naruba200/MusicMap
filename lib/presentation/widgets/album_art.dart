// Shared album cover resolution (Group 4, part 2). Hoisted from the
// Results album card, which used to own this privately, so Album
// detail resolves its cover with the same chain.
//
// Chain, in order:
//   album.artUrl -> enrichment artUrl -> enrichment artistThumbUrl
//   -> lazily fetched Last.fm track.getInfo art for the first song
//   (session cache, shared with the Results card).
// The lazy fetch only runs when no enrichment art exists, so a
// cached Last.fm URL can never outrank enrichment art. A missing
// cover stays a plain album icon, never a broken image.
//
// Cover fallback for song rows and players (Group 4, part 3):
//   track.imageUrl -> fallbackImageUrl (album art, or the artist
//   thumb when that is all the caller has) -> placeholder tile.
// [coverUrlFor] is the pure step; callers pass the album context in
// and the widgets below apply it.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/constants.dart';
import '../../data/engine/recommendation_engine.dart';
import '../../data/enrichment/album_enrichment.dart';
import '../../data/lastfm/lastfm_client.dart';
import '../providers/providers.dart';

/// Session cache for lazily fetched album art (FR-11): key -> image
/// URL (null = looked up, none found). Shared by the Results card
/// and Album detail, so one lookup serves both.
final albumArtCacheProvider =
    StateProvider<Map<String, String?>>((ref) => {});

String albumArtCacheKey(String artist, String album) =>
    albumEnrichmentKey(artist, album);

/// Album art or artist thumb for [album], in chain order, without
/// the lazy step: what a song row passes as its cover fallback.
String? albumArtFallbackUrl(AlbumRec album, AlbumEnrichment? enrichment) {
  if (album.artUrl != null && album.artUrl!.isNotEmpty) {
    return album.artUrl;
  }
  final art = enrichment?.artUrl;
  if (art != null && art.isNotEmpty) return art;
  final thumb = enrichment?.artistThumbUrl;
  if (thumb != null && thumb.isNotEmpty) return thumb;
  return null;
}

/// Full cover resolution in chain order. [cachedArtUrl] is the lazy
/// Last.fm result, used only when neither the album nor the
/// enrichment has art.
String? resolveAlbumArtUrl({
  required AlbumRec album,
  AlbumEnrichment? enrichment,
  String? cachedArtUrl,
}) =>
    albumArtFallbackUrl(album, enrichment) ??
    (cachedArtUrl != null && cachedArtUrl.isNotEmpty
        ? cachedArtUrl
        : null);

/// Song cover resolution: the track's own cover wins, then the
/// caller-supplied fallback (album art or artist thumb), then null
/// for the placeholder tile.
String? coverUrlFor({String? imageUrl, String? fallbackImageUrl}) {
  if (imageUrl != null && imageUrl.isNotEmpty) return imageUrl;
  if (fallbackImageUrl != null && fallbackImageUrl.isNotEmpty) {
    return fallbackImageUrl;
  }
  return null;
}

/// Album art with lazy Last.fm fill (FR-11): shows cached art, else
/// fetches track.getInfo for the top recommended song once and
/// caches the result. TheAudioDB art is the last fallback before
/// the lazy fetch, after Last.fm: generation-time Last.fm art wins,
/// and when enrichment art exists the lazy fetch is skipped so the
/// cover shows immediately.
class AlbumArtImage extends ConsumerStatefulWidget {
  final AlbumRec album;
  final double? width;
  final double? height;

  /// TheAudioDB annotation for this album, if enrichment found one.
  final AlbumEnrichment? enrichment;

  /// Placeholder icon size when no art exists at all.
  final double placeholderIconSize;

  const AlbumArtImage({
    super.key,
    required this.album,
    this.width,
    this.height,
    this.enrichment,
    this.placeholderIconSize = 40,
  });

  /// Square cover of [size], the Results card shape.
  const AlbumArtImage.square({
    super.key,
    required this.album,
    required double size,
    this.enrichment,
    this.placeholderIconSize = 40,
  })  : width = size,
        height = size;

  @override
  ConsumerState<AlbumArtImage> createState() => _AlbumArtImageState();
}

class _AlbumArtImageState extends ConsumerState<AlbumArtImage> {
  bool _fetching = false;

  @override
  void initState() {
    super.initState();
    final enrichArt = widget.enrichment?.artUrl;
    final enrichThumb = widget.enrichment?.artistThumbUrl;
    final hasEnrichArt =
        (enrichArt != null && enrichArt.isNotEmpty) ||
            (enrichThumb != null && enrichThumb.isNotEmpty);
    if ((widget.album.artUrl == null || widget.album.artUrl!.isEmpty) &&
        !hasEnrichArt) {
      _fetching = true;
      Future.microtask(_fetchArt);
    }
  }

  Future<void> _fetchArt() async {
    final key = albumArtCacheKey(widget.album.artist, widget.album.name);
    final cache = ref.read(albumArtCacheProvider);
    if (cache.containsKey(key)) {
      if (mounted) setState(() => _fetching = false);
      return;
    }
    String? url;
    try {
      if (widget.album.songs.isNotEmpty) {
        final top = widget.album.songs.first.track;
        final client =
            LastFmClient(dio: ref.read(dioProvider), apiKey: lastFmApiKey);
        final info = await client.getTrackInfo(top.artist, top.title);
        url = info.imageUrl;
      }
    } catch (_) {
      url = null; // art stays a placeholder; never breaks the card
    }
    ref.read(albumArtCacheProvider.notifier).state = {...cache, key: url};
    if (mounted) setState(() => _fetching = false);
  }

  @override
  Widget build(BuildContext context) {
    final key = albumArtCacheKey(widget.album.artist, widget.album.name);
    final cached = ref.watch(albumArtCacheProvider)[key];
    final url = resolveAlbumArtUrl(
      album: widget.album,
      enrichment: widget.enrichment,
      cachedArtUrl: cached,
    );
    final width = widget.width;
    final height = widget.height;
    return ClipRRect(
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        width: width,
        height: height,
        child: url != null && url.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: url,
                width: width,
                height: height,
                fit: BoxFit.cover,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator()),
                errorWidget: (_, __, ___) =>
                    Icon(Icons.album_outlined,
                        size: widget.placeholderIconSize),
              )
            : _fetching
                ? const Center(
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2)))
                : Icon(Icons.album_outlined,
                    size: widget.placeholderIconSize),
      ),
    );
  }
}
