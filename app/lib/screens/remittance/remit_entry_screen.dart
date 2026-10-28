import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';
import 'remit_parser.dart';
import 'remit_source.dart';
import 'remit_widgets.dart';

/// What the entry screen returns: saved online, queued offline, or deleted.
enum RemitSaved { online, queued, deleted }

/// budget-remittance: add / edit ONE "money received from abroad" entry.
/// Opened empty, from a quick sentence ([draft], always shown for checking —
/// nothing is saved until the user taps Save), or with an [entry] to edit.
/// Offline, a NEW entry is kept on this phone and synced later.
class RemitEntryScreen extends StatefulWidget {
  final RemitSource source;
  final RemitQueue queue;
  final Map<String, dynamic>? entry;
  final RemitDraft? draft;
  final String? said;
  final List<Map<String, dynamic>>? members;
  const RemitEntryScreen({
    super.key,
    required this.source,
    required this.queue,
    this.entry,
    this.draft,
    this.said,
    this.members,
  });

  @override
  State<RemitEntryScreen> createState() => _RemitEntryScreenState();
}

const kRmLastCurrency = 'remit_last_currency';
const kRmLastChannel = 'remit_last_channel';

class _RemitEntryScreenState extends State<RemitEntryScreen> {
  final _form = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _rate = TextEditingController();
  final _taka = TextEditingController();
  final _name = TextEditingController();
  final _note = TextEditingController();
  String _currency = 'BDT';
  String _channel = 'bkash';
  int? _memberId;
  DateTime _date = DateTime.now();
  bool _takaEdited = false;
  bool _busy = false;
  String? _err;
  List<Map<String, dynamic>> _members = const [];
  late final String _clientId = '${widget.entry?['client_id'] ?? rmClientId()}';

  bool get _edit => widget.entry != null && widget.entry!['id'] != null;

  @override
  void initState() {
    super.initState();
    final e = widget.entry;
    if (e != null) {
      _amount.text = '${e['amount'] ?? ''}';
      _currency = '${e['currency'] ?? 'BDT'}';
      _rate.text = _currency == 'BDT' ? '' : '${e['rate'] ?? ''}';
      _taka.text = '${e['taka'] ?? ''}';
      _takaEdited = true;
      _channel = '${e['channel'] ?? 'other'}';
      _name.text = '${e['sender_name'] ?? ''}';
      _memberId = int.tryParse('${e['sender_member_id'] ?? ''}');
      _note.text = '${e['note'] ?? ''}';
      _date = DateTime.tryParse('${e['received_on'] ?? ''}') ?? DateTime.now();
    }
    _members = widget.members ?? const [];
    _rate.addListener(_recalc);
    _amount.addListener(_recalc);
    _initDefaults();
    if (widget.members == null) _loadMembers();
  }

  Future<void> _initDefaults() async {
    if (widget.entry != null) return;
    try {
      final c = await widget.source.getPref(kRmLastCurrency);
      final ch = await widget.source.getPref(kRmLastChannel);
      if (!mounted) return;
      setState(() {
        if (c != null && kRmCurrencies.contains(c)) _currency = c;
        if (ch != null && RemitParser.channels.contains(ch)) _channel = ch;
      });
    } catch (_) {}
    _applyDraft();
  }

  void _applyDraft() {
    final d = widget.draft;
    if (d == null || !mounted) return;
    final t = AppLocalizations.of(context);
    setState(() {
      if (d.amount != null) _amount.text = rmPlain(d.amount!);
      // No currency word: the sentence is about taka (a bKash / Nagad /
      // Rocket transfer always is) — never silently the last foreign one.
      _currency = d.currency ?? (d.amount != null ? 'BDT' : _currency);
      if (d.channel != null) _channel = d.channel!;
      if (d.rate != null) _rate.text = rmPlain(d.rate!);
      if (d.date != null) _date = d.date!;
      if (d.memberId != null) {
        _memberId = d.memberId;
        _name.text = d.memberName ?? '';
      } else if (d.relation != null) {
        _name.text = rmRelation(t, d.relation!);
      }
    });
    _recalc();
  }

  Future<void> _loadMembers() async {
    try {
      final m = await widget.source.members();
      if (mounted) setState(() => _members = m);
    } catch (_) {
      // offline: the sender can still be typed as a name
    }
  }

