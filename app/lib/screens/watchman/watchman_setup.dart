import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';

/// cctv1 first-time wizard: 1) home or shop → 2) gateway (old Android phone /
/// Shop Box PC / existing PC) → 3) name → the place is created and the
/// caller shows the pairing sheet. Pops with the new site row (or null).
class WatchmanSetupScreen extends StatefulWidget {
  final WatchmanSource source;
  final bool canShop;

  /// Gallery/tests: open on this step.
  final int initialStep;
  const WatchmanSetupScreen({super.key, required this.source, required this.canShop, this.initialStep = 0});

  @override
  State<WatchmanSetupScreen> createState() => _WatchmanSetupScreenState();
}

class _WatchmanSetupScreenState extends State<WatchmanSetupScreen> {
  late int _step = widget.initialStep;
  String _kind = 'home';
  String _gateway = 'phone';
  final _name = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final site = await widget.source.setup(_kind, _gateway, _name.text.trim());
      if (mounted) Navigator.of(context).pop(site);
      return;
    } catch (e) {
      _error = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final titles = [t.wmStepKind, t.wmStepGateway, t.wmStepName];
    return Scaffold(
      appBar: AppBar(
        title: Text(t.wmSetupTitle),
        leading: _step == 0
            ? null
            : IconButton(
                tooltip: t.wmBack,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: _busy ? null : () => setState(() => _step--)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text(t.wmStepOf(wmDigits(lang, _step + 1), wmDigits(lang, 3)),
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(titles[_step], style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          ..._stepBody(t),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            onPressed: _busy || (_step == 0 && _kind == 'shop' && !widget.canShop)
                ? null
                : () {
                    if (_step < 2) {
                      setState(() => _step++);
                    } else {
                      _create();
                    }
                  },
            child: _busy
                ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                : Text(_step < 2 ? t.wmNext : t.wmCreatePlace),
          ),
        ],
      ),
    );
  }

  List<Widget> _stepBody(AppLocalizations t) {
    switch (_step) {
      case 0:
        return [
          _Choice(
            icon: Icons.home_rounded,
            title: t.wmKindHome,
            body: t.wmKindHomeBody,
            selected: _kind == 'home',
            onTap: () => setState(() => _kind = 'home'),
          ),
          _Choice(
            icon: Icons.storefront_rounded,
            title: t.wmKindShop,
            body: widget.canShop ? t.wmKindShopBody : t.wmKindShopNeedsBusiness,
            selected: _kind == 'shop',
            onTap: () => setState(() => _kind = 'shop'),
          ),
        ];
      case 1:
        return [
          _Choice(
            icon: Icons.phone_android_rounded,
            title: t.wmGwPhone,
            body: t.wmGwPhoneBody,
            selected: _gateway == 'phone',
            onTap: () => setState(() => _gateway = 'phone'),
          ),
          _Choice(
            icon: Icons.dns_rounded,
            title: t.wmGwShopbox,
            body: t.wmGwShopboxBody,
            selected: _gateway == 'shopbox',
            onTap: () => setState(() => _gateway = 'shopbox'),
          ),
          _Choice(
            icon: Icons.computer_rounded,
            title: t.wmGwPc,
            body: t.wmGwPcBody,
            selected: _gateway == 'pc',
            onTap: () => setState(() => _gateway = 'pc'),
          ),
          const SizedBox(height: 4),
          Text(t.wmGwWhy, style: Theme.of(context).textTheme.bodySmall),
        ];
      default:
        return [
          TextField(
            controller: _name,
            maxLength: 60,
            decoration: InputDecoration(
              labelText: t.wmPlaceName,
              hintText: _kind == 'home' ? t.wmPlaceNameHomeHint : t.wmPlaceNameShopHint,
              border: const OutlineInputBorder(),
            ),
          ),
          Text(t.wmRetentionNote, style: Theme.of(context).textTheme.bodySmall),
        ];
    }
  }
}

class _Choice extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final bool selected;
  final VoidCallback onTap;
  const _Choice({required this.icon, required this.title, required this.body, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
              ),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(icon, color: selected ? scheme.onPrimaryContainer : scheme.onSurface),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title,
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: selected ? scheme.onPrimaryContainer : scheme.onSurface)),
                    const SizedBox(height: 2),
                    Text(body,
                        style: TextStyle(color: selected ? scheme.onPrimaryContainer : scheme.onSurface)),
                  ]),
                ),
                if (selected) Icon(Icons.check_circle_rounded, color: scheme.primary),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
