import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../calls/call_log.dart';
import '../calls/call_recording.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import '../widgets/notif_models.dart' show notifLocalizeDigits;

/// b3-group B5: call recordings made WITH everyone's consent, kept encrypted
/// on this phone only. Play decrypts into the app cache for the moment it
/// plays (both tracks — your voice and the others — together); Share
/// decrypts, hands the files to the share sheet, then wipes them.
class CallRecordingsScreen extends StatefulWidget {
  const CallRecordingsScreen({super.key, this.vault});
  final RecordingVault? vault;

  @override
  State<CallRecordingsScreen> createState() => _CallRecordingsScreenState();
}

class _CallRecordingsScreenState extends State<CallRecordingsScreen> {
  List<SavedRecording>? _rows;
  String? _playing;
  final List<AudioPlayer> _players = [];
  List<String> _open = const [];

  RecordingVault get _vault => widget.vault ?? RecordingVault.instance;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await _vault.list();
    if (mounted) setState(() => _rows = l);
  }

  @override
  void dispose() {
    unawaited(_stop());
    super.dispose();
  }

  Future<void> _stop() async {
    for (final p in _players) {
      try {
        await p.stop();
        await p.dispose();
      } catch (_) {}
    }
    _players.clear();
    await _vault.wipe(_open);
    _open = const [];
    _playing = null;
  }

  Future<void> _play(SavedRecording r) async {
    if (_playing == r.id) {
      await _stop();
      if (mounted) setState(() {});
      return;
    }
    await _stop();
    try {
      final files = await _vault.open(r);
      if (files.isEmpty) throw StateError('empty');
      _open = files;
      for (var n = 0; n < files.length; n++) {
        final p = AudioPlayer();
        _players.add(p);
        p.onPlayerComplete.listen((_) {
          if (mounted && _playing == r.id) setState(() => _playing = null);
        });
      }
      // both tracks start together (my voice + everyone else)
      await Future.wait([
        for (var i = 0; i < files.length; i++)
          _players[i].play(DeviceFileSource(files[i]))
      ]);
      if (mounted) setState(() => _playing = r.id);
    } catch (e) {
      callLog('recordings#play', e);
      await _stop();
      _toast(AppLocalizations.of(context).b3RecordFailed);
    }
  }

  Future<void> _share(SavedRecording r) async {
    final t = AppLocalizations.of(context);
    List<String> files = const [];
    try {
      files = await _vault.open(r);
      if (files.isEmpty) throw StateError('empty');
      await Share.shareXFiles([for (final f in files) XFile(f)],
          text: t.b3RecordingShareText(r.title));
    } catch (e) {
      callLog('recordings#share', e);
      _toast(t.b3RecordFailed);
    } finally {
      // the share sheet has copied what it needs by the time it returns
      Timer(const Duration(minutes: 2), () => _vault.wipe(files));
    }
  }

  Future<void> _delete(SavedRecording r) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.b3DeleteConfirm),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(t.b3Cancel)),
          FilledButton(
              key: const Key('recording-delete-confirm'),
              style: FilledButton.styleFrom(backgroundColor: Brand.dangerFill),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(t.b3Delete)),
        ],
      ),
    );
    if (ok != true) return;
    if (_playing == r.id) await _stop();
    await _vault.delete(r);
    await _load();
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  String _len(int s) {
    String two(int n) => n.toString().padLeft(2, '0');
    final raw = '${two(s ~/ 60)}:${two(s % 60)}';
    return notifLocalizeDigits(context, raw);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rows = _rows;
    final lang = Localizations.localeOf(context).languageCode;
    return Scaffold(
      appBar: AppBar(title: Text(t.b3RecordingsTitle)),
      body: rows == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(Gap.lg),
              children: [
                Card(
                  child: ListTile(
                    leading: Icon(Icons.lock_outline, color: scheme.primary),
                    title: Text(t.b3RecordingsNote),
                  ),
                ),
                const SizedBox(height: Gap.md),
                if (rows.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Gap.xl),
                    child: Text(t.b3RecordingsEmpty,
                        key: const Key('recordings-empty'),
                        textAlign: TextAlign.center),
                  ),
                for (final r in rows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            key: Key('recording-${r.id}'),
                            leading: CircleAvatar(
                              backgroundColor: scheme.primaryContainer,
                              child: Icon(
                                  _playing == r.id
                                      ? Icons.pause
                                      : Icons.play_arrow,
                                  color: scheme.onPrimaryContainer),
                            ),
                            title: Text(
                                r.title.isEmpty ? t.b3GroupCallTitle : r.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${notifLocalizeDigits(context, DateFormat.yMMMd(lang).add_jm().format(r.at))} · ${_len(r.seconds)}'
                              '${r.people.isEmpty ? '' : '\n${t.b3RecordingWith(r.people.join(', '))}'}',
                            ),
                            isThreeLine: r.people.isNotEmpty,
                            onTap: () => _play(r),
                          ),
                          Wrap(
                            spacing: Gap.xs,
                            children: [
                              TextButton.icon(
                                onPressed: () => _play(r),
                                icon: Icon(_playing == r.id
                                    ? Icons.stop
                                    : Icons.play_arrow),
                                label: Text(_playing == r.id
                                    ? t.b3Stop
                                    : t.b3Play),
                              ),
                              TextButton.icon(
                                key: Key('recording-share-${r.id}'),
                                onPressed: () => _share(r),
                                icon: const Icon(Icons.share_outlined),
                                label: Text(t.b3Share),
                              ),
                              TextButton.icon(
                                key: Key('recording-delete-${r.id}'),
                                style: TextButton.styleFrom(
                                    foregroundColor: scheme.error),
                                onPressed: () => _delete(r),
                                icon: const Icon(Icons.delete_outline),
                                label: Text(t.b3Delete),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: Gap.sm),
                Text(t.b3RecordingTracksNote,
                    style: TextStyle(
                        fontSize: 12, color: scheme.onSurfaceVariant)),
              ],
            ),
    );
  }
}
