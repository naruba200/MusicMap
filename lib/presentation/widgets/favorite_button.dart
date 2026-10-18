// Heart toggle persisted to the favorites repo (FR-12).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/music_models.dart';
import '../providers/providers.dart';

class FavoriteButton extends ConsumerStatefulWidget {
  final Track track;

  const FavoriteButton({super.key, required this.track});

  @override
  ConsumerState<FavoriteButton> createState() => _FavoriteButtonState();
}

class _FavoriteButtonState extends ConsumerState<FavoriteButton> {
  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(favoritesRepositoryProvider);
    final isFav = repo.isFavorite(widget.track.artist, widget.track.title);
    return IconButton(
      icon: Icon(isFav ? Icons.favorite : Icons.favorite_outline,
          color: isFav ? Colors.pinkAccent : null),
      tooltip: isFav ? 'Remove from favorites' : 'Add to favorites',
      onPressed: () {
        final nowFav = repo.toggle(widget.track);
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(nowFav ? 'Added to favorites' : 'Removed from favorites'),
          duration: const Duration(seconds: 1),
        ));
      },
    );
  }
}
