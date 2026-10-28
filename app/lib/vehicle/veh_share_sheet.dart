import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_localizations.dart';
import '../state.dart';
import '../theme.dart';
import 'veh_format.dart';
import 'vehicle_api.dart';

/// veh100: share a vehicle's LIVE location as a link (lifeassisto.com/v/...).
/// Anyone with the link sees only the current position (never the route
/// history) until it expires or the owner turns it off. The full link is
/// shown ONCE, right after it is made (the server keeps only a hash).
class VehShareSheet extends StatefulWidget {
  final int trackerId;
  final bool paired;
  const VehShareSheet({super.key, required this.trackerId, this.paired = true});

  @override
  State<VehShareSheet> createState() => _VehShareSheetState();
}

class _VehShareSheetState extends State<VehShareSheet> {
  List<Map<String, dynamic>> _links = const [];
  List<int> _hours = const [1, 4, 8, 24, 72];
  int _pick = 8;
  final _label = TextEditingController();
  bool _loading = true, _busy = false;
  String? _err;
  String? _newUrl;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.vehShares(widget.trackerId);
      _links = vehList(r['links']);
      final h = r['hours'];
      if (h is List && h.isNotEmpty) _hours = [for (final x in h) vehInt(x) ?? 1];
      _err = null;
    } catch (e) {
      if (mounted) _err = vehReasonText(AppLocalizations.of(context), e);
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _create() async {
    final tr = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .vehShareCreate(widget.trackerId, _pick, label: _label.text.trim());
      _newUrl = '${vehMap(r['link'])['url'] ?? ''}';
      await _load();
    } catch (e) {
      _err = vehReasonText(tr, e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _revoke(int id) async {
    final tr = AppLocalizations.of(context);
    try {
      await context.read<AppState>().api.vehShareRevoke(widget.trackerId, id);
      await _load();
      _snack(tr.v100ShareRevoked);
    } catch (e) {
      _snack(vehReasonText(tr, e));
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  String _hoursLabel(AppLocalizations tr, int h) =>
      h < 24 ? tr.v100Hours(vehNumStr(context, h)) : tr.v100Days(vehNumStr(context, h ~/ 24));

  @override
  Widget build(BuildContext context) {
    final tr = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final active = _links.where((l) => l['state'] == 'active').toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(tr.v100ShareTitle, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Gap.xs),
          Text(tr.v100SharePrivacy,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.35)),
          const SizedBox(height: Gap.md),
          if (!widget.paired)
            Text(tr.v100ShareNeedsPaired, style: TextStyle(color: scheme.error))
          else ...[
            Text(tr.v100ShareHowLong, style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: Gap.xs),
            Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
              for (final h in _hours)
                ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(_hoursLabel(tr, h)),
                  selected: _pick == h,
                  onSelected: (_) => setState(() => _pick = h),
                ),
            ]),
            const SizedBox(height: Gap.sm),
            TextField(
              controller: _label,
              maxLength: 40,
              decoration: InputDecoration(
                  labelText: tr.v100ShareLabel, helperText: tr.v100ShareLabelHelp),
            ),
            FilledButton.icon(
              key: const ValueKey('veh-share-create'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _busy ? null : _create,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.add_link_rounded),
              label: Text(tr.v100ShareCreate),
            ),
          ],
          if (_err != null) ...[
            const SizedBox(height: Gap.sm),
            Text(_err!, style: TextStyle(color: scheme.error, fontWeight: FontWeight.w600)),
          ],
          if (_newUrl != null && _newUrl!.isNotEmpty) ...[
            const SizedBox(height: Gap.md),
            Card(
              color: scheme.primaryContainer,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(Gap.md),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Text(tr.v100ShareReady, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.xs),
                  SelectableText(_newUrl!,
                      style: AType.bodyMedium.copyWith(fontFamily: 'monospace')),
                  const SizedBox(height: Gap.xs),
                  Text(tr.v100ShareOnce,
                      style: AType.bodySmall.copyWith(color: scheme.onPrimaryContainer)),
                  const SizedBox(height: Gap.sm),
                  Wrap(spacing: Gap.sm, runSpacing: Gap.xs, children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: _newUrl!));
                        _snack(tr.vehCopied);
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: Text(tr.vehCopy),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => Share.share(tr.v100ShareMessage(_newUrl!)),
                      icon: const Icon(Icons.send_rounded),
                      label: Text(tr.v100ShareSend),
                    ),
                  ]),
                ]),
              ),
            ),
          ],
          const SizedBox(height: Gap.md),
          Text(tr.v100ShareActive, style: Theme.of(context).textTheme.titleMedium),
          if (_loading)
            const Padding(
                padding: EdgeInsets.all(Gap.md),
                child: Center(child: CircularProgressIndicator()))
          else if (active.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(tr.v100ShareNone, style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            for (final l in active)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_rounded),
                title: Text(
                    '${l['label'] ?? ''}'.trim().isEmpty
                        ? tr.v100ShareUnnamed
                        : '${l['label']}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  tr.v100ShareUntil(vehDateTime(context, vehDate(l['expires_at'])),
                      vehNumStr(context, vehInt(l['views']) ?? 0)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => _revoke(vehInt(l['id']) ?? 0),
                  child: Text(tr.v100ShareTurnOff),
                ),
              ),
        ]),
      ),
    );
  }
}
