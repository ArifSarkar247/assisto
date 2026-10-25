import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../l10n/app_localizations.dart';
import 'bday_model.dart';

/// Send-a-wish sheet (ADVANCED). Shows, for one occasion:
///   - the server wish DRAFTS (short / warm / formal),
///   - a greeting-CARD draft (title + body),
///   - an AI wish generator that is MOCK + KEY-GATED: with no key it returns the
///     deterministic mock marked "AI preview (mock, no key)" — honest, never a
///     fake real-AI claim (mirrors backend birthdays.ai_wish).
///
/// Every draft offers ONE-TAP SEND: WhatsApp-share / SMS / call (when a phone is
/// linked) plus copy + generic share. Nothing is auto-sent — each action only
/// OPENS the native app with the text prefilled; the user presses send.
class BdayWishSheet extends StatefulWidget {
  final Map<String, dynamic> occasion;

  /// drafts: [{style,text}], card: {title,body} — as returned by the drafts API.
  final List<Map<String, dynamic>> drafts;
  final Map<String, dynamic>? card;

  /// Optional AI generator. Given a style, returns {text, is_mock, source}. The
  /// screen wires this to api.birthdayDrafts/ai; if null the AI row is hidden.
  final Future<Map<String, dynamic>?> Function(String style)? onAiWish;

  const BdayWishSheet({
    super.key,
    required this.occasion,
    required this.drafts,
    this.card,
    this.onAiWish,
  });

  @override
  State<BdayWishSheet> createState() => _BdayWishSheetState();
}

class _BdayWishSheetState extends State<BdayWishSheet> {
  String? _aiText;
  bool _aiMock = true;
  bool _aiLoading = false;

  String get _phone => (widget.occasion['phone'] ?? '').toString();

  Future<void> _open(Uri uri) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        messenger.showSnackBar(
            SnackBar(content: Text(bStr(context, 'bSendOpenError'))));
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
            SnackBar(content: Text(bStr(context, 'bSendOpenError'))));
      }
    }
  }

  Future<void> _genAi(String style) async {
    if (widget.onAiWish == null) return;
    setState(() => _aiLoading = true);
    final r = await widget.onAiWish!(style);
    if (!mounted) return;
    setState(() {
      _aiLoading = false;
      if (r != null) {
        _aiText = (r['text'] ?? '').toString();
        _aiMock = r['is_mock'] != false; // honest default: mock unless told real
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final card = widget.card;
    return Padding(
      padding: const EdgeInsets.all(Gap.lg),
      child: SingleChildScrollView(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(bStr(context, 'bWishTitle'),
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Gap.xs),
              Text(bStr(context, 'bWishSubtitle'),
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),

              // ---- wish drafts (short / warm / formal) ----
              for (final d in widget.drafts)
                _WishCard(
                  label: bStr(context, bStyleKey((d['style'] ?? '').toString())),
                  text: (d['text'] ?? '').toString(),
                  phone: _phone,
                  onOpen: _open,
                ),

              // ---- AI wish (mock + key-gated, honest marker) ----
              if (widget.onAiWish != null) ...[
                const SizedBox(height: Gap.sm),
                _AiBlock(
                  loading: _aiLoading,
                  text: _aiText,
                  isMock: _aiMock,
                  phone: _phone,
                  onGenerate: () => _genAi('warm'),
                  onOpen: _open,
                ),
              ],

              // ---- greeting card draft ----
              if (card != null &&
                  (card['body'] ?? '').toString().isNotEmpty) ...[
                const SizedBox(height: Gap.md),
                Text(bStr(context, 'bCardTitle'),
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: Gap.sm),
                _WishCard(
                  label: (card['title'] ?? '').toString(),
                  text: (card['body'] ?? '').toString(),
                  phone: _phone,
                  onOpen: _open,
                  tinted: true,
                ),
              ],
              const SizedBox(height: Gap.sm),
            ]),
      ),
    );
  }
}

/// A draft card with copy + one-tap-send actions.
class _WishCard extends StatelessWidget {
  final String label;
  final String text;
  final String phone;
  final bool tinted;
  final Future<void> Function(Uri) onOpen;
  const _WishCard({
    required this.label,
    required this.text,
    required this.phone,
    required this.onOpen,
    this.tinted = false,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: tinted ? scheme.primaryContainer.withValues(alpha: 0.3) : null,
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (label.isNotEmpty)
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
          if (label.isNotEmpty) const SizedBox(height: 4),
          Text(text, style: const TextStyle(height: 1.4)),
          const SizedBox(height: Gap.sm),
          _ActionRow(text: text, phone: phone, onOpen: onOpen),
        ]),
      ),
    );
  }
}

/// WhatsApp / SMS / Call (when phone) + Copy + Share. Icons have tooltips for
/// a11y; buttons wrap on small screens.
class _ActionRow extends StatelessWidget {
  final String text;
  final String phone;
  final Future<void> Function(Uri) onOpen;
  const _ActionRow(
      {required this.text, required this.phone, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final hasPhone = phone.replaceAll(RegExp(r'[^0-9]'), '').isNotEmpty;
    return Wrap(spacing: Gap.xs, runSpacing: 0, children: [
      TextButton.icon(
        icon: const Icon(Icons.chat_rounded, size: 16),
        label: Text(bStr(context, 'bSendWhatsApp')),
        onPressed: () => onOpen(bWhatsAppUri(text, phone: phone)),
      ),
      if (hasPhone)
        TextButton.icon(
          icon: const Icon(Icons.sms_rounded, size: 16),
          label: Text(bStr(context, 'bSendSms')),
          onPressed: () => onOpen(bSmsUri(text, phone)),
        ),
      if (hasPhone)
        TextButton.icon(
          icon: const Icon(Icons.call_rounded, size: 16),
          label: Text(bStr(context, 'bSendCall')),
          onPressed: () => onOpen(bCallUri(phone)),
        ),
      TextButton.icon(
        icon: const Icon(Icons.copy_rounded, size: 16),
        label: Text(t.copy),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(t.copied)));
        },
      ),
      TextButton.icon(
        icon: const Icon(Icons.share_rounded, size: 16),
        label: Text(t.birthdayShare),
        onPressed: () => Share.share(text),
      ),
    ]);
  }
}

/// AI wish block: generate button -> text + honest "AI preview (mock, no key)"
/// marker + the same send actions.
class _AiBlock extends StatelessWidget {
  final bool loading;
  final String? text;
  final bool isMock;
  final String phone;
  final VoidCallback onGenerate;
  final Future<void> Function(Uri) onOpen;
  const _AiBlock({
    required this.loading,
    required this.text,
    required this.isMock,
    required this.phone,
    required this.onGenerate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.secondaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(Gap.md),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome_rounded, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Text(bStr(context, 'bAiWish'),
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary)),
            if (text != null && isMock) ...[
              const SizedBox(width: Gap.sm),
              Flexible(
                child: Text(bStr(context, 'bAiPreview'),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
            ],
          ]),
          const SizedBox(height: Gap.sm),
          if (text == null)
            OutlinedButton.icon(
              icon: loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.auto_awesome_rounded, size: 16),
              label: Text(bStr(context, 'bAiGenerate')),
              onPressed: loading ? null : onGenerate,
            )
          else ...[
            Text(text!, style: const TextStyle(height: 1.4)),
            const SizedBox(height: Gap.sm),
            _ActionRow(text: text!, phone: phone, onOpen: onOpen),
          ],
        ]),
      ),
    );
  }
}
