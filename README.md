# Music Map

Playlist-based song & album recommendations with a personalized music-news
feed. Android-first Flutter app.

**Spec:** the single source of truth is the product specification
(spec-driven development). Ask the maintainer for the latest copy before
changing behavior.

## Setup

```bash
# Android only — do NOT add windows/web/ios platform folders.
flutter create --platforms=android .
flutter pub get
flutter run
```

Then add the two intent-filters from `docs/android-share-intent.md` to
`android/app/src/main/AndroidManifest.xml` (OAuth redirect + share-intent).

## Keys & setup notes

- **Spotify**: register a free app at the Spotify Developer Dashboard for the
  OAuth client ID (spec §10).
- **SoundCloud**: parked for v1 — SoundCloud now requires an Artist Pro
  account for API access. The adapter (`lib/data/platforms/soundcloud_platform.dart`)
  is kept in-repo and can be re-enabled in the dropdown when a `client_id` exists.
- **Last.fm**: free API key (spec §10). Free-tier, revocable — never commit a
  paid key.
- **Deezer**: no key needed for public playlists.

## CI

GitHub Actions runs `flutter analyze` + `flutter test` on every push to `main`.
