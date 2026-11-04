import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/media/voice_player.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chatnav.dart';
import '../widgets/local_counter.dart';
import '../widgets/permission_reason.dart';
import 'carecall_api.dart';
import 'carecall_plan.dart';
import 'carecall_ui.dart';
import 'cc_recorder.dart';

/// carecall SCREEN 1 — the setter's "New Care Call", built exactly as the
/// owner's order describes: Who (first-letter avatar + name, from My Circle
/// family) · What to remind (free text — NEVER filtered — + six suggestion
/// chips) · Time and Repeat side by side · "Record in your own voice" (play
/// back, re-record, delete) · the small grey retry line · ONE main accent
/// button "Turn on Care Call". Offline: the Care Call is kept on the phone
/// and turned on as soon as the phone is online ([CareCallDrafts]).
class CareCallNewScreen extends StatefulWidget {
  const CareCallNewScreen({super.key, this.api, this.edit, this.person, this.debugPeople,
      this.debugVoiceSec, this.debugText, this.limits});

  final CareCallApi? api;

  /// Editing an existing schedule (server JSON of one sent Care Call).
  final Map<String, dynamic>? edit;

  /// Pre-picked person ({user_id, name, initial, link, quiet_start, quiet_end}).
  final Map<String, dynamic>? person;

  /// Gallery / tests: the picker rows without a server.
  final List<Map<String, dynamic>>? debugPeople;

  /// Gallery: show a finished recording of this many seconds.
  final int? debugVoiceSec;
  final String? debugText;
  final Map<String, dynamic>? limits;

  @override
  State<CareCallNewScreen> createState() => _CareCallNewScreenState();
}

class _CareCallNewScreenState extends State<CareCallNewScreen> {
  final _text = TextEditingController();
  Map<String, dynamic>? _who;
  TimeOfDay _time = const TimeOfDay(hour: 9, minute: 0);
  String _repeat = 'daily';
  Set<int> _days = {5, 6, 0, 1, 2, 3, 4};
  DateTime? _date;
  String? _voicePath;
  int _voiceSec = 0;
  bool _voiceDeleted = false;
  bool _recording = false;
  int _recSec = 0;
  Timer? _recTimer;
  CcRecorder? _rec;
  bool _saving = false;
  String? _error;

  int get _maxSec => (widget.limits?['voice_max_seconds'] as num?)?.toInt() ?? 30;
  int get _maxChars => (widget.limits?['text_max_chars'] as num?)?.toInt() ?? 300;
  bool get _isEdit => widget.edit != null;
  bool get _hasVoice => _voicePath != null || widget.debugVoiceSec != null ||
      (_isEdit && widget.edit!['has_voice'] == true && !_voiceDeleted);

