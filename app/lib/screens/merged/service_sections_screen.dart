import 'package:flutter/material.dart';

import '../../theme.dart';
import '../../widgets/app_sheet.dart' show withNavBarInset;

/// svcclean (owner order 10 Nov 00:45): ONE tile in All Services for ONE job;
/// related jobs are SECTIONS inside it. This is the shared body of such a
/// tile (Lost phone, Phone safety): a short intro, then one big card per
/// section that opens the full, real screen of that section.
///
/// [open]: an OLD deep link / route / notification / saved shortcut of a
/// section (e.g. `my_lost_phone`) lands HERE and then opens that section on
/// top at once — Back returns to this one place, so the user learns where it
/// lives now. Nothing is lost and nothing is a stub: every section is the
/// complete screen it always was.
class ServiceSection {
  /// The old ChatNav route key of this section (also the RouteSettings name,
  /// so feedback / ScreenTracker / ad rules see the same name as before).
  final String id;
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;
  const ServiceSection({
    required this.id,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });
}

class ServiceSectionsScreen extends StatefulWidget {
  final String title;
  final String intro;
  final List<ServiceSection> sections;
  final String? open;

  /// Optional accent for the section icons (Emergency-style red etc.).
  final Color? accent;
  const ServiceSectionsScreen({
    super.key,
    required this.title,
    required this.intro,
    required this.sections,
    this.open,
    this.accent,
  });

  @override
  State<ServiceSectionsScreen> createState() => _ServiceSectionsScreenState();
}

class _ServiceSectionsScreenState extends State<ServiceSectionsScreen> {
  @override
  void initState() {
    super.initState();
    final open = widget.open;
    if (open != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final s in widget.sections) {
          if (s.id == open) {
            _go(s);
            break;
          }
        }
      });
    }
  }

  Future<void> _go(ServiceSection s) => Navigator.of(context).push(
      MaterialPageRoute(builder: s.builder, settings: RouteSettings(name: s.id)));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        key: const ValueKey('svc-sections'),
        padding: withNavBarInset(context, const EdgeInsets.all(Gap.lg)),
        children: [
          Text(widget.intro,
              key: const ValueKey('svc-intro'),
              style: AType.bodyMedium.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: Gap.md),
          for (final s in widget.sections)
            Card(
              margin: const EdgeInsets.only(bottom: Gap.sm),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                key: ValueKey('svc-${s.id}'),
                minTileHeight: 64,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: Gap.lg, vertical: Gap.xs),
                leading: CircleAvatar(
                  backgroundColor: widget.accent?.withValues(alpha: 0.14) ??
                      scheme.secondaryContainer,
                  foregroundColor:
                      widget.accent ?? scheme.onSecondaryContainer,
                  child: Icon(s.icon),
                ),
                title: Text(s.title,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
                subtitle: Text(s.subtitle),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => _go(s),
              ),
            ),
        ],
      ),
    );
  }
}

/// svcclean: an old route of a feature that is now a SECTION of another tile
/// (e.g. `nominee` inside Family). Shows the tile's screen ([home]) and opens
/// the section ([open]) on top of it at once, so Back lands in the one place
/// where it lives now.
class LandThenOpen extends StatefulWidget {
  final Widget home;
  final WidgetBuilder open;
  final String name;
  const LandThenOpen(
      {super.key, required this.home, required this.open, required this.name});

  @override
  State<LandThenOpen> createState() => _LandThenOpenState();
}

class _LandThenOpenState extends State<LandThenOpen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
          builder: widget.open, settings: RouteSettings(name: widget.name)));
    });
  }

  @override
  Widget build(BuildContext context) => widget.home;
}
