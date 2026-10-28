import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../bizagent_api.dart';
import '../../../l10n/app_localizations.dart';
import '../../../state.dart';
import '../../../theme.dart';
import '../../../widgets/business_ui.dart';
import '../../../widgets/skeleton.dart';
import 'seller_agent_screen.dart'
    show asciiDigits, baChannelIcon, baChannelLabel, baErrorText, bd;
import 'package:assisto/widgets/app_sheet.dart';

/// P1 — seller onboarding for the AI agent.
///
/// 1. Channels: Facebook Page (Messenger + comments), Instagram, WhatsApp
///    Business (Cloud API). Until Meta's App Review passes, a Page / WhatsApp
///    access token is pasted with honest step-by-step help; the server checks
///    it with Meta and shows the real status.
/// 2. Catalog check (the AI only ever uses these prices / stock).
/// 3. Delivery charges inside / outside Dhaka (+ free over).
/// 4. Policies: returns, payment (cash on delivery; payment link ONLY via a
///    licensed partner — we never hold money).
/// 5. AI: tone, business hours, approve every reply, alerts.
/// 6. Courier merchant keys (Pathao / Steadfast / RedX), stored encrypted.
class SellerSetupScreen extends StatefulWidget {
  const SellerSetupScreen({super.key});
  @override
  State<SellerSetupScreen> createState() => _SellerSetupScreenState();
}

const _courierFields = {
  'pathao': ['client_id', 'client_secret', 'username', 'password', 'store_id'],
  'steadfast': ['api_key', 'secret_key'],
  'redx': ['access_token', 'pickup_store_id'],
};
const _secretFields = {'client_secret', 'password', 'api_key', 'secret_key', 'access_token'};

class _SellerSetupScreenState extends State<SellerSetupScreen> {
  bool _loading = true;
  Object? _error;
  bool _saving = false;
  Map<String, dynamic> _s = const {};

