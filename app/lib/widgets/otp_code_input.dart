import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// o1-otp — 6-box one-time-code input.
///
/// One real (invisible) TextField sits over [length] painted boxes, so:
///  * paste / keyboard suggestion / Android autofill all land in one field
///    (autofillHints: oneTimeCode — the platform's SMS-code autofill; no
///    native SMS-Retriever code, so no new native risk);
///  * the boxes are purely visual and scale down to fit 360 px;
///  * digits use FittedBox so large-font settings never clip.
class OtpCodeInput extends StatefulWidget {
  final TextEditingController controller;
  final int length;
  final bool enabled;
  final bool hasError;
  final bool autofocus;
  final String semanticsLabel;
  final ValueChanged<String>? onCompleted;
  final ValueChanged<String>? onChanged;

  const OtpCodeInput({
    super.key,
    required this.controller,
    this.length = 6,
    this.enabled = true,
    this.hasError = false,
    this.autofocus = true,
    this.semanticsLabel = '',
    this.onCompleted,
    this.onChanged,
  });

  @override
  State<OtpCodeInput> createState() => _OtpCodeInputState();
}

class _OtpCodeInputState extends State<OtpCodeInput> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onText);
    _focus.addListener(_rebuild);
  }

  @override
  void didUpdateWidget(OtpCodeInput old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    _focus.removeListener(_rebuild);
    _focus.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _onText() => _rebuild();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.controller.text;
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final maxW = c.maxWidth.isFinite ? c.maxWidth : 360.0;
      final box = math.min(52.0, (maxW - gap * (widget.length - 1)) / widget.length);
      final height = box * 1.15;
      return Semantics(
        label: widget.semanticsLabel,
        textField: true,
        child: SizedBox(
          height: height,
          child: Stack(children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.length; i++) ...[
                  if (i > 0) const SizedBox(width: gap),
                  _box(context, scheme, i, text, box, height),
                ],
              ],
            ),
            Positioned.fill(
              child: Opacity(
                opacity: 0.0,
                child: TextField(
                  key: const Key('otp-code-field'),
                  controller: widget.controller,
                  focusNode: _focus,
                  enabled: widget.enabled,
                  autofocus: widget.autofocus,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  showCursor: false,
                  enableSuggestions: false,
                  autocorrect: false,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(widget.length),
                  ],
                  decoration: const InputDecoration(
                      border: InputBorder.none, counterText: ''),
                  onChanged: (v) {
                    widget.onChanged?.call(v);
                    if (v.length == widget.length) widget.onCompleted?.call(v);
                  },
                ),
              ),
            ),
          ]),
        ),
      );
    });
  }

  Widget _box(BuildContext context, ColorScheme scheme, int i, String text,
      double w, double h) {
    final filled = i < text.length;
    final active = _focus.hasFocus &&
        (i == text.length || (i == widget.length - 1 && text.length == widget.length));
    final border = widget.hasError
        ? scheme.error
        : (active ? scheme.primary : scheme.outline);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: w,
      height: h,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: widget.enabled
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border, width: active || widget.hasError ? 2 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            filled ? text[i] : '',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700, color: scheme.onSurface),
          ),
        ),
      ),
    );
  }
}
