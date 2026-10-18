# Music Map

Playlist-based song & album recommendations with a personalized music-news
feed. Android-first Flutter app.

**Spec:** the single source of truth is the product specification
(spec-driven development). Ask the maintainer for the latest copy before
changing behavior.

## Setup

```bash
flutter pub get
flutter run
```

## Keys & setup notes

- **Spotify**: register a free app at the Spotify Developer Dashboard for the
  OAuth client ID (spec §10).
- **SoundCloud**: register a free app for a `client_id` (spec §10). The app
  shows a clear error if it is unset.
- **Last.fm**: free API key (spec §10). Free-tier, revocable — never commit a
  paid key.
- **Deezer**: no key needed for public playlists.

## CI

GitHub Actions runs `flutter analyze` + `flutter test` on every push to `main`.