  void _recalc() {
    if (_takaEdited && _edit) return;
    final a = rmNum(_amount.text);
    if (_currency == 'BDT') {
      if (_taka.text != _amount.text) _taka.text = _amount.text;
      return;
    }
    final r = rmNum(_rate.text);
    if (a > 0 && r > 0 && !_takaEdited) {
      final v = (a * r * 100).round() / 100;
      _taka.text = rmPlain(v);
    }
  }

  @override
  void dispose() {
    for (final c in [_amount, _rate, _taka, _name, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d != null) setState(() => _date = d);
  }

  Map<String, dynamic> _body() => {
    'client_id': _clientId,
    'amount': _amount.text.trim(),
    'currency': _currency,
    'rate': _currency == 'BDT' ? '' : _rate.text.trim(),
    'taka': _currency == 'BDT' ? _amount.text.trim() : _taka.text.trim(),
    'channel': _channel,
    'sender_member_id': _memberId,
    'sender_name': _name.text.trim(),
    'note': _note.text.trim(),
    'received_on': rmIsoDay(_date),
    'source': widget.draft != null ? 'text' : 'manual',
  };

  Future<void> _save() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    final t = AppLocalizations.of(context);
    HapticFeedback.selectionClick();
    setState(() {
      _busy = true;
      _err = null;
    });
    final body = _body();
    try {
      if (_edit) {
        final b = Map<String, dynamic>.from(body)..remove('client_id');
        await widget.source.updateEntry(int.parse('${widget.entry!['id']}'), b);
      } else {
        await widget.source.createEntry(body);
      }
      await widget.source.setPref(kRmLastCurrency, _currency);
      await widget.source.setPref(kRmLastChannel, _channel);
      if (mounted) Navigator.of(context).pop(RemitSaved.online);
    } catch (e) {
      if (rmOffline(e) && !_edit) {
        await widget.queue.add('entry', body);
        if (mounted) Navigator.of(context).pop(RemitSaved.queued);
        return;
      }
      setState(() => _err = rmOffline(e) ? t.rmtNeedsInternet : (rmError(e) ?? t.rmtErrorBody));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.rmtDeleteEntryTitle),
        content: Text(t.rmtDeleteEntryBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: Text(t.cancel)),
          FilledButton(style: Brand.dangerButton(), onPressed: () => Navigator.pop(c, true), child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.source.deleteEntry(int.parse('${widget.entry!['id']}'));
      if (mounted) Navigator.of(context).pop(RemitSaved.deleted);
    } catch (e) {
      setState(() {
        _busy = false;
        _err = rmOffline(e) ? t.rmtNeedsInternet : (rmError(e) ?? t.rmtErrorBody);
      });
    }
  }

