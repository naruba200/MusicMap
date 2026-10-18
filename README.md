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

### Desktop testing (temporary scaffolding)

`flutter run -d windows` works for UI testing. Spotify sign-in on desktop
uses a loopback redirect because the `musicmap://` scheme isn't registered
with the OS:

1. In the Spotify dashboard, add a second redirect URI:
   `http://127.0.0.1:8899/callback` (keep `musicmap://callback` too).
2. Sign in from the app — the browser opens, and after login a local
   server inside the app captures the code.

This is test-only scaffolding: `signInDesktop()` in
`lib/data/platforms/spotify_platform.dart` is marked TEST-ONLY and should
be removed before release. Share-intent receiving is Android-only and is
automatically skipped on desktop.

## Keys & setup notes

- **Spotify**: **parked for v1** (adapter kept in-repo). Since Feb 2026
  Spotify blocks Dev Mode apps from the Web API unless the dashboard account
  holds Premium, and playlist creation needs user OAuth — so v1 does intake
  via Deezer (no auth) and links out via Spotify search URLs (no auth).
- **Deezer**: no key needed for public playlists — the zero-setup intake path.
- **SoundCloud**: parked for v1 — SoundCloud now requires an Artist Pro
  account for API access. The adapter (`lib/data/platforms/soundcloud_platform.dart`)
  is kept in-repo and can be re-enabled in the dropdown when a `client_id` exists.
- **Last.fm**: free API key (spec §10). Free-tier, revocable — never commit a
  paid key.
- **Deezer**: no key needed for public playlists.

## CI

GitHub Actions runs `flutter analyze` + `flutter test` on every push to `main`.
