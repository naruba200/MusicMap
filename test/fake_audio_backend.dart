// Fake AudioBackend for player tests: records play/pause/resume/stop/
// seek calls and lets the test drive the backend's state, position and
// duration streams. No platform audio is touched.

import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:music_man/presentation/providers/audio_backend.dart';

class FakeAudioBackend implements AudioBackend {
  final stateController = StreamController<PlayerState>.broadcast();
  final positionController = StreamController<Duration>.broadcast();
  final durationController = StreamController<Duration>.broadcast();
  final playedUrls = <String>[];
  Object? playError;
  int pauseCalls = 0;
  int resumeCalls = 0;
  int stopCalls = 0;
  Duration? lastSeek;

  @override
  Stream<PlayerState> get onPlayerStateChanged => stateController.stream;
  @override
  Stream<Duration> get onPositionChanged => positionController.stream;
  @override
  Stream<Duration> get onDurationChanged => durationController.stream;

  @override
  Future<void> play(String url) async {
    if (playError != null) throw playError!;
    playedUrls.add(url);
    stateController.add(PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    stateController.add(PlayerState.paused);
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
    stateController.add(PlayerState.playing);
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    stateController.add(PlayerState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    lastSeek = position;
    positionController.add(position);
  }

  @override
  Future<void> dispose() async {
    await stateController.close();
    await positionController.close();
    await durationController.close();
  }
}
