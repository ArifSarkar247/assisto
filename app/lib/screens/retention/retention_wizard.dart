import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'retention_people.dart';
import 'retention_source.dart';
import 'retention_widgets.dart';

/// retention1 — create / edit ONE automation in four short steps:
/// What (the moment) → Who (trigger + honest audience count) → Message
/// (bn + en, variables, live preview with the Stop line) → How (channel,
/// send time, WhatsApp template, on/off).
class RetentionWizardScreen extends StatefulWidget {
  final RetentionSource source;
  final Map<String, dynamic> overview;
  final Map<String, dynamic>? initial;

  /// Tests / gallery: open on this step.
  final int initialStep;
  const RetentionWizardScreen({
    super.key,
    required this.source,
    required this.overview,
    this.initial,
    this.initialStep = 0,
  });

  @override
  State<RetentionWizardScreen> createState() => _RetentionWizardScreenState();
}

class _RetentionWizardScreenState extends State<RetentionWizardScreen> {
  late int _step = widget.initial != null && widget.initialStep == 0 ? 1 : widget.initialStep;
  late String _kind = (widget.initial?['kind'] ?? 'thanks_review').toString();
  late Map<String, int> _params = _paramsFrom(widget.initial?['params']);
  late final _bn = TextEditingController(text: (widget.initial?['template_bn'] ?? _default('bn')).toString());
  late final _en = TextEditingController(text: (widget.initial?['template_en'] ?? _default('en')).toString());
  late final _name = TextEditingController(text: (widget.initial?['name'] ?? '').toString());
  late String _channel = (widget.initial?['channel'] ?? 'in_app').toString();
  late int _hour = rtInt(widget.initial?['send_hour'], 11);
  late final Map<String, dynamic> _wa = Map<String, dynamic>.from(rtMap(widget.initial?['wa_template']));
  late final _waName = TextEditingController(text: (_wa['name'] ?? '').toString());
  late bool _enabled = widget.initial == null ? true : widget.initial!['enabled'] == true;
  TextEditingController? _focused;

  Map<String, dynamic>? _preview;
  bool _previewBusy = false;
  bool _previewFailed = false;
  Timer? _debounce;
  bool _saving = false;
  String? _saveError;

  bool get _editing => widget.initial != null;

  Map<String, dynamic> get _kindSpec =>
      rtList(widget.overview['kinds']).firstWhere((k) => k['kind'] == _kind, orElse: () => const {});

  String _default(String lang) => (_kindSpec[lang == 'bn' ? 'default_bn' : 'default_en'] ?? '').toString();

  Map<String, int> _paramsFrom(Object? raw) {
    final spec = rtMap(_kindSpecFor((widget.initial?['kind'] ?? 'thanks_review').toString())['params']);
    final r = rtMap(raw);
    return {
      for (final e in spec.entries) e.key: rtInt(r[e.key], rtInt(rtMap(e.value)['default'])),
    };
  }

  Map<String, dynamic> _kindSpecFor(String kind) =>
      rtList(widget.overview['kinds']).firstWhere((k) => k['kind'] == kind, orElse: () => const {});

