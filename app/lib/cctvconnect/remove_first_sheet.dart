// imou-real (owner 17 Nov): "remove it from the vendor app first" — shown
// BEFORE the serial + code sheet while the vendor's no-delete path (Imou
// OAuth, Dahua DMSS share) is not approved. A camera sits in ONE cloud
// account, so a camera still in Imou Life / EZVIZ / DMSS fails to link with
// a confusing "bound by others". Each step has our OWN simple drawing of the
// vendor screen (never a copied vendor screenshot) and plain words.
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../screens/watchman/watchman_source.dart' show wmDigits;
import '../screens/watchman/watchman_widgets.dart' show wmLang;
import '../theme.dart';
import '../widgets/app_sheet.dart';

/// The guide ids the server sends as `before` (cctv_connect_views.REMOVE_FIRST).
const kRemoveFirstGuides = {'imou_life', 'ezviz_app', 'dmss'};

/// Shows the guide; true = the user removed it (or never added it) and
/// wants to go on to the serial + code sheet.
Future<bool> showRemoveFirstSheet(BuildContext context, String guide) async {
  if (!kRemoveFirstGuides.contains(guide)) return true;
  final ok = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => CctvRemoveFirstSheet(guide: guide),
  );
  return ok == true;
}

class _Step {
  final String text;
  final _Sketch sketch;
  const _Step(this.text, this.sketch);
}

class CctvRemoveFirstSheet extends StatelessWidget {
  final String guide;
  const CctvRemoveFirstSheet({super.key, required this.guide});

  List<_Step> _steps(AppLocalizations t) {
    switch (guide) {
      case 'ezviz_app':
        return [
          _Step(t.crfStepOpenApp('EZVIZ'), _Sketch.list(t)),
          _Step(t.crfStepSettings, _Sketch.gear(t)),
          _Step(t.crfStepEncryption, _Sketch.encryption(t)),
          _Step(t.crfStepDelete, _Sketch.delete(t, t.crfSkDelete)),
          _Step(t.crfStepLabelEzviz, _Sketch.sticker(t.crfSkCodeEzviz)),
        ];
      case 'dmss':
        return [
          _Step(t.crfStepDmssMore, _Sketch.list(t, more: true)),
          _Step(t.crfStepDmssDelete, _Sketch.delete(t, t.crfSkDeleteShort)),
          _Step(t.crfStepLabelDmss, _Sketch.sticker(t.crfSkCodeDmss)),
        ];
      default:
        return [
          _Step(t.crfStepOpenApp('Imou Life'), _Sketch.list(t)),
          _Step(t.crfStepSettings, _Sketch.gear(t)),
          _Step(t.crfStepDelete, _Sketch.delete(t, t.crfSkDelete)),
          _Step(t.crfStepLabelImou, _Sketch.sticker(t.crfSkCodeImou)),
        ];
    }
  }

  String _title(AppLocalizations t) => switch (guide) {
        'ezviz_app' => t.crfTitleEzviz,
        'dmss' => t.crfTitleDmss,
        _ => t.crfTitleImou,
      };

  String _app() => switch (guide) {
        'ezviz_app' => 'EZVIZ',
        'dmss' => 'DMSS',
        _ => 'Imou Life',
      };

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final lang = wmLang(context);
    final th = Theme.of(context);
    final steps = _steps(t);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        key: const Key('ccnBeforeSheet'),
        padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Semantics(
              header: true,
              child: Text(_title(t), style: th.textTheme.titleLarge)),
          const SizedBox(height: Gap.xs),
          Text(t.crfWhy, style: th.textTheme.bodyMedium),
          const SizedBox(height: Gap.md),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Gap.md),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: th.colorScheme.primary,
                  child: Text(wmDigits(lang, i + 1),
                      style: th.textTheme.labelLarge
                          ?.copyWith(color: th.colorScheme.onPrimary, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(steps[i].text, key: Key('crfStep$i'), style: th.textTheme.bodyLarge),
                    const SizedBox(height: Gap.xs),
                    ExcludeSemantics(child: steps[i].sketch),
                  ]),
                ),
              ]),
            ),
          Text(t.crfNotInApp(_app()), style: th.textTheme.bodySmall),
          const SizedBox(height: Gap.md),
          FilledButton.icon(
            key: const Key('ccnBeforeGo'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
            icon: const Icon(Icons.check_circle_rounded),
            label: Text(t.crfContinue),
            onPressed: () => Navigator.of(context).pop(true),
          ),
          const SizedBox(height: Gap.xs),
          TextButton(
            key: const Key('ccnBeforeCancel'),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t.crfCancel),
          ),
        ]),
      ),
    );
  }
}

