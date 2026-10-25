import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/app_localizations.dart';

/// A password / PIN text field that starts obscured and adds a trailing
/// show/hide "eye" toggle. Drop-in replacement for a `TextField` that had
/// `obscureText: true`.
///
/// Preserves the host field's styling: pass the field's existing
/// [InputDecoration] via [decoration] and the eye toggle is threaded into its
/// `suffixIcon` (keeping any labelText/hintText/helperText/errorText/border it
/// already had). If no [decoration] is given, [labelText]/[hintText] are used.
///
/// Toggling obscure state is local to this widget, so it never loses focus or
/// clears the entered text, and it works fine as a child of an `AlertDialog`.
class ObscureTextField extends StatefulWidget {
  const ObscureTextField({
    super.key,
    required this.controller,
    this.labelText,
    this.hintText,
    this.decoration,
    this.keyboardType,
    this.textInputAction,
    this.maxLength,
    this.autofocus = false,
    this.enabled,
    this.inputFormatters,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? labelText;
  final String? hintText;

  /// Existing decoration to preserve (label, helper, border, prefixIcon, etc.).
  /// The eye toggle is injected as its `suffixIcon`.
  final InputDecoration? decoration;

  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final int? maxLength;
  final bool autofocus;
  final bool? enabled;
  final List<TextInputFormatter>? inputFormatters;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  State<ObscureTextField> createState() => _ObscureTextFieldState();
}

class _ObscureTextFieldState extends State<ObscureTextField> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final toggle = IconButton(
      tooltip: _obscure ? t.pwShow : t.pwHide,
      icon: Icon(_obscure
          ? Icons.visibility_rounded
          : Icons.visibility_off_rounded),
      onPressed: () => setState(() => _obscure = !_obscure),
    );

    final base = widget.decoration ??
        InputDecoration(
          labelText: widget.labelText,
          hintText: widget.hintText,
        );
    final decoration = base.copyWith(suffixIcon: toggle);

    return TextField(
      controller: widget.controller,
      obscureText: _obscure,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      maxLength: widget.maxLength,
      autofocus: widget.autofocus,
      enabled: widget.enabled,
      inputFormatters: widget.inputFormatters,
      autofillHints: widget.autofillHints,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      decoration: decoration,
    );
  }
}