  CareCallApi? _api() {
    if (widget.api != null) return widget.api;
    try {
      return HttpCareCallApi(context.read<AppState>().api);
    } catch (_) {
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _who = widget.person;
    _text.text = widget.debugText ?? '';
    if (widget.debugVoiceSec != null) _voiceSec = widget.debugVoiceSec!;
    final e = widget.edit;
    if (e != null) {
      _text.text = '${e['text'] ?? ''}';
      final m = ccMinutes('${e['time'] ?? '09:00'}') ?? 540;
      _time = TimeOfDay(hour: m ~/ 60, minute: m % 60);
      _repeat = '${e['repeat'] ?? 'daily'}';
      _days = {for (final d in (e['days'] as List? ?? const [])) (d as num).toInt()};
      _date = DateTime.tryParse('${e['date'] ?? ''}');
      _voiceSec = (e['voice_sec'] as num?)?.toInt() ?? 0;
      _who = {
        'user_id': e['receiver_id'], 'name': e['other_name'], 'initial': e['other_initial'],
        'link': e['link'], 'quiet_start': e['quiet_start'], 'quiet_end': e['quiet_end'],
      };
    }
  }

  @override
  void dispose() {
    _recTimer?.cancel();
    if (_recording) unawaited(_rec?.stop());
    unawaited(VoicePlayer.instance.stop());
    _text.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- who
  Future<void> _pickWho() async {
    final picked = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _PeoplePicker(api: _api(), debugRows: widget.debugPeople),
    );
    if (picked != null && mounted) setState(() {
      _who = picked;
      _error = null;
    });
  }

  // ---------------------------------------------------------------- time
  Future<void> _pickTime() async {
    final v = await showTimePicker(context: context, initialTime: _time);
    if (v != null && mounted) setState(() => _time = v);
  }

  Future<void> _pickRepeat() async {
    final t = AppLocalizations.of(context);
    final v = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in const ['once', 'daily', 'days'])
          ListTile(
            minTileHeight: 56,
            leading: Icon(r == _repeat ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded),
            title: Text(switch (r) { 'once' => t.ccRepeatOnce, 'days' => t.ccRepeatDays, _ => t.ccRepeatDaily }),
            onTap: () => Navigator.pop(ctx, r),
          ),
        const SizedBox(height: Gap.sm),
      ]),
    );
    if (v != null && mounted) {
      setState(() {
        _repeat = v;
        if (v == 'once') _date ??= _defaultDate();
        if (v == 'days' && _days.isEmpty) _days = {0, 1, 2, 3, 4, 5, 6};
      });
    }
  }

  DateTime _defaultDate() {
    final w = ccBdWall(DateTime.now());
    final today = DateTime(w.year, w.month, w.day);
    final mins = w.hour * 60 + w.minute;
    return (_time.hour * 60 + _time.minute) > mins ? today : today.add(const Duration(days: 1));
  }

  Future<void> _pickDate() async {
    final now = ccBdWall(DateTime.now());
    final first = DateTime(now.year, now.month, now.day);
    final v = await showDatePicker(
        context: context, initialDate: _date ?? first, firstDate: first,
        lastDate: first.add(const Duration(days: 365)));
    if (v != null && mounted) setState(() => _date = v);
  }

  // ---------------------------------------------------------------- voice
  /// Microphone: our own reason first (Play policy), then Android's prompt.
  Future<bool> _micOk() async {
    final forced = ccMicGrantedForTest;
    if (forced != null) return forced;
    try {
      if ((await Permission.microphone.status).isGranted) return true;
    } catch (_) {
      return false; // no permission plugin (tests): treated as refused
    }
    if (!mounted) return false;
    if (!await showPermissionReason(context, PermKind.mic)) return false;
    try {
      return (await Permission.microphone.request()).isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> _record() async {
    final t = AppLocalizations.of(context);
    await VoicePlayer.instance.stop();
    final r = _rec ??= ccRecorderFactory();
    final ok = await _micOk() && await r.start();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.ccMicDenied)));
      return;
    }
    setState(() {
      _recording = true;
      _recSec = 0;
    });
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(seconds: 1), (tm) {
      if (!mounted) return tm.cancel();
      setState(() => _recSec++);
      if (_recSec >= _maxSec) unawaited(_stopRec());
    });
  }

  Future<void> _stopRec() async {
    _recTimer?.cancel();
    final path = await _rec?.stop();
    if (!mounted) return;
    final old = _voicePath;
    setState(() {
      _recording = false;
      if (path != null && _recSec >= 1) {
        _voicePath = path;
        _voiceSec = _recSec;
        _voiceDeleted = false;
        _error = null;
      }
    });
    if (old != null && old != path) unawaited(_rec?.delete(old));
  }

  Future<void> _deleteVoice() async {
    await VoicePlayer.instance.stop();
    final p = _voicePath;
    if (p != null) unawaited((_rec ?? ccRecorderFactory()).delete(p));
    if (mounted) setState(() {
      _voicePath = null;
      _voiceSec = 0;
      _voiceDeleted = true;
    });
  }

  // ---------------------------------------------------------------- save
  Map<String, dynamic> _body() => {
        if (!_isEdit) 'receiver_id': _who?['user_id'],
        'text': _text.text.trim(),
        'time': ccHhmm(_time.hour, _time.minute),
        'repeat': _repeat,
        if (_repeat == 'days') 'days': (_days.toList()..sort()),
        if (_repeat == 'once')
          'date': (_date ?? _defaultDate()).toIso8601String().substring(0, 10),
        if (_isEdit && _voiceDeleted && _voicePath == null) 'delete_voice': true,
      };

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    String? err;
    if (_who == null) {
      err = t.ccErrWho;
    } else if (_text.text.trim().isEmpty && !_hasVoice) {
      err = t.ccErrWhat;
    } else if (_repeat == 'days' && _days.isEmpty) {
      err = t.ccErrDays;
    }
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = _body();
    if (_voicePath != null) {
      try {
        body['voice_b64'] = base64Encode(await File(_voicePath!).readAsBytes());
        body['voice_sec'] = _voiceSec;
      } catch (_) {
        // the recording file is gone: say so, never save without it silently
        if (mounted) {
          setState(() {
            _saving = false;
            _error = t.ccFailed;
          });
        }
        return;
      }
    }
    final api = _api();
    final name = '${_who?['name'] ?? ''}';
    final m = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      if (api == null) throw const SocketException('no api');
      final r = _isEdit
          ? await api.update((widget.edit!['id'] as num).toInt(), body)
          : await api.create(body);
      final link = '${r['link'] ?? (r['care_call'] as Map?)?['link'] ?? ''}';
      if (!mounted) return;
      final msg = link == 'accepted' || _isEdit
          ? t.ccSavedOn(name, ccTimeText(context, ccHhmm(_time.hour, _time.minute)))
          : t.ccSavedPending(name);
      nav.pop(true);
      m.showSnackBar(SnackBar(content: Text(msg)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message.isNotEmpty ? e.message : t.ccFailed;
      });
    } catch (_) {
      // offline: keep it on this phone, turn it on when online
      if (!_isEdit) {
        await CareCallDrafts.add({...body, if (_voicePath != null) 'voice_path': _voicePath});
        body.remove('voice_b64');
        if (!mounted) return;
        nav.pop(true);
        m.showSnackBar(SnackBar(content: Text(t.ccSavedOffline)));
      } else if (mounted) {
        setState(() {
          _saving = false;
          _error = t.ccFailed;
        });
      }
    }
  }

  // ---------------------------------------------------------------- ui
  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final who = _who;
    final hhmm = ccHhmm(_time.hour, _time.minute);
    final chips = [t.ccChipMedicine, t.ccChipMeal, t.ccChipWater, t.ccChipPrayer, t.ccChipWalk, t.ccChipBill];
    final quietAt = _quietShift(who, hhmm);
    return Scaffold(
      appBar: AppBar(title: Text(_isEdit ? t.ccEditTitle : t.ccNewTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.xl),
        children: [
          // ---- Who
          CcField(
            label: t.ccWho,
            semantics: who == null ? t.ccWhoPick : '${who['name']}',
            onTap: _isEdit ? null : _pickWho,
            child: Row(children: [
              CcAvatar(initial: '${who?['initial'] ?? ''}', icon: who == null ? Icons.person_add_alt_1_rounded : null),
              const SizedBox(width: Gap.md),
              Expanded(
                child: Text(who == null ? t.ccWhoPick : '${who['name']}',
                    style: who == null
                        ? tt.bodyLarge?.copyWith(color: s.onSurfaceVariant)
                        : tt.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (!_isEdit) Icon(Icons.expand_more_rounded, color: s.onSurfaceVariant),
            ]),
          ),
          const SizedBox(height: Gap.lg),
          // ---- What to remind
          Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 2),
            child: Text(t.ccWhat, style: tt.labelLarge?.copyWith(color: s.onSurfaceVariant)),
          ),
          TextField(
            controller: _text,
            minLines: 2,
            maxLines: 5,
            maxLength: _maxChars,
            buildCounter: localCounter,
            textCapitalization: TextCapitalization.sentences,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              hintText: t.ccWhatHint,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            for (final c in chips)
              ActionChip(
                label: Text(c),
                onPressed: () {
                  final cur = _text.text.trim();
                  final next = cur.isEmpty ? c : '$cur, $c';
                  if (next.length <= _maxChars) {
                    _text.text = next;
                    _text.selection = TextSelection.collapsed(offset: next.length);
                    setState(() => _error = null);
                  }
                },
              ),
          ]),
          const SizedBox(height: Gap.lg),
          // ---- Time + Repeat, side by side
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: CcField(
                label: t.ccTime,
                semantics: ccTimeText(context, hhmm),
                onTap: _pickTime,
                child: Row(children: [
                  Icon(Icons.schedule_rounded, color: s.primary),
                  const SizedBox(width: Gap.sm),
                  Flexible(child: Text(ccTimeText(context, hhmm), style: tt.titleMedium)),
                ]),
              ),
            ),
            const SizedBox(width: Gap.md),
            Expanded(
              child: CcField(
                label: t.ccRepeat,
                semantics: _repeatLabel(t),
                onTap: _pickRepeat,
                child: Row(children: [
                  Icon(Icons.repeat_rounded, color: s.primary),
                  const SizedBox(width: Gap.sm),
                  Flexible(child: Text(_repeatLabel(t), style: tt.titleMedium)),
                ]),
              ),
            ),
          ]),
          if (_repeat == 'days') ...[
            const SizedBox(height: Gap.sm),
            Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
              for (final d in kCcWeek)
                FilterChip(
                  label: Text(ccDayShort(t, d)),
                  selected: _days.contains(d),
                  onSelected: (on) => setState(() => on ? _days.add(d) : _days.remove(d)),
                ),
            ]),
          ],
          if (_repeat == 'once') ...[
            const SizedBox(height: Gap.xs),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _pickDate,
                icon: const Icon(Icons.event_rounded),
                label: Text('${ccRepeatText(context, 'once', const [], (_date ?? _defaultDate()).toIso8601String())} · ${t.ccOnceChange}'),
              ),
            ),
          ],
          const SizedBox(height: Gap.lg),
          // ---- Own voice
          _voiceCard(t, s, tt),
          const SizedBox(height: Gap.md),
          // ---- the small grey retry line
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, size: 18, color: s.onSurfaceVariant),
            const SizedBox(width: Gap.xs),
            Expanded(child: Text(t.ccRetryLine, style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant))),
          ]),
          if (quietAt != null) ...[
            const SizedBox(height: Gap.sm),
            Text(
                t.ccQuietNote('${who!['name']}', ccTimeText(context, '${who['quiet_start']}'),
                    ccTimeText(context, '${who['quiet_end']}'), quietAt),
                style: tt.bodySmall?.copyWith(color: Brand.warnInk(context))),
          ],
          if (who != null && !_isEdit && who['link'] != 'accepted') ...[
            const SizedBox(height: Gap.sm),
            Text(t.ccConsentNote('${who['name']}'),
                style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant)),
          ],
          if (_error != null) ...[
            const SizedBox(height: Gap.md),
            Semantics(
              liveRegion: true,
              child: Text(_error!, style: tt.bodyMedium?.copyWith(color: s.error)),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: FilledButton.icon(
              onPressed: _saving || _recording ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.phone_callback_rounded),
              label: Text(_isEdit ? t.ccSave : t.ccTurnOn,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
          ),
        ),
      ),
    );
  }

  String _repeatLabel(AppLocalizations t) => switch (_repeat) {
        'once' => t.ccRepeatOnce,
        'days' => _days.length == 7 ? t.ccRepeatDaily : t.ccRepeatDays,
        _ => t.ccRepeatDaily,
      };

  /// When the picked time falls in the receiver's quiet hours: the time it
  /// will really ring (their window's end), else null.
  String? _quietShift(Map<String, dynamic>? who, String hhmm) {
    if (who == null) return null;
    final qs = '${who['quiet_start'] ?? ''}', qe = '${who['quiet_end'] ?? ''}';
    final m = ccMinutes(hhmm)!;
    final probe = ccBdInstant(2026, 1, 5, m ~/ 60, m % 60);
    if (!ccInQuiet(probe, qs, qe)) return null;
    return ccTimeText(context, qe);
  }

  Widget _voiceCard(AppLocalizations t, ColorScheme s, TextTheme tt) {
    final len = ccNum(context, '0:${(_recording ? _recSec : _voiceSec).toString().padLeft(2, '0')}');
    Widget body;
    if (_recording) {
      body = Row(children: [
        Icon(Icons.fiber_manual_record_rounded, color: s.error),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Text('${t.ccRecording} $len / ${ccNum(context, '0:$_maxSec')}',
              style: tt.titleMedium),
        ),
        FilledButton.tonalIcon(
          onPressed: _stopRec,
          icon: const Icon(Icons.stop_rounded),
          label: Text(t.ccRecordStop),
        ),
      ]);
    } else if (_hasVoice) {
      final path = _voicePath;
      body = Row(children: [
        ValueListenableBuilder<VoiceState>(
          valueListenable: VoicePlayer.instance.state,
          builder: (context, v, _) {
            final playing = path != null && v.path == path && v.playing;
            return IconButton.filledTonal(
              tooltip: playing ? t.ccPause : t.ccPlay,
              onPressed: path == null ? null : () => VoicePlayer.instance.toggle(path, durationMs: _voiceSec * 1000),
              icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
            );
          },
        ),
        const SizedBox(width: Gap.sm),
        Expanded(child: Text(t.ccYourVoice(len), style: tt.titleMedium)),
        IconButton(tooltip: t.ccReRecord, onPressed: _record, icon: const Icon(Icons.refresh_rounded)),
        IconButton(tooltip: t.ccDeleteVoice, onPressed: _deleteVoice, icon: const Icon(Icons.delete_outline_rounded)),
      ]);
    } else {
      body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: OutlinedButton.icon(
            onPressed: _record,
            icon: const Icon(Icons.mic_rounded),
            label: Text(t.ccRecord),
          ),
        ),
        const SizedBox(height: Gap.xs),
        Text(t.ccRecordHint(ccNum(context, _maxSec)),
            style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant)),
      ]);
    }
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(Gap.md), child: body),
    );
  }
}

