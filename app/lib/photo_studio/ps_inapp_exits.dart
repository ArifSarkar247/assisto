/// aileft (owner 3 Nov 23:25 PART 7c): Photo Studio's in-app exits besides
/// the share sheet.
///
///  * Send to My Circle — pick a person / group in one tap (the forward
///    picker), then the photo goes through the SAME end-to-end encrypted media
///    path as a photo sent from the chat (preview + caption, outbox upload).
///  * Add to business catalog — only when the user already runs a shop: the
///    edited photo becomes the picture of one of their products, or a new one.
///
/// Both take the same gated, full-quality file as Save / Share
/// ([PhotoStudioController.exportFile]) — never a free bypass of the gate.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api.dart';
import '../l10n/app_localizations.dart';
import '../messaging/forward.dart';
import '../messaging/media/media_prep.dart';
import '../messaging/media/media_send.dart';
import '../state.dart';
import '../theme.dart';
import '../widgets/app_sheet.dart';
import '../widgets/chatnav.dart';
import '../widgets/local_counter.dart';
import 'ps_controller.dart';
import 'ps_export.dart';

void _say(BuildContext context, String text, {SnackBarAction? action}) {
  ScaffoldMessenger.maybeOf(context)
    ?..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

/// Does this user run a shop? (GET business/products/photo; never creates one.)
Future<bool> psHasCatalog(ApiClient api) async {
  try {
    final r = await api.catalogPhotoState();
    return r['has_catalog'] == true;
  } catch (_) {
    return false;
  }
}

/// Send to My Circle: choose a chat, then the encrypted media send.
Future<void> psSendToCircle(
    BuildContext context, PhotoStudioController c, GateUi ui) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  List<ForwardTarget> targets;
  try {
    targets = await loadForwardTargets(api);
  } catch (_) {
    targets = const [];
  }
  if (!context.mounted) return;
  if (targets.isEmpty) {
    // never a dead end: one tap to add people
    _say(context, t.aileftCircleEmpty,
        action: SnackBarAction(
            label: t.aileftCircleAdd,
            onPressed: () => ChatNav.push(context, 'circle_add')));
    return;
  }
  final to = await pickForwardTarget(context, targets);
  if (to == null || !context.mounted) return;
  final file = await c.exportFile(ui);
  if (file == null || !context.mounted) return;
  final draft = await preparePhotoBytes(file.$1, file.$2);
  if (!context.mounted) return;
  final job = await confirmAndQueueMedia(context, draft, chatKind: to.kind, chatId: to.id);
  if (job != null && context.mounted) _say(context, t.aileftSentCircle(to.name));
}

/// Add to business catalog: pick one of my products, or a new one.
Future<void> psAddToCatalog(
    BuildContext context, PhotoStudioController c, GateUi ui) async {
  final t = AppLocalizations.of(context);
  final api = context.read<AppState>().api;
  Map<String, dynamic> st;
  try {
    st = await api.catalogPhotoState();
  } catch (_) {
    if (context.mounted) _say(context, t.aileftCatalogFailed);
    return;
  }
  if (!context.mounted || st['has_catalog'] != true) return;
  final products = ((st['products'] ?? const []) as List).whereType<Map>().toList();
  final choice = await showAppSheet<Map<String, Object?>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => _CatalogSheet(products: products));
  if (choice == null || !context.mounted) return;
  final file = await c.exportFile(ui);
  if (file == null || !context.mounted) return;
  try {
    await api.catalogAddPhoto(
        bytes: file.$1,
        fileName: file.$2,
        productId: choice['product_id'] as int?,
        name: choice['name'] as String?,
        price: choice['price'] as String?);
    if (context.mounted) _say(context, t.aileftCatalogDone);
  } catch (_) {
    if (context.mounted) _say(context, t.aileftCatalogFailed);
  }
}

class _CatalogSheet extends StatefulWidget {
  const _CatalogSheet({required this.products});
  final List<Map> products;
  @override
  State<_CatalogSheet> createState() => _CatalogSheetState();
}

class _CatalogSheetState extends State<_CatalogSheet> {
  final _name = TextEditingController();
  final _price = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _price.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(Gap.lg, 0, Gap.lg, Gap.lg),
            children: [
              Text(t.aileftCatalogTitle, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: Gap.xs),
              Text(t.aileftCatalogBody, style: TextStyle(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.md),
              TextField(
                key: const Key('psCatName'),
                controller: _name,
                maxLength: 160,
                buildCounter: localCounter,
                decoration: InputDecoration(labelText: t.aileftCatalogName),
              ),
              TextField(
                key: const Key('psCatPrice'),
                controller: _price,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: t.aileftCatalogPrice),
              ),
              const SizedBox(height: Gap.sm),
              FilledButton.icon(
                key: const Key('psCatNew'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                onPressed: () {
                  final n = _name.text.trim();
                  if (n.isEmpty) return;
                  Navigator.pop(context, {'name': n, 'price': _price.text.trim()});
                },
                icon: const Icon(Icons.add_business_rounded),
                label: Text(t.aileftCatalogNew),
              ),
              if (widget.products.isNotEmpty) ...[
                const SizedBox(height: Gap.lg),
                Text(t.aileftCatalogExisting,
                    style: Theme.of(context).textTheme.labelLarge),
                for (final p in widget.products)
                  ListTile(
                    key: Key('psCatP_${p['id']}'),
                    minVerticalPadding: 12,
                    leading: Icon(p['has_photo'] == true
                        ? Icons.image_rounded
                        : Icons.inventory_2_outlined),
                    title: Text('${p['name'] ?? ''}',
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, {
                      'product_id': p['id'] is int ? p['id'] : int.tryParse('${p['id']}'),
                    }),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