/// One row inside a drawn phone screen.
class _Row {
  final IconData icon;
  final String label;
  final bool hot;      // the row to tap (highlighted, finger icon)
  final bool danger;   // red text (Delete)
  final bool? toggle;  // a switch drawn at the end (false = off)
  const _Row(this.icon, this.label, {this.hot = false, this.danger = false, this.toggle});
}

/// Our own simple drawing of a vendor screen: a phone outline, a top bar
/// and a few rows; the row to tap is outlined in the brand colour.
class _Sketch extends StatelessWidget {
  final String top;
  final List<_Row> rows;
  final bool gearHot;
  final String? sticker;   // a camera-label drawing instead of a phone

  const _Sketch({required this.top, required this.rows, this.gearHot = false, this.sticker});

  factory _Sketch.list(AppLocalizations t, {bool more = false}) => _Sketch(top: t.crfSkDevices, rows: [
        _Row(more ? Icons.more_vert_rounded : Icons.videocam_rounded, t.crfSkCamera, hot: true),
        _Row(Icons.videocam_outlined, t.crfSkCamera2),
      ]);

  factory _Sketch.gear(AppLocalizations t) => _Sketch(
      top: t.crfSkCamera, gearHot: true, rows: [_Row(Icons.play_circle_outline_rounded, t.crfSkLive)]);

  factory _Sketch.encryption(AppLocalizations t) => _Sketch(top: t.crfSkSettings, rows: [
        _Row(Icons.lock_outline_rounded, t.crfSkEncryption, hot: true, toggle: false),
        _Row(Icons.notifications_none_rounded, t.crfSkAlerts),
      ]);

  factory _Sketch.delete(AppLocalizations t, String label) => _Sketch(top: t.crfSkSettings, rows: [
        _Row(Icons.info_outline_rounded, t.crfSkDeviceInfo),
        _Row(Icons.delete_outline_rounded, label, hot: true, danger: true),
      ]);

  factory _Sketch.sticker(String codeLabel) =>
      _Sketch(top: '', rows: const [], sticker: codeLabel);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    if (sticker != null) {
      return Container(
        width: 230,
        padding: const EdgeInsets.all(Gap.sm),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cs.outline),
        ),
        child: Row(children: [
          Icon(Icons.qr_code_2_rounded, size: 40, color: cs.onSurface),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('SN: XXXXXXXXX', style: small),
              Container(
                margin: const EdgeInsets.only(top: 2),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(border: Border.all(color: cs.primary, width: 2),
                    borderRadius: BorderRadius.circular(4)),
                child: Text('${sticker!}: XXXXXX', style: small?.copyWith(fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ]),
      );
    }
    return Container(
      width: 230,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outline, width: 2),
      ),
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.sm, Gap.sm),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(top, style: small?.copyWith(fontWeight: FontWeight.w700))),
          Container(
            padding: const EdgeInsets.all(2),
            decoration: gearHot
                ? BoxDecoration(shape: BoxShape.circle, border: Border.all(color: cs.primary, width: 2))
                : null,
            child: Icon(Icons.settings_rounded, size: 18, color: gearHot ? cs.primary : cs.onSurfaceVariant),
          ),
          if (gearHot) Icon(Icons.touch_app_rounded, size: 18, color: cs.primary),
        ]),
        const Divider(height: Gap.sm),
        for (final r in rows)
          Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: r.hot ? cs.primary : cs.outlineVariant, width: r.hot ? 2 : 1),
            ),
            child: Row(children: [
              Icon(r.icon, size: 18, color: r.danger ? cs.error : cs.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(r.label,
                    style: small?.copyWith(
                        color: r.danger ? cs.error : null,
                        fontWeight: r.hot ? FontWeight.w700 : null)),
              ),
              if (r.toggle != null)
                Icon(r.toggle! ? Icons.toggle_on_rounded : Icons.toggle_off_rounded,
                    size: 26, color: r.toggle! ? cs.primary : cs.onSurfaceVariant),
              if (r.hot) Icon(Icons.touch_app_rounded, size: 18, color: cs.primary),
            ]),
          ),
      ]),
    );
  }
}
