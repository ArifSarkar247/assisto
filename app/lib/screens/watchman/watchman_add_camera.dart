import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'watchman_source.dart';
import 'watchman_widgets.dart';
import 'watchman_zones.dart';

/// cctv1 camera onboarding + COMPATIBILITY CHECK. The phone cannot reach LAN
/// cameras from the internet, so the GATEWAY runs the check (reachable? auth
/// ok? stream opens? fps/resolution? snapshot? events?) and we show its result
/// card with honest fixes. The password / safety code is handed to the
/// gateway once and never kept on our server.
///
/// Old-phone gateway (phase 1): its own camera, plus Imou cloud alarms when
/// the owner has switched Imou on. LAN RTSP on the phone is phase 2.
class WatchmanAddCameraScreen extends StatefulWidget {
  final WatchmanSource source;
  final Map<String, dynamic> site;
  final Map<String, dynamic> limits;
  final int credits;
  final bool imouCloud;

  /// Re-run the check for this existing camera (skips picking the brand).
  final Map<String, dynamic>? recheck;
  final Duration pollEvery;

  /// Gallery/tests: start showing this task result.
  final Map<String, dynamic>? initialResult;
  const WatchmanAddCameraScreen({
    super.key,
    required this.source,
    required this.site,
    required this.limits,
    required this.credits,
    this.imouCloud = false,
    this.recheck,
    this.pollEvery = const Duration(seconds: 3),
    this.initialResult,
  });

  @override
  State<WatchmanAddCameraScreen> createState() => _WatchmanAddCameraScreenState();
}

enum _Stage { pick, form, checking, result, phoneDone, cloudDone }

class _WatchmanAddCameraScreenState extends State<WatchmanAddCameraScreen> {
  _Stage _stage = _Stage.pick;
  String _vendor = '';
  Map<String, dynamic>? _camera;
  Map<String, dynamic>? _task;
  String? _error;
  bool _busy = false;
  bool _scanning = false;
  List<Map<String, dynamic>> _found = const [];
  Timer? _timer;
  int _polls = 0;

  final _name = TextEditingController();
  final _host = TextEditingController();
  final _channel = TextEditingController(text: '1');
  final _user = TextEditingController(text: 'admin');
  final _secret = TextEditingController();
  final _rtsp = TextEditingController();
  final _serial = TextEditingController();
  String _stream = 'sub';
  bool _hideSecret = true;

  bool get _phoneGw => widget.site['gateway'] == 'phone';

