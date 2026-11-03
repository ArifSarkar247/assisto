/// farmer_crop_data.dart — p3farm: the per-crop calendar and the guided
/// symptom picker behind Farmer mode's Help + Calendar tabs.
///
/// PURE DATA + tiny pure helpers (no network, no AI, no wall-clock: callers
/// pass the month). Machine tokens only — every user-facing word is an
/// AppLocalizations getter in the screen (zero Bangla literals here).
///
/// SOURCES (checked 3 Nov 2026; mirrored in backend/core/logic/farmer_mode.py
/// CROP_CALENDAR so the lock-step test can compare):
///   * rice (Aman / Boro / Aus) — Bangladesh Rice Research Institute (BRRI)
///     seasons: Aus mid-Mar–mid-Jul, T. Aman mid-Jul–mid-Nov (seedbed Jun–Jul),
///     Boro mid-Nov–mid-Mar seedbed/transplant, harvest Apr–May;
///   * jute — Bangladesh Jute Research Institute (BJRI);
///   * potato, mustard, vegetables — Bangladesh Agricultural Research
///     Institute (BARI);
///   * wheat — Bangladesh Wheat and Maize Research Institute (BWMRI).
/// These are BROAD month windows. Area and variety shift them, so the screen
/// always says "ask your Upazila Agriculture Officer / call 16123".
///
/// The symptom picker lists only well-known, field-recognisable problems
/// from those institutes' public IPM material. It NEVER gives a pesticide,
/// dose or mix: the screen shows signs + general field care + official links +
/// the 16123 call. It is a guide, not a diagnosis.
library;

/// Official source code -> URL (opened in the browser from the screen).
const Map<String, String> kFarmSourceUrls = {
  'brri': 'https://brri.gov.bd',
  'bjri': 'https://bjri.gov.bd',
  'bari': 'https://bari.gov.bd',
  'bwmri': 'https://bwmri.gov.bd',
  'dae': 'https://dae.gov.bd',
  'ais': 'https://ais.gov.bd',
  'janala': 'http://www.krishokerjanala.gov.bd',
  'bamis': 'https://www.bamis.gov.bd',
  'dam': 'https://dam.gov.bd',
};

/// Krishi Call Centre (Agriculture Information Service) — short code.
const String kKrishiCallCentre = '16123';

class CropPlan {
  final String crop; // stable token, localised in the screen
  final List<int> sow; // seedbed / sowing months
  final List<int> transplant; // transplanting months ([] = direct sown)
  final List<int> harvest;
  final String source; // key of kFarmSourceUrls
  const CropPlan(this.crop, this.sow, this.transplant, this.harvest, this.source);

  /// The jobs that fall in [month]: any of 'sow', 'transplant', 'harvest'.
  List<String> jobsIn(int month) => [
        if (sow.contains(month)) 'sow',
        if (transplant.contains(month)) 'transplant',
        if (harvest.contains(month)) 'harvest',
      ];
}

/// Major Bangladeshi crops, in the order farmers think of them.
const List<CropPlan> kCropCalendar = [
  CropPlan('aman_rice', [6, 7], [7, 8], [11, 12], 'brri'),
  CropPlan('boro_rice', [11, 12], [12, 1, 2], [4, 5], 'brri'),
  CropPlan('aus_rice', [3, 4], [4, 5], [7, 8], 'brri'),
  CropPlan('jute', [3, 4], [], [7, 8], 'bjri'),
  CropPlan('potato', [11, 12], [], [2, 3], 'bari'),
  CropPlan('wheat', [11, 12], [], [3], 'bwmri'),
  CropPlan('mustard', [10, 11], [], [1, 2], 'bari'),
  CropPlan('winter_veg', [9, 10, 11], [], [12, 1, 2], 'bari'),
  CropPlan('summer_veg', [2, 3, 4], [], [5, 6, 7, 8], 'bari'),
];

/// Crops that have a job this [month] (for the "this month" strip).
List<CropPlan> cropsActiveIn(int month) =>
    [for (final c in kCropCalendar) if (c.jobsIn(month).isNotEmpty) c];

/// One recognisable problem: token + the official page to read more.
class FarmProblem {
  final String id; // localised: name / what you see / general care
  final String source;
  const FarmProblem(this.id, this.source);
}

/// Crop group -> problems (symptom picker). Groups: rice, potato, jute, veg.
const Map<String, List<FarmProblem>> kFarmProblems = {
  'rice': [
    FarmProblem('rice_blast', 'brri'),
    FarmProblem('rice_blight', 'brri'),
    FarmProblem('rice_bph', 'brri'),
    FarmProblem('rice_borer', 'brri'),
  ],
  'potato': [
    FarmProblem('potato_late_blight', 'bari'),
    FarmProblem('potato_wilt', 'bari'),
  ],
  'jute': [
    FarmProblem('jute_stem_rot', 'bjri'),
  ],
  'veg': [
    FarmProblem('brinjal_borer', 'bari'),
    FarmProblem('gourd_fruit_fly', 'bari'),
  ],
};

const List<String> kFarmProblemGroups = ['rice', 'potato', 'jute', 'veg'];
