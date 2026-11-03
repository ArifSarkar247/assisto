import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../theme.dart';

/// e-gaps / circlemedia: the round "1" (view once) toggle that sits right
/// next to Send on the photo / album preview. Shared so every preview shows
/// the same control; what happens after Send is the view-once code's job.
class ViewOnceToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const ViewOnceToggle({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Tooltip(
      message: value ? t.eVoOnHint : t.eVoToggle,
      child: Semantics(
        button: true,
        toggled: value,
        label: t.eVoToggle,
        child: InkWell(
          key: const Key('e-vo-toggle'),
          customBorder: const CircleBorder(),
          onTap: () {
            onChanged(!value);
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
                duration: const Duration(seconds: 2),
                content: Text(!value ? t.eVoOnHint : t.eVoOffHint)));
          },
          child: Container(
            width: kMinTap, // a11y1: was 44
            height: kMinTap,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value ? Colors.white : Colors.white12,
            ),
            child: Text('1',
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: value ? Colors.black : Colors.white)),
          ),
        ),
      ),
    );
  }
}
