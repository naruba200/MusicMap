# Launcher icons (M5)

Generated 2026-10-19: violet music-note-in-map-pin on deep purple,
matching the "Nocturne Electric" dark theme (#A855F7).

## Install (on your dev machine, android/ is local-only)

Copy the whole `res/` tree into your Android project:

```
xcopy assets\launcher_icons\res android\app\src\main\res /E /Y
```

i.e. `res/mipmap-mdpi/ic_launcher.png` → `android/app/src/main/res/mipmap-mdpi/ic_launcher.png`,
and so on for hdpi / xhdpi / xxhdpi / xxxhdpi.

These are legacy PNG icons; launchers mask them fine. If you later want
adaptive icons, use `store/ic_playstore_512.png` as the foreground source
and add `mipmap-anydpi-v26/ic_launcher.xml`.

## Play Store

`store/ic_playstore_512.png` is the 512×512 high-res icon for the
Play Console listing.
