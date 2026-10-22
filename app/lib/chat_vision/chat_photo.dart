
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../photo_studio/ps_ads.dart';
import '../state.dart';
import '../theme.dart';
import 'cv_backend.dart';
import 'cv_controller.dart';
import 'on_device_vision.dart';

/// A photo the user attached in a chat, plus the question typed with it.
class ChatPhotoRequest {
  ChatPhotoRequest(this.bytes, this.question);
  final Uint8List bytes;
  final String question;
}

/// Camera / gallery seam (tests inject bytes). The picker already shrinks the
/// photo (max 1600 px, JPEG 85) so it fits the server cap and uploads fast.
abstract class ChatPhotoPicker {
  Future<Uint8List?> pick({required bool camera});
}

class ImagePickerChatPhotoPicker implements ChatPhotoPicker {
  const ImagePickerChatPhotoPicker();
  @override
  Future<Uint8List?> pick({required bool camera}) async {
    try {
      final x = await ImagePicker().pickImage(
          source: camera ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 1600,
          maxHeight: 1600,
          imageQuality: 85);
      return x == null ? null : await x.readAsBytes();
    } catch (_) {
      return null;
    }
  }
}

/// The paper-clip button in a chat input bar. Opens a camera / gallery sheet
/// and hands back the photo; the caller adds a [ChatPhotoTurn] to its thread.
class ChatPhotoAttachButton extends StatelessWidget {
  const ChatPhotoAttachButton(
      {super.key, required this.onPicked, this.picker, this.enabled = true});
  final void Function(Uint8List bytes) onPicked;
  final ChatPhotoPicker? picker;
  final bool enabled;

  Future<void> _open(BuildContext context) async {
    final t = AppLocalizations.of(context);
    final camera = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.sm),
            child: Text(t.h1PhotoSheetTitle,
                style: Theme.of(ctx).textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.lg),
            child: Text(t.h1PhotoSheetBody,
                style: TextStyle(color: Theme.of(ctx).colorScheme.onSurfaceVariant)),
          ),
          const SizedBox(height: Gap.sm),
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: Text(t.h1PhotoCamera),
            onTap: () => Navigator.pop(ctx, true),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: Text(t.h1PhotoGallery),
            onTap: () => Navigator.pop(ctx, false),
          ),
          const SizedBox(height: Gap.sm),
        ]),
      ),
    );
    if (camera == null) return;
    final bytes =
        await (picker ?? const ImagePickerChatPhotoPicker()).pick(camera: camera);
    if (bytes == null || bytes.isEmpty) return;
    HapticFeedback.selectionClick();
    onPicked(bytes);
  }

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: AppLocalizations.of(context).h1AttachPhoto,
        onPressed: enabled ? () => _open(context) : null,
        icon: const Icon(Icons.add_photo_alternate_outlined),
      );
}

/// One photo turn: the user's photo + question, then Assisto's answer card.
class ChatPhotoTurn extends StatefulWidget {
  const ChatPhotoTurn({
    super.key,
    required this.request,
    this.backend,
    this.onDevice,
    this.ads,
    this.controller,
  });
  final ChatPhotoRequest request;
  final CvBackend? backend;
  final OnDeviceVision? onDevice;
  final PhotoAdBridge? ads;

  /// Pre-built controller (tests / gallery).
  final CvController? controller;

  @override
  State<ChatPhotoTurn> createState() => _ChatPhotoTurnState();
}

