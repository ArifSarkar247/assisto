import 'package:flutter/services.dart';

/// train-app (Train Tracker V2): the phone's serving cell tower. Read ONLY
/// while the rider shares the trip AND said yes to "also send the mobile
/// tower" (opt-in), or on the train screen in offline mode. Needs only the
/// location permission the trip already has (no READ_PHONE_STATE).
/// "mcc-mnc-tac-cid" with leading zeros dropped ("470-01" == "470-1"), so
/// the phone's key always matches the learned map's.
String trainTowerKey(Object? mcc, Object? mnc, Object? tac, Object? cid) {
  String n(Object? v) => '${int.tryParse('$v') ?? v}';
  return '${n(mcc)}-${n(mnc)}-${n(tac)}-${n(cid)}';
}

class TrainCell {
  final String mcc, mnc, rat;
  final int tac, cid;
  final int? dbm;
  const TrainCell(
      {required this.mcc,
      required this.mnc,
      required this.tac,
      required this.cid,
      this.rat = '',
      this.dbm});

  /// The tower key used by the offline tower map: "mcc-mnc-tac-cid".
  String get key => trainTowerKey(mcc, mnc, tac, cid);

  Map<String, dynamic> toJson() => {
        'mcc': mcc,
        'mnc': mnc,
        'tac': tac,
        'cid': cid,
        if (rat.isNotEmpty) 'rat': rat,
        if (dbm != null) 'dbm': dbm,
      };

  static TrainCell? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final mcc = raw['mcc'], mnc = raw['mnc'];
    final tac = (raw['tac'] as num?)?.toInt(), cid = (raw['cid'] as num?)?.toInt();
    if (mcc == null || mnc == null || tac == null || cid == null || cid <= 0) return null;
    return TrainCell(
        mcc: '$mcc',
        mnc: '$mnc',
        tac: tac,
        cid: cid,
        rat: '${raw['rat'] ?? ''}',
        dbm: (raw['dbm'] as num?)?.toInt());
  }
}

class TrainPower {
  final int? pct;
  final bool charging;
  const TrainPower(this.pct, this.charging);

  /// Battery saver for the rider service: under 20 % and not charging.
  bool get low => !charging && pct != null && pct! < 20;
}

/// Native bridge "com.assisto/train_v2" (TrainV2Channel.kt). Every call is
/// crash-guarded; tests replace [TrainNative.I].
class TrainNative {
  TrainNative();
  static TrainNative I = TrainNative();

  /// Widget tests / gallery: no GPS look-ups, no permission prompts.
  static bool disabledForTests = false;
  static const _ch = MethodChannel('com.assisto/train_v2');

  Future<TrainCell?> servingCell() async {
    try {
      return TrainCell.fromMap(await _ch.invokeMethod<Object?>('servingCell'));
    } catch (_) {
      return null; // no plugin / no SIM / not granted
    }
  }

  Future<TrainPower> power() async {
    try {
      final m = await _ch.invokeMethod<Map<Object?, Object?>>('power');
      return TrainPower((m?['pct'] as num?)?.toInt(), m?['charging'] == true);
    } catch (_) {
      return const TrainPower(null, false);
    }
  }

  /// "Share to Assisto" (16318 reply) is offered by Android only while the
  /// Train Tracker is on for this user.
  Future<void> setShareTarget(bool on) async {
    try {
      await _ch.invokeMethod<bool>('setShareTarget', {'on': on});
    } catch (_) {
      // best-effort: the paste button still works
    }
  }

  bool? _target;

  /// [setShareTarget] only when the wanted state changed (one IPC).
  Future<void> syncShareTarget(bool on) async {
    if (_target == on) return;
    _target = on;
    await setShareTarget(on);
  }

  Future<String?> takeSharedText() async {
    try {
      return await _ch.invokeMethod<String>('takeSharedText');
    } catch (_) {
      return null;
    }
  }
}
