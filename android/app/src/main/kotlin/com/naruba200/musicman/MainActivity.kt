package com.naruba200.musicman

import com.ryanheise.audioservice.AudioServiceActivity

// Extends AudioServiceActivity (a FlutterActivity) so the activity
// reuses the Flutter engine the audio service runs in — otherwise
// tapping the media notification would spin up a second engine (and
// a second player) instead of the one the notification controls.
class MainActivity : AudioServiceActivity()