/// The "pick from My Circle family" sheet (one tap). Empty Circle = the
/// benefit line + a big "Open My Circle" button + how-to.
class _PeoplePicker extends StatefulWidget {
  const _PeoplePicker({required this.api, this.debugRows});
  final CareCallApi? api;
  final List<Map<String, dynamic>>? debugRows;
  @override
  State<_PeoplePicker> createState() => _PeoplePickerState();
}

class _PeoplePickerState extends State<_PeoplePicker> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _rows = widget.debugRows;
    if (_rows == null) _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final r = await widget.api!.people();
      if (mounted) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final s = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    Widget body;
    if (_failed) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        Text(t.loadFailed, textAlign: TextAlign.center),
        const SizedBox(height: Gap.md),
        FilledButton.icon(onPressed: _load, icon: const Icon(Icons.refresh_rounded), label: Text(t.retry)),
      ]);
    } else if (_rows == null) {
      body = const Padding(padding: EdgeInsets.all(Gap.xl), child: Center(child: CircularProgressIndicator()));
    } else if (_rows!.isEmpty) {
      body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Icon(Icons.diversity_1_rounded, size: 48, color: s.primary),
        const SizedBox(height: Gap.sm),
        Text(t.ccPickEmpty, textAlign: TextAlign.center, style: tt.titleMedium),
        const SizedBox(height: Gap.md),
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: FilledButton.icon(
            onPressed: () {
              Navigator.pop(context);
              ChatNav.push(context, 'circle');
            },
            icon: const Icon(Icons.group_add_rounded),
            label: Text(t.ccOpenCircle),
          ),
        ),
        const SizedBox(height: Gap.sm),
        Text(t.ccPickEmptyHow, textAlign: TextAlign.center,
            style: tt.bodySmall?.copyWith(color: s.onSurfaceVariant)),
      ]);
    } else {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        for (final r in _rows!)
          ListTile(
            minTileHeight: 64,
            enabled: r['link'] != 'stopped' && r['link'] != 'declined',
            leading: CcAvatar(initial: '${r['initial'] ?? ''}'),
            title: Text('${r['name'] ?? ''}', style: tt.titleMedium),
            subtitle: Text(switch ('${r['link']}') {
              'accepted' => t.ccLinkAccepted,
              'pending' => t.ccLinkPending,
              'stopped' || 'declined' => t.ccLinkStopped,
              _ => t.ccLinkNew,
            }),
            onTap: () => Navigator.pop(context, r),
          ),
      ]);
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: withNavBarInset(context, const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(t.ccPickTitle, style: tt.titleLarge),
          const SizedBox(height: Gap.md),
          body,
        ]),
      ),
    );
  }
}