  String? _amountRule(String? v, AppLocalizations t) {
    final d = rmNum(v);
    if ((v ?? '').trim().isEmpty || d <= 0) return t.rmtErrAmount;
    if (d > 100000000) return t.rmtErrAmount;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final foreign = _currency != 'BDT';
    return Scaffold(
      appBar: AppBar(title: Text(_edit ? t.rmtEditEntryTitle : t.rmtAddEntryTitle)),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.md, Gap.lg, Gap.xxxl),
            children: [
              if (widget.draft != null) ...[
                Card(
                  key: const ValueKey('rmt_understood'),
                  color: scheme.secondaryContainer,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.draft!.isEmpty ? t.rmtNotUnderstood : t.rmtUnderstoodCheck,
                          style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w700),
                        ),
                        if ((widget.said ?? '').isNotEmpty)
                          Text('"${widget.said}"', style: TextStyle(color: scheme.onSecondaryContainer)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: Gap.md),
              ],
              Text(t.rmtFieldCurrency, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.xs),
              DropdownButtonFormField<String>(
                key: const ValueKey('rmt_currency'),
                initialValue: kRmCurrencies.contains(_currency) ? _currency : 'BDT',
                isExpanded: true,
                items: [
                  for (final c in kRmCurrencies)
                    DropdownMenuItem(
                      value: c,
                      child: Text(rmCurrency(t, c), overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _currency = v ?? 'BDT';
                  _takaEdited = false;
                  _recalc();
                }),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                key: const ValueKey('rmt_amount'),
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: foreign ? t.rmtFieldAmountForeign : t.rmtFieldAmountTaka,
                  helperText: foreign ? t.rmtFieldAmountForeignHelp : null,
                  helperMaxLines: 3,
                ),
                validator: (v) => _amountRule(v, t),
              ),
              if (foreign) ...[
                const SizedBox(height: Gap.md),
                TextFormField(
                  key: const ValueKey('rmt_rate'),
                  controller: _rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: t.rmtFieldRate,
                    helperText: t.rmtFieldRateHelp,
                    helperMaxLines: 3,
                  ),
                  validator: (v) {
                    final r = rmNum(v);
                    if ((v ?? '').trim().isEmpty) {
                      return rmNum(_taka.text) > 0 ? null : t.rmtErrRate;
                    }
                    return r <= 0 || r > 1000 ? t.rmtErrRate : null;
                  },
                ),
                const SizedBox(height: Gap.md),
                TextFormField(
                  key: const ValueKey('rmt_taka'),
                  controller: _taka,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => _takaEdited = true,
                  decoration: InputDecoration(
                    labelText: t.rmtFieldTaka,
                    helperText: t.rmtFieldTakaHelp,
                    helperMaxLines: 3,
                  ),
                  validator: (v) {
                    if ((v ?? '').trim().isEmpty) {
                      return rmNum(_rate.text) > 0 ? null : t.rmtErrAmount;
                    }
                    return rmNum(v) <= 0 ? t.rmtErrAmount : null;
                  },
                ),
              ],
              const SizedBox(height: Gap.lg),
              Text(t.rmtFieldChannel, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.xs),
              Wrap(
                spacing: Gap.sm,
                runSpacing: Gap.xs,
                children: [
                  for (final c in RemitParser.channels)
                    ChoiceChip(
                      key: ValueKey('rmt_ch_$c'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      showCheckmark: false,
                      avatar: Icon(rmChannelIcon(c), size: 18),
                      label: Text(rmChannel(t, c)),
                      selected: _channel == c,
                      onSelected: (_) => setState(() => _channel = c),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: Gap.xs),
                child: Text(t.rmtLegalOnly, style: Theme.of(context).textTheme.bodySmall),
              ),
              const SizedBox(height: Gap.lg),
              Text(t.rmtFieldSender, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.xs),
              if (_members.isNotEmpty)
                Wrap(
                  spacing: Gap.sm,
                  runSpacing: Gap.xs,
                  children: [
                    for (final m in _members)
                      ChoiceChip(
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        showCheckmark: false,
                        avatar: const Icon(Icons.diversity_3, size: 18),
                        label: Text('${m['name'] ?? ''}'),
                        selected: _memberId != null && '$_memberId' == '${m['id']}',
                        onSelected: (sel) => setState(() {
                          _memberId = sel ? int.tryParse('${m['id']}') : null;
                          if (sel) _name.text = '${m['name'] ?? ''}';
                        }),
                      ),
                  ],
                ),
              TextFormField(
                key: const ValueKey('rmt_sender'),
                controller: _name,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: _members.isEmpty ? t.rmtFieldSenderName : t.rmtFieldSenderOther,
                  helperText: _members.isEmpty ? t.rmtFieldSenderHelp : null,
                  helperMaxLines: 3,
                ),
                onChanged: (_) {
                  if (_memberId != null) setState(() => _memberId = null);
                },
              ),
              const SizedBox(height: Gap.sm),
              Text(t.rmtFieldDate, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Gap.xs),
              OutlinedButton.icon(
                key: const ValueKey('rmt_date'),
                style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48), alignment: Alignment.centerLeft),
                onPressed: _pickDate,
                icon: const Icon(Icons.event_rounded),
                label: Text(rmDay(context, rmIsoDay(_date))),
              ),
              const SizedBox(height: Gap.md),
              TextFormField(
                key: const ValueKey('rmt_note'),
                controller: _note,
                maxLength: 200,
                decoration: InputDecoration(labelText: t.rmtFieldNote),
              ),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Gap.sm),
                  child: Text(_err!, style: TextStyle(color: scheme.error)),
                ),
              FilledButton.icon(
                key: const ValueKey('rmt_save'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                onPressed: _busy ? null : _save,
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check_rounded),
                label: Text(t.rmtSave),
              ),
              if (_edit) ...[
                const SizedBox(height: Gap.sm),
                TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size.fromHeight(48), foregroundColor: scheme.error),
                  onPressed: _busy ? null : _delete,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: Text(t.rmtDeleteEntry),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
