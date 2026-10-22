import 'package:flutter/widgets.dart';

/// tl1: a stable id for Firebase Test Lab Robo scripts. Flutter sends a
/// Semantics `identifier` to Android as the node's resource-id; MergeSemantics
/// makes that id sit on the SAME node as the field's text/set-text or the
/// button's tap (a plain Semantics wrapper would become a separate parent
/// node, which Robo could click but never type into). No visual change.
class RoboId extends StatelessWidget {
  const RoboId({super.key, required this.id, required this.child});
  final String id;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      MergeSemantics(child: Semantics(identifier: id, child: child));
}