class _ChatPhotoTurnState extends State<ChatPhotoTurn>
    with AutomaticKeepAliveClientMixin {
  late final CvController c;
  late final bool _owns;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _owns = widget.controller == null;
    c = widget.controller ??
        CvController(
          backend: widget.backend ?? ApiCvBackend(context.read<AppState>().api),
          bytes: widget.request.bytes,
          question: widget.request.question,
          onDevice: widget.onDevice,
          ads: widget.ads,
        );
    if (_owns) WidgetsBinding.instance.addPostFrameCallback((_) => c.start());
  }

  @override
  void dispose() {
    if (_owns) c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    final w = MediaQuery.of(context).size.width;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ---- the user's photo + question ----
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Container(
            constraints: BoxConstraints(maxWidth: w * 0.70),
            padding: const EdgeInsets.all(Gap.xs),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.memory(widget.request.bytes,
                    height: 160,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    semanticLabel: t.h1PhotoYouSent,
                    errorBuilder: (_, __, ___) => SizedBox(
                        height: 80,
                        child: Center(
                            child: Icon(Icons.broken_image_outlined,
                                color: scheme.onPrimary)))),
              ),
              if (widget.request.question.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.sm, Gap.sm, Gap.xs),
                  child: Text(widget.request.question,
                      style: TextStyle(color: scheme.onPrimary, height: 1.4)),
                ),
            ]),
          ),
        ),
      ),
      // ---- Assisto's card ----
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: ListenableBuilder(
          listenable: c,
          builder: (context, _) => _AnswerCard(c: c),
        ),
      ),
    ]);
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.c});
  final CvController c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = AppLocalizations.of(context);
    final w = MediaQuery.of(context).size.width;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(28 * 0.26),
        child: Image.asset('assets/branding/new_logo.png',
            width: 28, height: 28, fit: BoxFit.cover),
      ),
      const SizedBox(width: Gap.sm),
      Flexible(
        child: Container(
          constraints: BoxConstraints(maxWidth: w * 0.80),
          padding: const EdgeInsets.all(Gap.lg),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(4),
              topRight: Radius.circular(18),
              bottomLeft: Radius.circular(18),
              bottomRight: Radius.circular(18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: c.phase == CvPhase.reading
                ? [_Busy(text: t.h1PhotoReading)]
                : [
                    _onDevice(context, t, scheme),
                    const SizedBox(height: Gap.md),
                    Divider(height: 1, color: scheme.outlineVariant),
                    const SizedBox(height: Gap.md),
                    _detailed(context, t, scheme),
                  ],
          ),
        ),
      ),
    ]);
  }

  // ---------------- on-device part ----------------
  Widget _onDevice(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final title = Text(t.h1OnDeviceTitle,
        style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface));
    final r = c.reading;
    if (r.status == OnDeviceStatus.unavailable) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title,
        const SizedBox(height: Gap.xs),
        Text(t.h1OnDeviceUnavailable,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ]);
    }
    if (r.status == OnDeviceStatus.failed) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title,
        const SizedBox(height: Gap.xs),
        Text(t.h1OnDeviceFailed,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ]);
    }
    final a = c.local!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      title,
      const SizedBox(height: Gap.xs),
      Text(_kindLine(t, a.kind), style: const TextStyle(height: 1.4)),
      if (a.text.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Text(t.h1OnDeviceTextFound,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.xs),
        SelectableText(
          a.text.length > 600 ? '${a.text.substring(0, 600)}…' : a.text,
          style: const TextStyle(height: 1.35),
        ),
      ] else ...[
        const SizedBox(height: Gap.xs),
        Text(t.h1OnDeviceNoText,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      ],
      if (r.latinOnly) ...[
        const SizedBox(height: Gap.xs),
        Text(t.h1OnDeviceLatinOnly,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
      ],
      if (a.labels.isNotEmpty) ...[
        const SizedBox(height: Gap.sm),
        Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
          for (final l in a.labels)
            Chip(
              label: Text(l),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
        ]),
      ],
      if (a.kind == PhotoKind.medicine) ...[
        const SizedBox(height: Gap.sm),
        _Note(icon: Icons.medical_information_outlined, text: t.h1MedicineNote),
      ],
    ]);
  }

  String _kindLine(AppLocalizations t, PhotoKind k) => switch (k) {
        PhotoKind.medicine => t.h1KindMedicine,
        PhotoKind.bill => t.h1KindBill,
        PhotoKind.document => t.h1KindDocument,
        PhotoKind.plant => t.h1KindPlant,
        PhotoKind.food => t.h1KindFood,
        PhotoKind.other => t.h1KindOther,
      };

  // ---------------- detailed (cloud) part ----------------
  Widget _detailed(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    final title = Text(t.h1DetailedTitle,
        style: TextStyle(fontWeight: FontWeight.w700, color: scheme.onSurface));
    Widget body;
    switch (c.phase) {
      case CvPhase.reading:
      case CvPhase.funding:
        body = _Busy(text: t.h1DetailedPreparing);
      case CvPhase.watchingAd:
        body = _Busy(text: t.h1DetailedWatching);
      case CvPhase.verifying:
        final j = c.job;
        body = _Busy(
            text: t.h1DetailedVerifying('${(j?.adsVerified ?? 0) + 1}', '${j?.adsRequired ?? 0}'));
      case CvPhase.answering:
        body = _Busy(text: t.h1DetailedAnswering);
      case CvPhase.done:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(c.answer, style: const TextStyle(height: 1.45)),
          const SizedBox(height: Gap.sm),
          _Note(icon: Icons.lock_outline, text: t.h1PrivacyNote),
        ]);
      case CvPhase.refused:
        body = _Note(
            icon: Icons.privacy_tip_outlined,
            text: c.message.isNotEmpty ? c.message : t.h1FaceRefused);
      case CvPhase.adFailed:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c.insufficient ? t.h1NotEnoughCredits : t.h1AdFailed,
              style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.sm),
          _Actions(children: [
            FilledButton.tonal(onPressed: c.retryAds, child: Text(t.h1TryAdAgain)),
            if (c.quote.option('credits') != null)
              OutlinedButton(
                  onPressed: () => c.requestDetailed('credits'),
                  child: Text(t.h1UseCredits('${c.quote.option('credits')!.credits}'))),
          ]),
        ]);
      case CvPhase.error:
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              c.insufficient
                  ? t.h1NotEnoughCredits
                  : (c.message.isNotEmpty ? c.message : t.h1DetailedError),
              style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.sm),
          _Actions(children: [
            FilledButton.tonal(onPressed: c.retry, child: Text(t.h1TryAgain)),
          ]),
        ]);
      case CvPhase.ready:
        body = _offer(context, t, scheme);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      title,
      const SizedBox(height: Gap.xs),
      body,
    ]);
  }

  Widget _offer(BuildContext context, AppLocalizations t, ColorScheme scheme) {
    if (c.configFailed) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.h1DetailedOffline, style: const TextStyle(height: 1.4)),
        const SizedBox(height: Gap.sm),
        _Actions(children: [
          FilledButton.tonal(onPressed: c.retryConfig, child: Text(t.h1TryAgain)),
        ]),
      ]);
    }
    final q = c.quote;
    final pool = q.option('pool');
    final ads = q.option('ads');
    final credits = q.option('credits');
    final reasonText = q.reason != 'ok' && q.message.isNotEmpty ? q.message : '';
    if (!q.ok) {
      return Text(reasonText.isNotEmpty ? reasonText : t.h1DetailedUnavailable,
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
          pool != null
              ? t.h1DetailedPaidBody
              : (ads != null ? t.h1DetailedFreeBody : reasonText),
          style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
      const SizedBox(height: Gap.sm),
      _Actions(children: [
        if (pool != null)
          FilledButton.icon(
              onPressed: () => c.requestDetailed('pool'),
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: Text(t.h1DetailedPool('${pool.credits}'))),
        if (ads != null)
          FilledButton.icon(
              onPressed: () => c.requestDetailed('ads'),
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: Text(t.h1DetailedAds('${ads.ads}'))),
        if (credits != null)
          OutlinedButton(
              onPressed: () => c.requestDetailed('credits'),
              child: Text(t.h1UseCredits('${credits.credits}'))),
      ]),
    ]);
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: Gap.sm, runSpacing: Gap.sm, children: children);
}

class _Busy extends StatelessWidget {
  const _Busy({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Row(children: [
        const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: Gap.md),
        Expanded(child: Text(text, style: const TextStyle(height: 1.4))),
      ]);
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: scheme.primary),
      const SizedBox(width: Gap.sm),
      Expanded(
          child: Text(text,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.4))),
    ]);
  }
}
