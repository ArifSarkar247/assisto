import 'package:flutter/material.dart';
import '../theme.dart';

/// A single shimmering placeholder block.
class Skeleton extends StatefulWidget {
  final double? width;
  final double height;
  final double radius;
  const Skeleton({super.key, this.width, this.height = 14, this.radius = 8});

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = scheme.surfaceContainerHighest;
    final hi = Color.alphaBlend(
        scheme.onSurface.withValues(alpha: 0.06), base);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          gradient: LinearGradient(
            begin: Alignment(-1 - 2 * _c.value, 0),
            end: Alignment(1 - 2 * _c.value, 0),
            colors: [base, hi, base],
            stops: const [0.3, 0.5, 0.7],
          ),
        ),
      ),
    );
  }
}

/// A list of skeleton "cards" — the standard loading state for list modules.
class SkeletonList extends StatelessWidget {
  final int count;
  const SkeletonList({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.all(Gap.lg),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: Gap.md),
      itemBuilder: (_, __) => Row(children: [
        const Skeleton(width: 44, height: 44, radius: 12),
        const SizedBox(width: Gap.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: const [
            Skeleton(width: 160, height: 13),
            SizedBox(height: Gap.sm),
            Skeleton(width: 110, height: 11),
          ]),
        ),
      ]),
    );
  }
}

/// A crafted empty/error state: icon, title, message, optional action.
class StateMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final Color? tint;
  const StateMessage(
      {super.key,
      required this.icon,
      required this.title,
      this.message,
      this.action,
      this.tint});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            height: 72,
            width: 72,
            decoration: BoxDecoration(
              color: (tint ?? scheme.primary).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 34, color: tint ?? scheme.primary),
          ),
          const SizedBox(height: Gap.lg),
          Text(title,
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          if (message != null) ...[
            const SizedBox(height: Gap.sm),
            Text(message!,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          ],
          if (action != null) ...[
            const SizedBox(height: Gap.lg),
            action!,
          ],
        ]),
      ),
    );
  }
}