  @override
  void initState() {
    super.initState();
    if (_step >= 1) _schedulePreview(immediate: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _bn.dispose();
    _en.dispose();
    _name.dispose();
    _waName.dispose();
    super.dispose();
  }

  void _pickKind(String k) {
    setState(() {
      _kind = k;
      final spec = rtMap(_kindSpecFor(k)['params']);
      _params = {for (final e in spec.entries) e.key: rtInt(rtMap(e.value)['default'])};
      _bn.text = _default('bn');
      _en.text = _default('en');
      if (k != 'khata_due' && _wa['category'] == 'utility') _wa['category'] = 'marketing';
    });
  }

  Map<String, dynamic> _draft() => {
        'kind': _kind,
        'name': _name.text.trim(),
        'params': _params,
        'template_bn': _bn.text.trim(),
        'template_en': _en.text.trim(),
        'channel': _channel,
        'send_hour': _hour,
        'enabled': _enabled,
        'wa_template': {
          'name': _waName.text.trim(),
          'lang': (_wa['lang'] ?? 'bn').toString(),
          'category': (_wa['category'] ?? 'marketing').toString(),
          'approved': _wa['approved'] == true,
          'has_stop': _wa['has_stop'] == true,
        },
      };

  void _schedulePreview({bool immediate = false}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 400), _runPreview);
  }

  Future<void> _runPreview() async {
    if (!mounted) return;
    setState(() {
      _previewBusy = true;
      _previewFailed = false;
    });
    try {
      final p = await widget.source.preview(_draft());
      if (mounted) setState(() => _preview = p);
    } catch (_) {
      if (mounted) setState(() => _previewFailed = true);
    }
    if (mounted) setState(() => _previewBusy = false);
  }

  void _go(int step) {
    setState(() => _step = step);
    if (step == 1) _schedulePreview(immediate: true);
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      final body = _draft();
      if (_editing) {
        body.remove('kind');
        await widget.source.update(rtInt(widget.initial!['id']), body);
      } else {
        await widget.source.create(body);
      }
      if (mounted) {
        rtSnack(context, t.rtSaved);
        Navigator.of(context).pop(true);
      }
      return;
    } catch (e) {
      _saveError = rtError(e) ?? t.rtGenericError;
    }
    if (mounted) setState(() => _saving = false);
  }

  void _insertVar(String v) {
    final c = _focused ?? _bn;
    final sel = c.selection;
    final text = c.text;
    final at = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final ins = '{$v}';
    c.value = TextEditingValue(
      text: text.replaceRange(at, end, ins),
      selection: TextSelection.collapsed(offset: at + ins.length),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final steps = [t.rtStepWhat, t.rtStepWho, t.rtStepMessage, t.rtStepHow];
    final lang = rtLang(context);
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? t.rtWizardTitleEdit : t.rtWizardTitleNew)),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(children: [
            for (var i = 0; i < steps.length; i++)
              Expanded(
                child: Column(children: [
                  LinearProgressIndicator(value: i <= _step ? 1 : 0, minHeight: 4),
                  const SizedBox(height: 4),
                  Text('${rtDigits(lang, i + 1)}. ${steps[i]}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(fontWeight: i == _step ? FontWeight.w700 : FontWeight.w400)),
                ]),
              ),
          ]),
        ),
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
            if (_step == 0) ..._whatStep(t),
            if (_step == 1) ..._whoStep(t, lang),
            if (_step == 2) ..._messageStep(t, lang),
            if (_step == 3) ..._howStep(t, lang),
            if (_saveError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_saveError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(children: [
              if (_step > (_editing ? 1 : 0))
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(48, 52)),
                    onPressed: _saving ? null : () => _go(_step - 1),
                    child: Text(t.rtBack),
                  ),
                ),
              if (_step > (_editing ? 1 : 0)) const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
                  onPressed: _saving
                      ? null
                      : _step < 3
                          ? (_step == 2 && _bn.text.trim().isEmpty && _en.text.trim().isEmpty
                              ? null
                              : () => _go(_step + 1))
                          : _save,
                  child: Text(_step < 3 ? t.rtNext : t.rtSave),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------ step 0
  List<Widget> _whatStep(AppLocalizations t) => [
        Text(t.rtWhatTitle, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        for (final k in rtKinds)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(
                  color: _kind == k ? Theme.of(context).colorScheme.primary : Colors.transparent, width: 2),
            ),
            child: ListTile(
              minVerticalPadding: 12,
              leading: Icon(rtKindIcon(k)),
              title: Text(rtKindTitle(t, k)),
              subtitle: Text(rtKindDesc(t, k)),
              trailing: _kind == k ? const Icon(Icons.check_circle_rounded) : null,
              selected: _kind == k,
              onTap: () => _pickKind(k),
            ),
          ),
      ];

  // ------------------------------------------------------------ step 1
  String _paramLabel(AppLocalizations t, String p) => switch (p) {
        'days_after' => t.rtParamDaysAfter,
        'days_without' => t.rtParamDaysWithout,
        'min_due_taka' => t.rtParamMinDue,
        'every_days' => t.rtParamEvery,
        _ => p,
      };

  int _stepOf(String p) => switch (p) {
        'days_without' => 5,
        'min_due_taka' => 50,
        _ => 1,
      };

  Widget _paramRow(AppLocalizations t, String lang, String p, Map<String, dynamic> spec) {
    final v = _params[p] ?? rtInt(spec['default']);
    final lo = rtInt(spec['min']), hi = rtInt(spec['max']);
    final st = _stepOf(p);
    void set(int n) {
      setState(() => _params[p] = n.clamp(lo, hi));
      _schedulePreview();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(_paramLabel(t, p))),
        IconButton(
          tooltip: t.rtLess,
          icon: const Icon(Icons.remove_circle_outline_rounded),
          onPressed: v > lo ? () => set(v - st) : null,
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48),
          child: Text(rtDigits(lang, v),
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton(
          tooltip: t.rtMore,
          icon: const Icon(Icons.add_circle_outline_rounded),
          onPressed: v < hi ? () => set(v + st) : null,
        ),
      ]),
    );
  }

  List<Widget> _whoStep(AppLocalizations t, String lang) {
    final spec = rtMap(_kindSpec['params']);
    final p = _preview;
    return [
      Row(children: [
        Icon(rtKindIcon(_kind)),
        const SizedBox(width: 8),
        Expanded(child: Text(rtKindTitle(t, _kind), style: Theme.of(context).textTheme.titleMedium)),
      ]),
      const SizedBox(height: 4),
      Text(rtKindWhen(t, lang, _kind, _params)),
      const SizedBox(height: 8),
      for (final e in spec.entries) _paramRow(t, lang, e.key, rtMap(e.value)),
      const Divider(height: 24),
      Text(t.rtAudienceTitle, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      if (_previewBusy && p == null)
        Row(children: [
          const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Text(t.rtCounting),
        ])
      else if (_previewFailed && p == null)
        Row(children: [
          Expanded(child: Text(t.rtPreviewError)),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(64, 48)),
            onPressed: () => _schedulePreview(immediate: true),
            child: Text(t.rtRetry),
          ),
        ])
      else if (p != null)
        ..._audienceLines(t, lang, p),
      if (_kind == 'birthday' || _kind == 'back_in_stock') ...[
        const SizedBox(height: 12),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: Icon(_kind == 'birthday' ? Icons.cake_outlined : Icons.inventory_2_outlined),
          label: Text(_kind == 'birthday' ? t.rtManageBirthdays : t.rtManageAsks),
          onPressed: () async {
            await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _kind == 'birthday'
                    ? RetentionBirthdaysScreen(source: widget.source)
                    : RetentionStockAsksScreen(source: widget.source)));
            _schedulePreview(immediate: true);
          },
        ),
      ],
      const SizedBox(height: 12),
      Text(t.rtNoColdOutreach, style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  List<Widget> _audienceLines(AppLocalizations t, String lang, Map<String, dynamic> p) {
    final aud = rtInt(p['audience']);
    Widget line(IconData i, String s) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(i, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(s)),
          ]),
        );
    return [
      if (aud == 0)
        line(Icons.hourglass_empty_rounded, t.rtAudienceEmpty)
      else
        line(Icons.groups_2_outlined, t.rtAudienceCount(rtDigits(lang, aud))),
      if (aud > 0) line(Icons.schedule_send_outlined, t.rtDueNow(rtDigits(lang, rtInt(p['due_now'])))),
      if (p['on_assisto'] != null && aud > 0)
        line(Icons.phone_android_rounded, t.rtOnAssisto(rtDigits(lang, rtInt(p['on_assisto'])))),
      if (rtInt(p['opted_out']) > 0)
        line(Icons.block_rounded, t.rtOptedOutCount(rtDigits(lang, rtInt(p['opted_out'])))),
      if (rtInt(p['no_phone']) > 0)
        line(Icons.phone_disabled_outlined, t.rtNoPhone(rtDigits(lang, rtInt(p['no_phone'])))),
    ];
  }

  // ------------------------------------------------------------ step 2
  String _varLabel(AppLocalizations t, String v) => switch (v) {
        'name' => t.rtVarName,
        'shop' => t.rtVarShop,
        'product' => t.rtVarProduct,
        'days' => t.rtVarDays,
        'due' => t.rtVarDue,
        _ => v,
      };

  String _localPreview(AppLocalizations t, String lang) {
    final src = lang == 'en'
        ? (_en.text.trim().isNotEmpty ? _en.text : _bn.text)
        : (_bn.text.trim().isNotEmpty ? _bn.text : _en.text);
    final shop = (widget.overview['shop'] ?? '').toString();
    final vals = {
      'name': t.rtExampleName,
      'shop': shop.isNotEmpty ? shop : t.rtExampleShop,
      'product': t.rtExampleProduct,
      'days': rtDigits(lang, rtInt(_params['days_without'], 45)),
      'due': rtDigits(lang, '1,250'),
    };
    final body = src.replaceAllMapped(RegExp(r'\{([a-zA-Z_]+)\}'), (m) => vals[m.group(1)] ?? '');
    final footer = switch (_channel) {
      'in_app' => t.rtFooterInApp,
      'sms' => t.rtFooterSms,
      _ => t.rtFooterChat,
    };
    return '${body.trim()}\n$footer';
  }

  Widget _templateField(String label, TextEditingController c) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Focus(
          onFocusChange: (f) {
            if (f) _focused = c;
          },
          child: TextField(
            controller: c,
            minLines: 3,
            maxLines: 6,
            maxLength: 400,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
                labelText: label, border: const OutlineInputBorder(), alignLabelWithHint: true),
          ),
        ),
      );

  List<Widget> _messageStep(AppLocalizations t, String lang) {
    final vars = (_kindSpec['vars'] is List)
        ? (_kindSpec['vars'] as List).map((e) => '$e').toList()
        : <String>['name', 'shop'];
    return [
      _templateField(t.rtMessageBn, _bn),
      _templateField(t.rtMessageEn, _en),
      Text(t.rtInsert, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final v in vars)
          ActionChip(
            avatar: const Icon(Icons.add_rounded, size: 18),
            label: Text(_varLabel(t, v)),
            materialTapTargetSize: MaterialTapTargetSize.padded,
            onPressed: () => _insertVar(v),
          ),
        ActionChip(
          avatar: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text(t.rtUseDefault),
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onPressed: () => setState(() {
            _bn.text = _default('bn');
            _en.text = _default('en');
          }),
        ),
      ]),
      const SizedBox(height: 16),
      Text(t.rtPreviewLabel, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(_localPreview(t, lang)),
      ),
      const SizedBox(height: 6),
      Text(t.rtStopAdded, style: Theme.of(context).textTheme.bodySmall),
    ];
  }

  // ------------------------------------------------------------ step 3
  List<Widget> _howStep(AppLocalizations t, String lang) {
    final ready = (widget.overview['channels_ready'] is List)
        ? (widget.overview['channels_ready'] as List).map((e) => '$e').toSet()
        : {'in_app'};
    final loc = MaterialLocalizations.of(context);
    return [
      Text(t.rtChannel, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      RadioGroup<String>(
        groupValue: _channel,
        onChanged: (v) {
          if (v != null && ready.contains(v)) setState(() => _channel = v);
        },
        child: Column(children: [
          for (final ch in rtChannels)
            RadioListTile<String>(
              value: ch,
              enabled: ready.contains(ch),
              secondary: Icon(rtChannelIcon(ch)),
              title: Text(rtChannelName(t, ch)),
              subtitle: Text(ready.contains(ch)
                  ? rtChannelDesc(t, ch)
                  : '${rtChannelDesc(t, ch)} ${t.rtChNotConnected}'),
              contentPadding: EdgeInsets.zero,
            ),
        ]),
      ),
      if (_channel == 'whatsapp') ..._waFields(t),
      const Divider(height: 24),
      Row(children: [
        Expanded(child: Text(t.rtSendTime)),
        DropdownButton<int>(
          value: _hour,
          onChanged: (v) => setState(() => _hour = v ?? 11),
          items: [
            for (var h = 9; h <= 20; h++)
              DropdownMenuItem(value: h, child: Text(loc.formatTimeOfDay(TimeOfDay(hour: h, minute: 0)))),
          ],
        ),
      ]),
      Text(t.rtSendTimeHelp, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 12),
      TextField(
        controller: _name,
        maxLength: 80,
        decoration: InputDecoration(labelText: t.rtName, border: const OutlineInputBorder()),
      ),
      SwitchListTile(
        value: _enabled,
        onChanged: (v) => setState(() => _enabled = v),
        title: Text(t.rtTurnOn),
        contentPadding: EdgeInsets.zero,
      ),
    ];
  }

  List<Widget> _waFields(AppLocalizations t) {
    final cat = (_wa['category'] ?? 'marketing').toString();
    return [
      const SizedBox(height: 8),
      Text(t.rtWaTemplateTitle, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 4),
      Text(t.rtWaTemplateHelp, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 8),
      TextField(
        controller: _waName,
        decoration: InputDecoration(labelText: t.rtWaTemplateName, border: const OutlineInputBorder()),
      ),
      const SizedBox(height: 8),
      Text(t.rtWaCategory),
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [
        ChoiceChip(
          label: Text(t.rtWaMarketing),
          selected: cat == 'marketing',
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onSelected: (_) => setState(() => _wa['category'] = 'marketing'),
        ),
        ChoiceChip(
          label: Text(t.rtWaUtility),
          selected: cat == 'utility',
          materialTapTargetSize: MaterialTapTargetSize.padded,
          onSelected: _kind == 'khata_due' ? (_) => setState(() => _wa['category'] = 'utility') : null,
        ),
      ]),
      Text(t.rtWaUtilityNote, style: Theme.of(context).textTheme.bodySmall),
      CheckboxListTile(
        value: _wa['approved'] == true,
        onChanged: (v) => setState(() => _wa['approved'] = v == true),
        title: Text(t.rtWaApproved),
        contentPadding: EdgeInsets.zero,
      ),
      CheckboxListTile(
        value: _wa['has_stop'] == true,
        onChanged: (v) => setState(() => _wa['has_stop'] = v == true),
        title: Text(t.rtWaHasStop),
        contentPadding: EdgeInsets.zero,
      ),
    ];
  }
}