  @override
  void initState() {
    super.initState();
    final r = widget.recheck;
    if (r != null) {
      _camera = r;
      _vendor = (r['vendor'] ?? '').toString();
      final src = wmMap(r['source']);
      _name.text = (r['name'] ?? '').toString();
      _host.text = (src['host'] ?? '').toString();
      _channel.text = (src['channel'] ?? 1).toString();
      _user.text = (src['username'] ?? 'admin').toString();
      _stream = (src['stream'] ?? 'sub').toString();
      _stage = _Stage.form;
    }
    if (widget.initialResult != null) {
      _task = widget.initialResult;
      _vendor = (wmMap(_task!['request'])['vendor'] ?? _vendor).toString();
      _stage = _Stage.result;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final c in [_name, _host, _channel, _user, _secret, _rtsp, _serial]) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _vendors => _phoneGw
      ? ['phone', if (widget.imouCloud) 'imou']
      : ['imou', 'hikvision', 'dahua', 'tapo', 'ezviz', 'onvif', 'rtsp'];

  bool get _fixedAdmin => _vendor == 'imou' || _vendor == 'ezviz';

  String _secretLabel(AppLocalizations t) => switch (_vendor) {
        'imou' => t.wmSecretImou,
        'ezviz' => t.wmSecretEzviz,
        'tapo' => t.wmSecretTapo,
        _ => t.wmSecretPassword,
      };

  String _vendorHelp(AppLocalizations t) => switch (_vendor) {
        'imou' => _phoneGw ? t.wmHelpImouCloud : t.wmHelpImou,
        'hikvision' => t.wmHelpHik,
        'dahua' => t.wmHelpDahua,
        'tapo' => t.wmHelpTapo,
        'ezviz' => t.wmHelpEzviz,
        'onvif' => t.wmHelpOnvif,
        'rtsp' => t.wmHelpRtsp,
        'phone' => t.wmHelpPhone,
        _ => '',
      };

  Future<void> _submit() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var cam = _camera;
      if (cam == null) {
        final ch = int.tryParse(_channel.text.trim()) ?? 1;
        cam = await widget.source.addCamera((widget.site['id'] as num).toInt(), {
          'name': _name.text.trim().isEmpty ? wmVendorName(t, _vendor) : _name.text.trim(),
          'kind': 'shopbox',
          'vendor': _vendor,
          'source': {
            if (_host.text.trim().isNotEmpty) 'host': _host.text.trim(),
            'port': 554,
            'channel': ch,
            'stream': _stream,
            if (!_fixedAdmin && _user.text.trim().isNotEmpty) 'username': _user.text.trim(),
          },
        });
        _camera = cam;
      }
      final camId = (cam['id'] as num).toInt();
      if (_vendor == 'phone') {
        setState(() {
          _busy = false;
          _stage = _Stage.phoneDone;
        });
        return;
      }
      if (_phoneGw && _vendor == 'imou') {
        await widget.source.linkImou(camId, _serial.text.trim(), _secret.text.trim());
        setState(() {
          _busy = false;
          _stage = _Stage.cloudDone;
        });
        return;
      }
      final task = await widget.source.queueCheck(camId, {
        'secret': _secret.text.trim(),
        if (!_fixedAdmin) 'username': _user.text.trim(),
        if (_host.text.trim().isNotEmpty) 'host': _host.text.trim(),
        'channel': int.tryParse(_channel.text.trim()) ?? 1,
        'stream': _stream,
        if (_vendor == 'rtsp') 'rtsp_url': _rtsp.text.trim(),
      });
      _secret.clear(); // never kept on this phone either
      _task = task;
      _polls = 0;
      setState(() {
        _busy = false;
        _stage = _Stage.checking;
      });
      _poll();
    } catch (e) {
      setState(() {
        _busy = false;
        _error = wmError(e) ?? t.wmGenericError;
      });
    }
  }

  void _poll() {
    _timer?.cancel();
    _timer = Timer(widget.pollEvery, () async {
      if (!mounted || _task == null) return;
      _polls++;
      try {
        final t = await widget.source.task((_task!['id'] as num).toInt());
        _task = t;
        final st = t['status'];
        if (st == 'done' || st == 'expired') {
          if (mounted) setState(() => _stage = _Stage.result);
          return;
        }
      } catch (_) {
        // offline for a moment: keep waiting (honest spinner text says so)
      }
      if (_polls >= 40) {
        if (mounted) {
          setState(() {
            _task = {...?_task, 'status': 'expired', 'result': {'ok': false, 'code': 'gateway_no_answer'}};
            _stage = _Stage.result;
          });
        }
        return;
      }
      if (mounted) {
        setState(() {});
        _poll();
      }
    });
  }

  Future<void> _scan() async {
    final t = AppLocalizations.of(context);
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      var task = await widget.source.discover((widget.site['id'] as num).toInt());
      for (var i = 0; i < 15 && mounted; i++) {
        if (task['status'] == 'done' || task['status'] == 'expired') break;
        await Future<void>.delayed(widget.pollEvery);
        task = await widget.source.task((task['id'] as num).toInt());
      }
      final res = wmMap(task['result']);
      _found = wmList(res['discovered']);
      if (task['status'] != 'done') _error = t.wmScanNoAnswer;
      if (task['status'] == 'done' && _found.isEmpty) _error = t.wmScanNone;
    } catch (e) {
      _error = wmError(e) ?? t.wmGenericError;
    }
    if (mounted) setState(() => _scanning = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.recheck != null ? t.wmCheckAgain : t.wmAddCamera)),
      body: switch (_stage) {
        _Stage.pick => _pick(t),
        _Stage.form => _form(t),
        _Stage.checking => _checking(t),
        _Stage.result => _result(t),
        _Stage.phoneDone => _done(t, t.wmPhoneCamDoneTitle, t.wmPhoneCamDoneBody),
        _Stage.cloudDone => _done(t, t.wmCloudDoneTitle, t.wmCloudDoneBody),
      },
    );
  }

  Widget _pick(AppLocalizations t) {
    final lang = wmLang(context);
    final included = (widget.limits['included_cameras'] as num?)?.toInt() ?? 0;
    final cost = (widget.limits['credits_per_extra_camera'] as num?)?.toInt() ?? 0;
    final days = (widget.limits['period_days'] as num?)?.toInt() ?? 30;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
      Text(t.wmPickBrand, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(_phoneGw ? t.wmPickBrandPhoneGw : t.wmPickBrandPcGw),
      const SizedBox(height: 8),
      for (final v in _vendors)
        ListTile(
          minVerticalPadding: 12,
          leading: Icon(v == 'phone' ? Icons.phone_android_rounded : Icons.videocam_rounded),
          title: Text(wmVendorName(t, v)),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => setState(() {
            _vendor = v;
            _user.text = v == 'tapo' ? '' : 'admin';
            _stage = _Stage.form;
          }),
        ),
      if (_phoneGw) ...[
        const SizedBox(height: 8),
        Text(widget.imouCloud ? t.wmPhoneGwLanLater : t.wmPhoneGwLanLaterNoImou,
            style: Theme.of(context).textTheme.bodySmall),
      ],
      const Divider(height: 28),
      Text(t.wmCostLine(wmDigits(lang, included), wmDigits(lang, cost), wmDigits(lang, days),
          wmDigits(lang, widget.credits))),
    ]);
  }

  Widget _form(AppLocalizations t) {
    final lang = wmLang(context);
    final cloud = _phoneGw && _vendor == 'imou';
    final needsHost = !cloud && _vendor != 'rtsp' && _vendor != 'phone';
    final channelVendors = {'imou', 'dahua', 'hikvision'};
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
      Text(wmVendorName(t, _vendor), style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 6),
      Text(_vendorHelp(t)),
      const SizedBox(height: 14),
      if (_camera == null)
        TextField(
          controller: _name,
          maxLength: 60,
          decoration: InputDecoration(
              labelText: t.wmCamName, hintText: t.wmCamNameHint, border: const OutlineInputBorder()),
        ),
      if (cloud) ...[
        TextField(
          controller: _serial,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(labelText: t.wmImouSerial, border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
      ],
      if (needsHost) ...[
        TextField(
          controller: _host,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
              labelText: t.wmCamIp, hintText: '192.168.1.20', border: const OutlineInputBorder()),
        ),
        if (!_phoneGw)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: _scanning ? null : _scan,
              icon: _scanning
                  ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.wifi_find_rounded),
              label: Text(_scanning ? t.wmScanning : t.wmScan),
            ),
          ),
        for (final f in _found)
          ListTile(
            leading: const Icon(Icons.videocam_outlined),
            title: Text((f['host'] ?? '').toString()),
            subtitle: Text([f['manufacturer'], f['model'], f['name']]
                .where((x) => x != null && x.toString().isNotEmpty)
                .join(' · ')),
            onTap: () => setState(() => _host.text = (f['host'] ?? '').toString()),
          ),
        const SizedBox(height: 12),
      ],
      if (_vendor == 'rtsp') ...[
        TextField(
          controller: _rtsp,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
              labelText: t.wmRtspUrl,
              hintText: 'rtsp://user:pass@192.168.1.20:554/stream',
              border: const OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
      ],
      if (!cloud && _vendor != 'phone' && _vendor != 'rtsp') ...[
        if (!_fixedAdmin) ...[
          TextField(
            controller: _user,
            decoration: InputDecoration(
                labelText: _vendor == 'tapo' ? t.wmTapoUser : t.wmUser,
                border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
        ],
        if (channelVendors.contains(_vendor)) ...[
          TextField(
            controller: _channel,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: t.wmChannel, helperText: t.wmChannelHelp, border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
        ],
      ],
      if (_vendor != 'phone' && _vendor != 'rtsp') ...[
        TextField(
          controller: _secret,
          obscureText: _hideSecret,
          decoration: InputDecoration(
            labelText: _secretLabel(t),
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: _hideSecret ? t.wmShow : t.wmHide,
              icon: Icon(_hideSecret ? Icons.visibility_rounded : Icons.visibility_off_rounded),
              onPressed: () => setState(() => _hideSecret = !_hideSecret),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(t.wmSecretPrivacy, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
      ],
      if (!cloud && _vendor != 'phone') ...[
        Text(t.wmStream, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'sub', label: Text(t.wmStreamSub)),
            ButtonSegment(value: 'main', label: Text(t.wmStreamMain)),
          ],
          selected: {_stream},
          onSelectionChanged: (s) => setState(() => _stream = s.first),
        ),
        const SizedBox(height: 4),
        Text(t.wmStreamHelp, style: Theme.of(context).textTheme.bodySmall),
      ],
      if (_error != null) ...[
        const SizedBox(height: 12),
        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      const SizedBox(height: 18),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
        onPressed: _busy ? null : _submit,
        child: _busy
            ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
            : Text(_vendor == 'phone'
                ? t.wmAddThisCamera
                : cloud
                    ? t.wmLinkImou
                    : t.wmRunCheck),
      ),
      if (_camera == null && _vendor != 'phone') ...[
        const SizedBox(height: 8),
        Text(t.wmCheckCostNote(wmDigits(lang, (widget.limits['credits_per_extra_camera'] as num?)?.toInt() ?? 0)),
            style: Theme.of(context).textTheme.bodySmall),
      ],
    ]);
  }

  Widget _checking(AppLocalizations t) {
    final gw = wmMap(_task?['gateway']);
    return ListView(padding: const EdgeInsets.all(24), children: [
      const SizedBox(height: 30),
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: 20),
      Text(t.wmChecking, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 8),
      Text(gw['online'] == true ? t.wmCheckingBody : '${t.wmCheckingGwOffline} ${wmGatewayLine(t, context, gw)}',
          textAlign: TextAlign.center),
    ]);
  }

  String _stepName(AppLocalizations t, String k) => switch (k) {
        'reachable' => t.wmStepReachable,
        'auth' => t.wmStepAuth,
        'stream' => t.wmStepStream,
        'snapshot' => t.wmStepSnapshot,
        _ => t.wmStepEvents,
      };

  /// The honest fix for a failed step (vendor-aware).
  String? _fix(AppLocalizations t, String key, String code) {
    if (key == 'reachable') return t.wmFixUnreachable;
    if (key == 'auth') {
      return switch (_vendor) {
        'imou' => t.wmFixAuthImou,
        'tapo' => t.wmFixAuthTapo,
        'ezviz' => t.wmFixAuthEzviz,
        _ => t.wmFixAuth,
      };
    }
    if (key == 'stream') return code == 'timeout' ? t.wmFixTimeout : t.wmFixStream;
    if (key == 'snapshot') return t.wmFixSnapshot;
    return null;
  }

  Widget _result(AppLocalizations t) {
    final lang = wmLang(context);
    final res = wmMap(_task?['result']);
    final ok = res['ok'] == true;
    final expired = _task?['status'] == 'expired';
    final steps = wmList(res['steps']);
    final info = wmMap(res['info']);
    final cam = _camera;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 24), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(ok ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                  color: ok ? wmOk() : wmBad(), size: 30),
              const SizedBox(width: 10),
              Expanded(
                child: Text(ok ? t.wmResultOk : (expired ? t.wmResultNoAnswer : t.wmResultFailed),
                    style: Theme.of(context).textTheme.titleMedium),
              ),
            ]),
            if (expired) ...[
              const SizedBox(height: 8),
              Text(t.wmFixGatewayNoAnswer),
            ],
            if (ok && info['width'] != null) ...[
              const SizedBox(height: 8),
              Text(t.wmResultInfo(
                  wmDigits(lang, info['width']), wmDigits(lang, info['height'] ?? ''),
                  wmDigits(lang, (info['fps'] ?? '').toString()))),
            ],
            const SizedBox(height: 8),
            for (final s in steps)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(
                    s['ok'] == true
                        ? Icons.check_rounded
                        : s['ok'] == false
                            ? Icons.close_rounded
                            : Icons.remove_rounded,
                    color: s['ok'] == true ? wmOk() : (s['ok'] == false ? wmBad() : wmWarn()),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_stepName(t, (s['key'] ?? '').toString()),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (s['ok'] == false && _fix(t, s['key'].toString(), (s['code'] ?? '').toString()) != null)
                        Text(_fix(t, s['key'].toString(), (s['code'] ?? '').toString())!),
                      if (s['ok'] == null)
                        Text(s['key'] == 'events' ? t.wmEventsNotChecked : t.wmStepSkipped,
                            style: Theme.of(context).textTheme.bodySmall),
                    ]),
                  ),
                ]),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      if (ok && cam != null)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.draw_rounded),
          label: Text(t.wmDrawZonesNow),
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => WatchmanZonesScreen(source: widget.source, camera: cam))),
        ),
      if (!ok)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t.wmFixAndRetry),
          onPressed: () => setState(() {
            _stage = _Stage.form;
            _error = null;
          }),
        ),
      const SizedBox(height: 8),
      OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(t.wmDone),
      ),
    ]);
  }

  Widget _done(AppLocalizations t, String title, String body) {
    final cam = _camera;
    return ListView(padding: const EdgeInsets.all(24), children: [
      Icon(Icons.check_circle_rounded, size: 56, color: wmOk()),
      const SizedBox(height: 12),
      Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      Text(body, textAlign: TextAlign.center),
      const SizedBox(height: 20),
      if (cam != null)
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(48, 52)),
          icon: const Icon(Icons.schedule_rounded),
          label: Text(t.wmZonesSchedule),
          onPressed: () => Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) => WatchmanZonesScreen(source: widget.source, camera: cam))),
        ),
      const SizedBox(height: 8),
      OutlinedButton(
        style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(t.wmDone),
      ),
    ]);
  }
}