  final _inside = TextEditingController();
  final _outside = TextEditingController();
  final _freeOver = TextEditingController();
  final _returns = TextEditingController();
  String _tone = 'friendly';
  bool _approveAll = false;
  bool _cod = true;
  bool _payLink = false;
  bool _lowStock = true;
  bool _daily = true;
  bool _always = true;
  TimeOfDay _start = const TimeOfDay(hour: 10, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 22, minute: 0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [_inside, _outside, _freeOver, _returns]) {
      c.dispose();
    }
    super.dispose();
  }

  TimeOfDay? _parse(Object? v) {
    final p = '${v ?? ''}'.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]), m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  String _hm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final s = await context.read<AppState>().api.bizAgentSetup();
      final st = (s['settings'] as Map?) ?? const {};
      _inside.text = bd(context, st['delivery_inside'] ?? '');
      _outside.text = bd(context, st['delivery_outside'] ?? '');
      _freeOver.text = bd(context, st['free_over'] ?? '');
      _returns.text = '${st['returns'] ?? ''}';
      _tone = '${st['tone'] ?? 'friendly'}';
      _approveAll = st['approve_all'] == true;
      _cod = st['cod_enabled'] != false;
      _payLink = st['payment_link_enabled'] == true;
      _lowStock = st['low_stock_alert'] != false;
      _daily = st['daily_report'] != false;
      final h = (st['hours'] as Map?) ?? const {};
      final a = _parse(h['start']), b = _parse(h['end']);
      _always = a == null || b == null;
      if (a != null) _start = a;
      if (b != null) _end = b;
      if (!mounted) return;
      setState(() {
        _s = s;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _snack(String m) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(bd(context, m))));

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    setState(() => _saving = true);
    try {
      await context.read<AppState>().api.bizAgentSaveSettings({
        'tone': _tone,
        'approve_all': _approveAll,
        'cod_enabled': _cod,
        'payment_link_enabled': _payLink,
        'low_stock_alert': _lowStock,
        'daily_report': _daily,
        'hours': _always ? <String, String>{} : {'start': _hm(_start), 'end': _hm(_end)},
        'delivery_inside': _inside.text.trim().isEmpty ? '0' : asciiDigits(_inside.text.trim()),
        'delivery_outside': _outside.text.trim().isEmpty ? '0' : asciiDigits(_outside.text.trim()),
        'free_over': asciiDigits(_freeOver.text.trim()),
        'returns': _returns.text.trim(),
      });
      _snack(t.baSaved);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    if (mounted) setState(() => _saving = false);
  }

  Future<void> _pickTime(bool start) async {
    final v = await showTimePicker(context: context, initialTime: start ? _start : _end);
    if (v != null && mounted) setState(() => start ? _start = v : _end = v);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.baSetupTitle)),
      body: _body(t),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(Gap.lg, Gap.sm, Gap.lg, Gap.md),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: const Icon(Icons.save_rounded),
                  label: Text(t.baSaveSettings),
                ),
              ),
            ),
    );
  }

  Widget _body(AppLocalizations t) {
    if (_loading) return const SkeletonList();
    if (_error != null) {
      return StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bizLoadFailed,
        message: baErrorText(t, _error!),
        action: FilledButton(onPressed: _load, child: Text(t.bizRetry)),
      );
    }
    return ListView(padding: const EdgeInsets.all(Gap.lg), children: [
      _channelsCard(t),
      const SizedBox(height: Gap.md),
      _catalogCard(t),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.baDeliveryTitle,
        icon: Icons.local_shipping_rounded,
        child: Column(children: [
          _money(_inside, t.baDeliveryInside),
          const SizedBox(height: Gap.sm),
          _money(_outside, t.baDeliveryOutside),
          const SizedBox(height: Gap.sm),
          _money(_freeOver, t.baFreeOver),
        ]),
      ),
      const SizedBox(height: Gap.md),
      BizCard(
        title: t.baPoliciesTitle,
        icon: Icons.policy_rounded,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _returns,
            minLines: 2,
            maxLines: 4,
            decoration: InputDecoration(
                labelText: t.baReturnPolicy, hintText: t.baReturnPolicyHint,
                border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _cod,
            title: Text(t.baCod),
            onChanged: (v) => setState(() => _cod = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _payLink,
            title: Text(t.baPayLink),
            subtitle: Text(t.baPayLinkSub),
            onChanged: (v) => setState(() => _payLink = v),
          ),
        ]),
      ),
      const SizedBox(height: Gap.md),
      _aiCard(t),
      const SizedBox(height: Gap.md),
      _couriersCard(t),
      const SizedBox(height: Gap.xl),
    ]);
  }

  Widget _money(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
            labelText: label, prefixText: '৳ ', border: const OutlineInputBorder()),
      );

  Widget _channelsCard(AppLocalizations t) {
    final chans = ((_s['channels'] as List?) ?? const []).cast<Map>();
    final kill = (_s['kill'] as Map?) ?? const {};
    return BizCard(
      title: t.baChannelsTitle,
      icon: Icons.hub_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.baChannelsBody, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.sm),
        for (final c in chans) _channelRow(t, c, kill['${c['kind']}'] == true),
        const SizedBox(height: Gap.sm),
        // biz-v2: Page / WhatsApp connect only while the server's Meta app
        // is configured (features.own_channels) — hidden, not "coming soon".
        if (((_s['features'] as Map?) ?? const {})['own_channels'] != false)
        Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          for (final k in const ['messenger', 'instagram', 'whatsapp_cloud'])
            OutlinedButton.icon(
              onPressed: () => _connect(k),
              icon: Icon(baChannelIcon(k), size: 18),
              label: Text(t.baConnectX(baChannelLabel(t, k))),
            ),
        ]),
        const SizedBox(height: Gap.sm),
        BizNote(text: t.baOfficialOnly, icon: Icons.verified_rounded),
      ]),
    );
  }

  Widget _channelRow(AppLocalizations t, Map c, bool killed) {
    final ok = c['status'] == 'connected';
    final detail = '${c['status_detail'] ?? ''}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(baChannelIcon('${c['kind']}')),
      title: Text(bd(context, c['display_name'] ?? c['external_id']), maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: Text(bd(context,
        killed
            ? t.baChannelPausedByAssisto
            : ok
                ? (c['enabled'] == true ? t.baConnected : t.baChannelOff)
                : (detail.isNotEmpty ? t.baConnectError(detail) : t.baNotConnected)),
      ),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        // a11y1: TalkBack reads which channel the switch turns on/off.
        MergeSemantics(
          child: Semantics(
            label: bd(context, c['display_name'] ?? c['external_id']),
            child: Switch(
              value: c['enabled'] == true,
              onChanged: (v) => _toggle((c['id'] as num).toInt(), v),
            ),
          ),
        ),
        IconButton(
          tooltip: t.baDisconnect,
          icon: const Icon(Icons.link_off_rounded),
          onPressed: () => _disconnect((c['id'] as num).toInt()),
        ),
      ]),
    );
  }

  Future<void> _toggle(int id, bool on) async {
    final t = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.bizAgentToggleChannel(id, on);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
  }

  Future<void> _disconnect(int id) async {
    final t = AppLocalizations.of(context);
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true, // insets: 200% text / keyboard
        title: Text(t.baDisconnectQ),
        content: Text(t.baDisconnectBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t.baDisconnect)),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await context.read<AppState>().api.bizAgentDeleteChannel(id);
    } catch (e) {
      _snack(baErrorText(t, e));
    }
    await _load();
  }

  Future<void> _connect(String kind) async {
    final t = AppLocalizations.of(context);
    final res = await showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ConnectSheet(kind: kind),
    );
    if (res == null || !mounted) return;
    final ch = (res['channel'] as Map?) ?? const {};
    _snack(ch['status'] == 'connected'
        ? t.baConnectedOk
        : t.baConnectError('${ch['status_detail'] ?? ''}'));
    await _load();
  }

  Widget _catalogCard(AppLocalizations t) {
    final c = (_s['catalog'] as Map?) ?? const {};
    final n = (c['products'] as num?)?.toInt() ?? 0;
    final missing = ((c['missing_price'] as List?) ?? const []).cast<Object>();
    final low = ((c['low_stock'] as List?) ?? const []).cast<Map>();
    return BizCard(
      title: t.baCatalogTitle,
      icon: Icons.inventory_2_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(bd(context, t.baCatalogLine(n, (c['priced'] as num?)?.toInt() ?? 0,
            (c['in_stock'] as num?)?.toInt() ?? 0))),
        if (n == 0) ...[
          const SizedBox(height: Gap.sm),
          BizNote(text: t.baCatalogEmpty, icon: Icons.warning_amber_rounded, tint: AssistoTokens.of(context).warning),
        ],
        if (missing.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          BizNote(text: bd(context, t.baCatalogMissingPrice(missing.join(', '))),
              icon: Icons.warning_amber_rounded, tint: AssistoTokens.of(context).warning),
        ],
        if (low.isNotEmpty) ...[
          const SizedBox(height: Gap.sm),
          Text(t.baLowStockTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
          for (final x in low.take(5))
            Text(bd(context, t.baLowStockLine('${x['name']}', (x['stock'] as num?)?.toInt() ?? 0))),
        ],
        const SizedBox(height: Gap.sm),
        BizNote(text: t.baCatalogTruth, icon: Icons.price_check_rounded),
      ]),
    );
  }

  Widget _aiCard(AppLocalizations t) {
    return BizCard(
      title: t.baAiTitle,
      icon: Icons.smart_toy_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.baTone, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: Gap.sm),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'friendly', label: Text(t.baToneFriendly)),
            ButtonSegment(value: 'formal', label: Text(t.baToneFormal)),
            ButtonSegment(value: 'short', label: Text(t.baToneShort)),
          ],
          selected: {_tone},
          onSelectionChanged: (v) => setState(() => _tone = v.first),
        ),
        const SizedBox(height: Gap.md),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _always,
          title: Text(t.baHoursAlways),
          subtitle: Text(t.baHoursSub),
          onChanged: (v) => setState(() => _always = v),
        ),
        if (!_always)
          Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
            OutlinedButton.icon(
              onPressed: () => _pickTime(true),
              icon: const Icon(Icons.schedule_rounded, size: 18),
              label: Text(bd(context, t.baHoursFrom(_hm(_start)))),
            ),
            OutlinedButton.icon(
              onPressed: () => _pickTime(false),
              icon: const Icon(Icons.schedule_rounded, size: 18),
              label: Text(bd(context, t.baHoursTo(_hm(_end)))),
            ),
          ]),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _approveAll,
          title: Text(t.baApproveAll),
          subtitle: Text(t.baApproveAllSub),
          onChanged: (v) => setState(() => _approveAll = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _lowStock,
          title: Text(t.baLowStockAlert),
          onChanged: (v) => setState(() => _lowStock = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _daily,
          title: Text(t.baDailyReport),
          onChanged: (v) => setState(() => _daily = v),
        ),
        BizNote(text: t.baRiskyNote, icon: Icons.shield_rounded),
      ]),
    );
  }

  Widget _couriersCard(AppLocalizations t) {
    final cs = (_s['couriers'] as Map?) ?? const {};
    return BizCard(
      title: t.baCouriersTitle,
      icon: Icons.local_shipping_rounded,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.baCouriersBody, style: const TextStyle(height: 1.4)),
        for (final c in _courierFields.keys)
          _CourierTile(
            courier: c,
            connected: ((cs[c] as Map?) ?? const {})['connected'] == true,
            onSaved: _load,
          ),
      ]),
    );
  }
}

