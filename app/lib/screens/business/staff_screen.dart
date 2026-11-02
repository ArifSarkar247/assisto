import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api.dart' show ApiException;
import '../../l10n/app_localizations.dart';
import '../../services/action_feedback.dart' show showActionFailed, showNeedInput;
import '../../services/error_kind.dart' show honestFailText;
import '../../state.dart';
import '../../theme.dart';
import '../../widgets/app_sheet.dart';
import '../../widgets/cv_empty.dart' show pickCirclePerson;
import '../../widgets/skeleton.dart';

/// bizbar: one shop on several phones. The owner adds a staff member (an
/// Assisto user) by number or from My Circle in one tap; staff then find the
/// shop under Business -> Switch shop. Staff write sales, dues and the
/// cashbox but never see cost, minimum price, profit or the supplier book
/// (server-enforced). TallyKhata's 4-year-old complaint is "one phone only".
class StaffScreen extends StatefulWidget {
  final int businessId;
  const StaffScreen({super.key, required this.businessId});
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  Object? _fail;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _rows.isEmpty;
      _fail = null;
    });
    try {
      final r = await context
          .read<AppState>()
          .api
          .getJson('/business/staff?business=${widget.businessId}');
      _rows = ((r['staff'] ?? const []) as List)
          .whereType<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
    } catch (e) {
      _fail = e;
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _add(String phone) async {
    final t = AppLocalizations.of(context);
    if (phone.trim().isEmpty) {
      showNeedInput(context);
      return;
    }
    setState(() => _busy = true);
    try {
      await context.read<AppState>().api.postJson('/business/staff',
          {'business': widget.businessId, 'phone': phone.trim()});
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t.bbStaffAdded)));
      }
      await _load();
    } catch (e) {
      if (!mounted) return;
      // the server's own sentence for "not on Assisto" / limits
      if (e is ApiException && e.status != null && e.status! < 500) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      } else {
        showActionFailed(context, 'staff.add', e);
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _fromCircle() async {
    final t = AppLocalizations.of(context);
    final p = await pickCirclePerson(context, title: t.bbStaffPickTitle);
    final phone = '${p?['phone'] ?? ''}';
    if (p != null && mounted) await _add(phone);
  }

  Future<void> _byNumber() async {
    final t = AppLocalizations.of(context);
    final ctrl = TextEditingController();
    final phone = await showAppSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            Gap.lg, 0, Gap.lg, MediaQuery.of(ctx).viewInsets.bottom + Gap.lg),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t.bbStaffByNumber, style: Theme.of(ctx).textTheme.titleMedium),
          const SizedBox(height: Gap.md),
          TextField(
            key: const ValueKey('bb-staff-phone'),
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
                labelText: t.phone, prefixIcon: const Icon(Icons.call_rounded)),
          ),
          const SizedBox(height: Gap.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text),
                child: Text(t.bbStaffAdd)),
          ),
        ]),
      ),
    );
    ctrl.dispose();
    if (phone != null && mounted) await _add(phone);
  }

  Future<void> _remove(Map<String, dynamic> m) async {
    final t = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.bbStaffRemoveQ('${m['name'] ?? ''}')),
        content: Text(t.bbStaffRemoveBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t.cancel)),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true), child: Text(t.bbStaffRemove)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context
          .read<AppState>()
          .api
          .postJson('/business/staff/${m['id']}/remove', {'business': widget.businessId});
      await _load();
    } catch (e) {
      if (mounted) showActionFailed(context, 'staff.remove', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget addButtons() => Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: [
          FilledButton.icon(
            key: const ValueKey('bb-staff-circle'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _fromCircle,
            icon: const Icon(Icons.people_alt_rounded),
            label: Text(t.bbStaffFromCircle),
          ),
          OutlinedButton.icon(
            key: const ValueKey('bb-staff-number'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: _busy ? null : _byNumber,
            icon: const Icon(Icons.dialpad_rounded),
            label: Text(t.bbStaffByNumber),
          ),
        ]);
    Widget body;
    if (_loading) {
      body = const SkeletonList();
    } else if (_fail != null) {
      body = StateMessage(
        icon: Icons.cloud_off_rounded,
        title: t.bbStaffTitle,
        message: honestFailText(t, _fail),
        action: FilledButton(onPressed: _load, child: Text(t.retry)),
      );
    } else {
      body = ListView(
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(t.bbStaffBenefit, style: AType.bodyLarge),
          const SizedBox(height: Gap.sm),
          Text(t.bbStaffHow, style: AType.bodySmall.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.lg),
          addButtons(),
          const SizedBox(height: Gap.lg),
          if (_rows.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.lg),
              child: Text(t.bbStaffNone,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            )
          else
            for (final m in _rows)
              Card(
                child: ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.badge_rounded)),
                  title: Text('${m['name'] ?? ''}'),
                  subtitle: Text('${m['phone_masked'] ?? ''}'),
                  trailing: IconButton(
                    tooltip: t.bbStaffRemove,
                    icon: Icon(Icons.person_remove_rounded, color: scheme.error),
                    onPressed: () => _remove(m),
                  ),
                ),
              ),
        ],
      );
    }
    return Scaffold(appBar: AppBar(title: Text(t.bbStaffTitle)), body: body);
  }
}
