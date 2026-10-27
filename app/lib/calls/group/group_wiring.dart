import '../../api.dart';
import '../../realtime/realtime_transport.dart';
import '../api_call_signaling.dart';
import '../call_controller.dart';
import '../media_ext.dart';
import 'group_call.dart';
import 'group_call_api.dart';

/// callsB: the app wiring of a [GroupCallSession] — one real
/// [CallController] per pair link over the normal call signalling (each
/// with its own peer connection sharing [host]'s mic/camera).
GroupCallSession newGroupSession({
  required ApiClient api,
  required PollRealtimeTransport transport,
  required MeshHost host,
  CallController? primary,
  GroupRoster? roster,
}) =>
    GroupCallSession(
      api: ApiGroupCallApi(api, transport),
      host: host,
      primary: primary,
      roster: roster,
      newLinkMedia: host.createLinkMedia,
      makeLink: (link, media, video) => CallController(
        media: media,
        signaling: ApiCallSignaling(api, transport),
        sounds: const SilentCallSounds(),
        video: video,
        outgoing: link.offerer,
        preplaced: link.offerer,
        callId: link.callId,
      ),
    );