String _courierName(AppLocalizations t, String c) =>
    c == 'pathao' ? t.baPathao : (c == 'steadfast' ? t.baSteadfast : t.baRedx);

String _fieldLabel(AppLocalizations t, String f) {
  switch (f) {
    case 'client_id':
      return t.baFClientId;
    case 'client_secret':
      return t.baFClientSecret;
    case 'username':
      return t.baFUsername;
    case 'password':
      return t.baFPassword;
    case 'store_id':
      return t.baFStoreId;
    case 'api_key':
      return t.baFApiKey;
    case 'secret_key':
      return t.baFSecretKey;
    case 'access_token':
      return t.baFAccessToken;
    case 'pickup_store_id':
      return t.baFPickupStore;
    default:
      return f;
  }
}

class _CourierTile extends StatefulWidget {
  final String courier;
  final bool connected;
  final Future<void> Function() onSaved;
  const _CourierTile({required this.courier, required this.connected, required this.onSaved});
  @override
  State<_CourierTile> createState() => _CourierTileState();
}

class _CourierTileState extends State<_CourierTile> {
  late final Map<String, TextEditingController> _c = {
    for (final f in _courierFields[widget.courier]!) f: TextEditingController()
  };
  bool _busy = false;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final t = AppLocalizations.of(context);
    final body = {for (final e in _c.entries) if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim()};
    if (body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.baKeysEmpty)));
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.bizAgentSaveCourier(widget.courier, body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t.baKeysSaved)));
      for (final c in _c.values) {
        c.clear();
      }
      await widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(bd(context, baErrorText(t, e)))));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text(_courierName(t, widget.courier)),
      subtitle: Text(widget.connected ? t.baConnected : t.baNotConnected),
      children: [
        for (final e in _c.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.sm),
            child: TextField(
              controller: e.value,
              obscureText: _secretFields.contains(e.key),
              autocorrect: false,
              decoration: InputDecoration(
                  labelText: _fieldLabel(t, e.key), border: const OutlineInputBorder()),
            ),
          ),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: FilledButton.tonal(
              onPressed: _busy ? null : _save, child: Text(t.baSaveKeys)),
        ),
        const SizedBox(height: Gap.sm),
      ],
    );
  }
}

