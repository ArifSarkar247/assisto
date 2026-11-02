// cctvevidence (W7): fake server for the camera's Recording & evidence
// screen (widget tests + screenshot gallery). Shapes = backend/core/cctv_evidence.py.
import 'package:assisto/api.dart';
import 'package:assisto/cctvx/cctv_evidence_source.dart';

Map<String, dynamic> fakeRecording({
  String sd = 'ok',
  String label = 'SD card OK',
  num? days = 5.8,
  bool active = false,
  bool supported = true,
  String supportText = '',
  int today = 3,
}) =>
    {
      'camera_id': 11,
      'vendor': supported ? 'ezviz' : 'imou',
      'site_id': 1,
      'sd': {
        'state': sd, 'label': label, 'days': days, 'total_bytes': days == null ? null : 64000000000,
        'used_bytes': null, 'source': 'imou', 'checked_at': '2026-11-03T09:30:00+06:00',
        'reason': days == null ? 'size_not_reported' : '',
      },
      'addon': {
        'active': active,
        'tier': active ? '30d' : null,
        'active_until': active ? '2026-12-03T09:30:00+06:00' : null,
        'last_tier': active ? '30d' : null,
        'tiers': [
          {'tier': '7d', 'days': 7, 'price_tk': 100, 'credits': 100, 'play_product': 'cctv_video_7d'},
          {'tier': '30d', 'days': 30, 'price_tk': 150, 'credits': 150, 'play_product': 'cctv_video_30d'},
        ],
        'photo_days': active ? 30 : 7,
        'base_photo_days': 7,
      },
      'clips': {'today': today, 'max_per_day': 30, 'seconds': 10},
      'clip_support': {
        'supported': supported,
        'reason': supported ? null : 'imou_no_download',
        'text': supported ? null : supportText,
      },
      'storage': 'local_encrypted',
      'address': '12 Mirpur Road, Dhaka',
    };

class FakeCctvEvidence implements CctvEvidenceSource {
  final String mode; // '' | 'fail' | 'nocredit' | 'imou'
  final calls = <String>[];
  FakeCctvEvidence([this.mode = '']);

  @override
  Future<Map<String, dynamic>> recording(int cameraId, {bool refresh = false}) async {
    calls.add('recording:$cameraId:$refresh');
    if (mode == 'fail') throw ApiException('offline', 0);
    if (mode == 'imou') {
      return fakeRecording(
          sd: 'ok',
          supported: false,
          supportText: "Imou's official API cannot download SD-card video — watch it in the Imou Life app.");
    }
    return fakeRecording();
  }

  @override
  Future<Map<String, dynamic>> buyAddon(int cameraId, String tier) async {
    calls.add('buy:$cameraId:$tier');
    if (mode == 'nocredit') {
      throw ApiException('Not enough credits.', 402, null, 'no_credits', {'error': 'no_credits'});
    }
    return fakeRecording(active: true);
  }

  @override
  Future<Map<String, dynamic>> saveAddress(int siteId, String address) async {
    calls.add('address:$siteId:$address');
    return {'ok': true, 'address': address};
  }
}
