// Playback log screen (full-song pivot, push 1): every full-song
// resolve attempt — track, time, and each source tried with its
// outcome + detail — newest first, expandable per-source detail.
// Reachable from Settings. The log is in-memory (last ~100 attempts)
// and clears when the app restarts.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../data/fullsong/resolution_log.dart';
import '../providers/providers.dart';

class PlaybackLogScreen extends ConsumerWidget {
  const PlaybackLogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(resolutionLogProvider);
    final ordered = entries.reversed.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Playback log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear log',
            onPressed: entries.isEmpty
                ? null
                : () => ref.read(resolutionLogProvider.notifier).clear(),
          ),
        ],
      ),
      body: ordered.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No playback attempts yet.\nPlay a track and the '
                  'sources tried — and why each one matched or failed '
                  '— will show up here.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.builder(
              itemCount: ordered.length,
              itemBuilder: (context, index) {
                final entry = ordered[index];
                return ExpansionTile(
                  title: Text('${entry.artist} — ${entry.title}'),
                  subtitle: Text(
                      '${entry.result} · ${_formatTime(entry.time)}'),
                  children: [
                    for (final attempt in entry.attempts)
                      ListTile(
                        leading: Icon(
                          attempt.outcome == SourceOutcome.matched
                              ? Icons.check_circle_outline
                              : attempt.outcome ==
                                          SourceOutcome.networkError ||
                                      attempt.outcome ==
                                          SourceOutcome.sessionRejected
                                  ? Icons.error_outline
                                  : Icons.remove_circle_outline,
                          color: attempt.outcome == SourceOutcome.matched
                              ? Colors.green
                              : null,
                        ),
                        title: Text(attempt.source),
                        subtitle: Text(
                          attempt.detail.isEmpty
                              ? attempt.outcome.label
                              : '${attempt.outcome.label} — ${attempt.detail}',
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }

  static String _formatTime(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    final s = time.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
