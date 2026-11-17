# Assisto Bangladesh vehicle model (`assisto_vehicle_bd_nano.onnx`)

**What it is.** A version of YOLOX-Nano retrained to find vehicles common on Bangladeshi streets, including CNG
auto-rickshaws, cycle and van rickshaws, legunas, bikes, cars, microbuses, pickups, buses and trucks. It runs only on the
Assisto Shop Box, and only for cameras that have parking, no-parking or vehicle gate-line zones. Phones see people only.
It detects vehicles only. It never detects faces and never identifies people.

- **Input and output:** 416 x 416 BGR, letterboxed with value 114. The output has 85 columns: box, objectness and the
  80 COCO class scores. The box reads vehicle classes 1, 2, 3, 5 and 7 (shopbox/person.py).
- **SHA-256:** `@SHA256@` (pinned in edge/shopbox/shopbox/model_fetch.py). The box refuses any other file.
- **Built by:** tools/e2e/cctv_vehicle_train.py in CI, run @RUN@ on commit @COMMIT@.

## Sources and licences
- **Starting weights and code:** YOLOX-Nano weights and the YOLOX 0.3.0 code by Megvii (Apache License 2.0),
  from https://github.com/Megvii-BaseDetection/YOLOX
- **Training photos (CC BY 4.0):** the train/ folders of "Multi-Class Vehicle Detection Dataset for Dense and
  Heterogeneous Urban Traffic in Bangladesh" by Rahman A., Munim Shahriar S., Awsaf S.A., Jahan I., Ferdous J. and
  Chowdhury M.J.U. (Leading University, Sylhet), Mendeley Data v2, DOI 10.17632/tx6699m24b.2,
  https://data.mendeley.com/datasets/tx6699m24b/2. Licence: https://creativecommons.org/licenses/by/4.0/.
  **Changes made:** photos were resized to 640 x 360, then augmented during training (crop, flip, colour, grey IR,
  blur, noise, JPEG). The 11 local classes were mapped to COCO vehicle ids. This model is built on that data; the
  dataset's authors do not endorse it.
- **Vehicle-free example photos:** COCO train2017 images whose own licence is CC BY 2.0, CC BY-SA 2.0,
  "no known copyright restrictions" or US Government work. The COCO annotations are CC BY 4.0
  (https://cocodataset.org).
- **Not used for training:** the Sylhet valid/ folder, used to choose settings, and test/ folder, used for the
  reported numbers. COCO val2017 was not used either.

## Honest limits
- All the photos come from one city and were taken with a phone at street level, not from a CCTV mounting height.
- The precision and recall measured by CI appear in edge/shopbox/shopbox/cctv_thresholds.json under "measured".
- Vehicle alerts are logged and go into the daily report; they do not ring unless the owner turns ringing on for that
  zone.
