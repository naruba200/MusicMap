# Android setup (run once after `flutter create --platforms=android .`)

The Flutter code is complete, but two intent-filters must be added to
`android/app/src/main/AndroidManifest.xml` inside the `<activity>` that has
the `MAIN` / `LAUNCHER` intent-filter:

```xml
<!-- 1. Spotify OAuth redirect: musicmap://callback?code=... -->
<intent-filter>
    <action android:name="android.intent.action.VIEW" />
    <category android:name="android.intent.category.DEFAULT" />
    <category android:name="android.intent.category.BROWSABLE" />
    <data android:scheme="musicmap" android:host="callback" />
</intent-filter>

<!-- 2. Receive shared playlist links (text/plain) from other apps -->
<intent-filter>
    <action android:name="android.intent.action.SEND" />
    <category android:name="android.intent.category.DEFAULT" />
    <data android:mimeType="text/plain" />
</intent-filter>
```

Notes:

- `flutter create --platforms=android .` does not overwrite an existing
  `AndroidManifest.xml`; if you already edited it, your filters survive.
- The redirect URI registered in the Spotify dashboard must be exactly
  `musicmap://callback`.
- Deep links (`app_links`) and shared text (`receive_sharing_intent`) are
  both handled in `lib/presentation/providers/providers.dart`
  (`deepLinkHandlerProvider`): any recognized playlist URL opens the
  playlist-detail screen directly.
