import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';

/// GLOBAL RULE (owner order 21 Oct, after "Phone Safety Check-up spins
/// forever"): every loading state ends in CONTENT, an EMPTY state, or an
/// ERROR WITH RETRY within [kLoadTimeout]. Never an endless spinner.
///
/// * [loadGuard] — wrap any load future: it completes, or throws a
///   [TimeoutException] after 15 s.
/// * [LoadingGate] — a widget that runs a loader through [loadGuard] and shows
///   spinner -> content / empty / [LoadErrorRetry].
/// * [LoadErrorRetry] — the one honest error+Retry view (keys `load-error`,
///   `load-retry`).
const Duration kLoadTimeout = Duration(seconds: 15);

Future<T> loadGuard<T>(Future<T> future, {Duration timeout = kLoadTimeout}) =>
    future.timeout(timeout);

class LoadingGate<T> extends StatefulWidget {
  const LoadingGate({
    super.key,
    required this.load,
    required this.builder,
    this.isEmpty,
    this.emptyBuilder,
    this.timeout = kLoadTimeout,
    this.errorTitle,
    this.errorBody,
  });

  final Future<T> Function() load;
  final Widget Function(BuildContext context, T data, Future<void> Function() reload)
      builder;
  final bool Function(T data)? isEmpty;
  final WidgetBuilder? emptyBuilder;
  final Duration timeout;
  final String? errorTitle;
  final String? errorBody;

  @override
  State<LoadingGate<T>> createState() => _LoadingGateState<T>();
}

class _LoadingGateState<T> extends State<LoadingGate<T>> {
  bool _loading = true;
  Object? _error;
  T? _data;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    final gen = ++_gen;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final d = await loadGuard(widget.load(), timeout: widget.timeout);
      if (!mounted || gen != _gen) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
          key: Key('load-spinner'), child: CircularProgressIndicator());
    }
    if (_error != null) {
      return LoadErrorRetry(
          title: widget.errorTitle, body: widget.errorBody, onRetry: _run);
    }
    final d = _data as T;
    if (widget.isEmpty?.call(d) == true && widget.emptyBuilder != null) {
      return widget.emptyBuilder!(context);
    }
    return widget.builder(context, d, _run);
  }
}

/// The honest "couldn't load" state with a Retry button. [compact] renders a
/// one-row banner (for a section inside a list) instead of a centred block.
class LoadErrorRetry extends StatelessWidget {
  const LoadErrorRetry({
    super.key,
    this.title,
    this.body,
    required this.onRetry,
    this.compact = false,
  });

  final String? title;
  final String? body;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final retry = FilledButton.tonalIcon(
      key: const Key('load-retry'),
      onPressed: onRetry,
      icon: const Icon(Icons.refresh),
      label: Text(t.retry),
    );
    if (compact) {
      return Container(
        key: const Key('load-error'),
        margin: const EdgeInsets.fromLTRB(Gap.md, Gap.sm, Gap.md, Gap.xs),
        padding: const EdgeInsets.all(Gap.md),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(children: [
          Icon(Icons.cloud_off_outlined, color: scheme.onErrorContainer),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Text(body ?? t.qaLoadFailedRetry,
                style: TextStyle(color: scheme.onErrorContainer, height: 1.35)),
          ),
          const SizedBox(width: Gap.sm),
          retry,
        ]),
      );
    }
    return Center(
      key: const Key('load-error'),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_off_outlined, size: 48, color: scheme.error),
          const SizedBox(height: Gap.md),
          Text(title ?? t.loadFailed,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Gap.xs),
          Text(body ?? t.qaLoadFailedRetry,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.4)),
          const SizedBox(height: Gap.md),
          retry,
        ]),
      ),
    );
  }
}
