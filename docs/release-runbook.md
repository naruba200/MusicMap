# Release runbook — Music Man v1.0.0 (M5)

## 0. One-time setup (do once)

### applicationId
Your `android/` folder is in the repo. In
`android/app/build.gradle.kts`, it is set to:

```gradle
namespace = "com.naruba200.musicman"
...
applicationId = "com.naruba200.musicman"
```

(`com.example.*` is rejected by Play Console. Pick this once — it can
never change after first upload.)

**⚠️ Do not skip — MainActivity package (learned the hard way, 2026-10-20):**
changing the ID is NOT enough. `MainActivity.kt` still declares the
`flutter create` package, so the manifest's `.MainActivity` points at a
class that isn't in the APK → `ClassNotFoundException`, app dies
instantly on launch, and the build does NOT warn you. Fixed 2026-10-24: the file now lives at
`android/app/src/main/kotlin/com/naruba200/musicman/MainActivity.kt` with
its first line:

```kotlin
package com.naruba200.musicman
```

**⚠️ Do not skip — INTERNET permission (learned the hard way, 2026-10-20):**
the `flutter create` MAIN manifest does NOT declare INTERNET (Flutter
only adds it to the debug/profile manifests). A release build without it
has NO network at all — and the failure disguises itself as DNS:
`SocketException: Failed host lookup (errno = 7)`, because Android's
resolver refuses lookups for apps lacking the permission. News, Last.fm,
YouTube Music — everything dies at its first call, on phone AND
emulator, while desktop/web builds work fine. Fix: in
`android/app/src/main/AndroidManifest.xml`, inside `<manifest>` above
`<application>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
```

(Done 2026-10-24.)
### Keystore (signing key — do once, back it up!)
```powershell
keytool -genkey -v -keystore D:\keys\musicman-release.jks `
  -keyalg RSA -keysize 2048 -validity 10000 -alias musicman
```
Back up `musicman-release.jks` + passwords somewhere safe (USB drive /
password manager). **Losing it = you can never update the app.**

**Pending (PC off, 2026-10-24):** the keystore actually on your PC is still
`musicmap-release.jks` / alias `musicmap`. When the PC is on, do NOT create
a new key — rename the alias in place, then rename the file:
```powershell
keytool -changealias -keystore D:\keys\musicmap-release.jks -alias musicmap -destalias musicman
# then rename D:\keys\musicmap-release.jks to D:\keys\musicman-release.jks
# and update android/key.properties to match
```
Until then a signed build from the PC will still use the old key.properties values.

### key.properties (NOT in git)
Create `android/key.properties` (never commit this file):
```properties
storePassword=YOUR_STORE_PASSWORD
keyPassword=YOUR_KEY_PASSWORD
keyAlias=musicman
storeFile=D:/keys/musicman-release.jks
```
Wire it in `android/app/build.gradle.kts` (`signingConfigs.release` →
`buildTypes.release.signingConfig`). **Note:** newer Flutter templates use
Kotlin DSL (`build.gradle.kts`), not Groovy (`build.gradle`) — use the
matching snippet below.

Groovy (`build.gradle`):
```gradle
def keystoreProperties = new Properties()
def keystorePropertiesFile = rootProject.file('key.properties')
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))
}
```
```gradle
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile keystoreProperties['storeFile'] ? file(keystoreProperties['storeFile']) : null
            storePassword keystoreProperties['storePassword']
        }
    }
```
then in `buildTypes { release { ... } }` change
`signingConfig signingConfigs.debug` → `signingConfig signingConfigs.release`.

Kotlin DSL (`build.gradle.kts`):
```kotlin
import java.io.FileInputStream
import java.util.Properties

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
```
```kotlin
    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }
```
then in `buildTypes { release { ... } }` change
`signingConfig = signingConfigs.getByName("debug")` →
`signingConfig = signingConfigs.getByName("release")`.

### GitHub Pages (privacy policy URL)
Repo Settings → Pages → Deploy from branch → `main` → `/docs`.
Wait ~1 min, then check `https://naruba200.github.io/MusicMap/privacy.html`.

### Launcher icons
```powershell
# Icons ship as musicmap-launcher-icons.zip (sent in chat 2026-10-19 —
# the GitHub connector can't push binary files). Extract it, then:
xcopy launcher-icons\res android\app\src\main\res /E /Y
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
7. Play Console → Music Man → **Testing → Closed testing** → new release →
   upload the `.aab`, fill release notes, roll out to your testers list.
8. Install the closed-testing build on your phone; run the manual QA
   matrix (§15 of the spec: airplane mode, 600-track playlist, 150-rec run,
   news offline, all-sources-off, 1.3× font, dark mode…).
9. Fix, bump, repeat → then **Production** track when clean.

## 2. First-time Play Console checklist
- [ ] App created, package `com.naruba200.musicman`
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
