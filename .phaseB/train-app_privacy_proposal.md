# train-app: privacy-policy proposal (Train Tracker V2, mobile tower IDs)

Target: `backend/web/legal_content.py` -> `_TRAIN` section, add ONE bullet to its `UL(...)`
(after "What is sent"). Bump `LAST_UPDATED_V2` when the integrator applies it. Play data-safety:
the lead handles it.

```python
       ("<b>মোবাইল টাওয়ার (ঐচ্ছিক):</b> শেয়ারের সময় আপনি আলাদা সুইচে রাজি হলে তবেই ফোনের মোবাইল টাওয়ারের "
        "নম্বর (MCC, MNC, LAC/TAC, Cell ID) অবস্থানের সাথে যায় — বেনামে, শুধু ট্রেনের অবস্থান বের করতে। "
        "আপনার কল, SMS বা ফোন নম্বর কখনো নয়।",
        "<b>Mobile tower (optional):</b> only if you turn on its separate switch while sharing, your phone's "
        "mobile tower ID (MCC, MNC, LAC/TAC, Cell ID) is sent with each position — anonymously and used only "
        "to place trains. Never your calls, SMS or phone number."),
```

Source of truth in the app: the switch `tr2_cell_optin` (off by default) on the share consent sheet
(app/lib/screens/train/train_v2_widgets.dart); the tower is read by
TrainV2Channel.servingCell (needs only the location permission already granted; no READ_PHONE_STATE).
