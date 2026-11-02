import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import 'rn_bits.dart' show pickCircleMember;

/// moneybar: "Pick from My Circle" inside the money tools' add-person sheets
/// (split, mess, samity, domestic staff, house rent) — nobody's name or
/// number is typed twice. Fills the given controllers; never saves anything
/// by itself (the user still taps Save). An empty / unreachable Circle is
/// handled by the shared picker (honest message + retry).
class CirclePickButton extends StatelessWidget {
  const CirclePickButton({
    super.key,
    required this.name,
    this.phone,
    this.onPicked,
  });
  final TextEditingController name;
  final TextEditingController? phone;
  final VoidCallback? onPicked;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        key: const ValueKey('mb-circle-pick'),
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.diversity_1_rounded),
        label: Text(t.mbCirclePick),
        onPressed: () async {
          final r = await pickCircleMember(context,
              title: t.mbCirclePick, subtitle: t.mbCirclePickSub);
          if (r == null) return;
          final n = '${r['name'] ?? ''}'.trim();
          if (n.isNotEmpty) name.text = n;
          final p = '${r['phone'] ?? ''}'.trim();
          if (phone != null && p.isNotEmpty) phone!.text = p;
          onPicked?.call();
        },
      ),
    );
  }
}