/// Care Calls saved while offline: created on the server as soon as the
/// phone is online again (CareCallSync.run).
class CareCallDrafts {
  CareCallDrafts._();
  static const key = 'carecall_drafts_v1';

  static Future<List<Map<String, dynamic>>> all() async {
    try {
      final p = await SharedPreferences.getInstance();
      final j = jsonDecode(p.getString(key) ?? '[]') as List;
      return [for (final x in j) Map<String, dynamic>.from(x as Map)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _save(List<Map<String, dynamic>> l) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(l));
    } catch (_) {
      // best-effort: no local storage (tests / blocked) — the online path still works
    }
  }

  static Future<void> add(Map<String, dynamic> body) async {
    final l = await all();
    body.remove('voice_b64');
    l.add(body);
    await _save(l.length > 20 ? l.sublist(l.length - 20) : l);
  }

  /// Send what was saved offline. Kept on a network failure; dropped on a
  /// server refusal (e.g. the person left the Circle) so it never loops.
  static Future<int> flush(CareCallApi api) async {
    final l = await all();
    if (l.isEmpty) return 0;
    var sent = 0;
    final keep = <Map<String, dynamic>>[];
    for (final d in l) {
      final body = Map<String, dynamic>.from(d);
      final vp = body.remove('voice_path');
      if (vp is String) {
        try {
          body['voice_b64'] = base64Encode(await File(vp).readAsBytes());
        } catch (_) {}
      }
      try {
        await api.create(body);
        sent++;
      } on ApiException {
        // refused by the server: not retried
      } catch (_) {
        keep.add(d);
      }
    }
    await _save(keep);
    return sent;
  }
}
