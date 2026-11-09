"""quranpron — app API for the rule-based Bangla pronunciation (no AI).

  GET /api/v1/quran/pron/<surah>[?ayah=N]
   -> {ok, surah, engine_version, label: "under_review", source, legend_bn,
       items: [{ayah, bn, review, spans, rules, note_bn?}], bismillah_bn?}

`review` is "approved" only when an alem / qari approved exactly this output
in Owner Admin (/owner/quran-pron); the app shows "যাচাই চলছে" otherwise.
`spans` = [[start, end, rule], ...] over `bn` for tajweed colours.
"""
from rest_framework.response import Response
from rest_framework.views import APIView

from . import quran_pron as QP
from . import quran_pron_review as RV

LEGEND_BN = ("উচ্চারণের চিহ্ন: '-' = ২ হরকত টানুন, '--' = ৪ হরকত, '---' = ৬ হরকত; "
             "'ঁ' = গুন্নাহ (নাকে ২ হরকত); 'ং' = ইখফা; '্' = স্বরহীন অক্ষর; "
             "'।' = এখানে থামুন; ',' = না থেমে পড়া যায়; '—' = সাকতা (শ্বাস না নিয়ে সামান্য থামা)।")
NOTE_BN = "একজন আলেম এই আয়াতের উচ্চারণ ঠিক করতে বলেছেন — সংশোধন চলছে। আরবি দেখে পড়ুন।"


class QuranPronView(APIView):
    def get(self, request, surah):
        if not 1 <= surah <= 114:
            return Response({"ok": False, "reason": "unknown_surah"}, status=404)
        try:
            items = QP.surah_items(surah)
        except (OSError, QP.PronError):
            return Response({"ok": False, "reason": "text_unavailable"}, status=503)
        want = request.query_params.get("ayah")
        if want is not None:
            try:
                want = int(want)
            except ValueError:
                return Response({"ok": False, "reason": "bad_ayah"}, status=400)
            items = [x for x in items if x[0] == want]
            if not items:
                return Response({"ok": False, "reason": "unknown_ayah"}, status=404)
        st = RV.status_map(surah)
        out = []
        for a, _, r in items:
            review = st.get(a, {}).get("status", "under_review")
            it = {"ayah": a, "bn": r["bn"], "review": review, "spans": r["spans"],
                  "rules": r["rules"]}
            if review in ("rejected", "needs_fix"):
                it["note_bn"] = NOTE_BN
            out.append(it)
        body = {"ok": True, "surah": surah, "engine_version": QP.ENGINE_VERSION,
                "label": "under_review", "source": QP.SOURCE_LABEL,
                "method": "rule_based_no_ai", "legend_bn": LEGEND_BN, "items": out}
        if QP.has_bismillah(surah):
            body["bismillah_bn"] = QP.bismillah_bn()
        resp = Response(body)
        resp["Cache-Control"] = "private, max-age=3600"
        return resp