/// Connect one channel: honest steps + ID + access token. The server checks
/// the token with Meta (Graph API) and returns the real status.
class _ConnectSheet extends StatefulWidget {
  final String kind;
  const _ConnectSheet({required this.kind});
  @override
  State<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends State<_ConnectSheet> {
  final _id = TextEditingController();
  final _token = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _id.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final t = AppLocalizations.of(context);
    final id = _id.text.trim();
    if (!RegExp(r'^\d{3,32}$').hasMatch(id) || _token.text.trim().isEmpty) {
      setState(() => _err = t.baConnectFieldsErr);
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .bizAgentConnect(widget.kind, id, _token.text.trim());
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _err = baErrorText(t, e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final wa = widget.kind == 'whatsapp_cloud';
    final ig = widget.kind == 'instagram';
    final steps = wa ? t.baStepsWhatsapp : (ig ? t.baStepsInstagram : t.baStepsPage);
    return Padding(
      padding: EdgeInsets.only(
          left: Gap.lg, right: Gap.lg,
          bottom: MediaQuery.of(context).viewInsets.bottom + Gap.lg),
      child: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(t.baConnectX(baChannelLabel(t, widget.kind)),
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.sm),
          Text(steps, style: const TextStyle(height: 1.5)),
          const SizedBox(height: Gap.md),
          TextField(
            controller: _id,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: wa ? t.baPhoneNumberId : (ig ? t.baIgAccountId : t.baPageId),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: Gap.sm),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: InputDecoration(
                labelText: t.baAccessToken, border: const OutlineInputBorder()),
          ),
          if (_err != null) ...[
            const SizedBox(height: Gap.sm),
            Text(bd(context, _err!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: _busy ? null : _go, child: Text(t.baConnectCheck)),
          ),
          const SizedBox(height: Gap.sm),
          BizNote(text: t.baTokenSafe, icon: Icons.lock_outline_rounded),
        ]),
      ),
    );
  }
}
