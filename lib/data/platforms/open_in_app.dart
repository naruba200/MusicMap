// Open a link in a non-browser app when one can handle it, falling back
// to the browser. No custom app schemes are guessed here: url_launcher's
// externalNonBrowserApplication already asks Android for a non-browser
// handler (e.g. Spotify / YouTube / YouTube Music / Deezer when installed)
// and returns false when there is none, so the browser fallback below
// keeps working on devices without those apps installed.

import 'package:url_launcher/url_launcher.dart';

/// Try a non-browser app first, then the browser. Returns true if either
/// launch succeeded, false (never throws) if neither did.
Future<bool> openLinkInAppFirst(Uri uri) async {
  try {
    if (await launchUrl(uri,
        mode: LaunchMode.externalNonBrowserApplication)) {
      return true;
    }
  } catch (_) {
    // Fall through to the browser attempt below.
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
