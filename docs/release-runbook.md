# Release runbook — Music Map v1.0.0 (M5)

## 0. One-time setup (do once)

### applicationId
Your `android/` folder is local-only (not in the repo). In
`android/app/build.gradle`, set:

```gradle
namespace = "com.naruba200.musicmap"
...
applicationId = "com.naruba200.musicmap"
```

(`com.example.*` is rejected by Play Console. Pick this once — it can
never change after first upload.)

### Keystore (signing key — do once, back it up!)
```powershell
keytool -genkey -v -keystore D:\keys\musicmap-release.jks `
  -keyalg RSA -keysize 2048 -validity 10000 -alias musicmap
```
Back up `musicmap-release.jks` + passwords somewhere safe (USB drive /
password manager). **Losing it = you can never update the app.**

### key.properties (NOT in git)
Create `android/key.properties` (never commit this file):
```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=musicmap
storeFile=D:/keys/musicmap-release.jks
```
Wire it in `android/app/build.gradle` (`signingConfigs.release` →
`buildTypes.release.signingConfig`). Also add `key.properties` to
`.gitignore` if you ever commit `android/`.

### GitHub Pages (privacy policy URL)
Repo Settings → Pages → Deploy from branch → `main` → `/docs`.
Wait ~1 min, then check `https://naruba200.github.io/MusicMap/privacy.html`.

### Launcher icons
```powershell
xcopy assets\launcher_icons\res android\app\src\main\res /E /Y
```
(See `assets/launcher_icons/README.md`.)

## 1. Every release

1. `git pull` — make sure you're on latest `main`.
2. Bump version in `pubspec.yaml`: `version: 1.0.1+2` etc.
   (x.y.z = shown to users, +N = Play's versionCode, must increase.)
3. `flutter clean; flutter pub get`
4. `flutter analyze` — must be clean.
5. `flutter test` — all green.
6. Build: `flutter build appbundle --release`
   → `build/app/outputs/bundle/release/app-release.aab`
7. Play Console → Music Map → **Testing → Closed testing** → new release →
   upload the `.aab`, fill release notes, roll out to your testers list.
8. Install the closed-testing build on your phone; run the manual QA
   matrix (§15 of the spec: airplane mode, 600-track playlist, 150-rec run,
   news offline, all-sources-off, 1.3× font, dark mode…).
9. Fix, bump, repeat → then **Production** track when clean.

## 2. First-time Play Console checklist
- [ ] App created, package `com.naruba200.musicmap`
- [ ] Listing filled from `docs/play-listing.md` (title, short/long desc)
- [ ] Graphics: 512 icon ✓ (repo), feature graphic 1024×500, ≥2 screenshots
- [ ] Privacy policy URL set
- [ ] Data safety form: "No data collected"
- [ ] Content rating questionnaire: Everyone
- [ ] Closed-testing track live before production

## 3. Version history
- **1.0.0+1** (2026-10-19): first release. M0–M4: playlist intake
  (Deezer, YouTube Music β), Last.fm recommendation engine, favorites,
  history, settings, music-news tab. Desktop TEST-ONLY Spotify
  scaffolding removed.
