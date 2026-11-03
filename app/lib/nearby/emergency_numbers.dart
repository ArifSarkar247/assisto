// nearby (owner 3 Nov 18:50): emergency numbers per country — OFFICIAL
// sources only, bundled in the app so they work with no network at all.
//
// The country is the one the phone is IN (pickEmergencyCountry): the mobile
// network's country first (a Bangladeshi SIM roaming in Riyadh -> Saudi
// Arabia), then the country of the nearest place in our own list for the
// GPS position (never paid geocoding), then the SIM's home country. The
// language stays the user's choice.
//
// Each country cites the official page its numbers were read from on
// 3 Nov 2026. `verified == false` = the official page could not be opened
// from our network that day (geo-blocked / down); those numbers are the ones
// the official services publish but the owner should re-check them
// (owner_actions/FEATURE_CARD_NEARBY_BN.md). Never a guessed number.

/// What a number is for — labelled via AppLocalizations in the UI.
enum EmergencyKind {
  all, // police + fire + ambulance on one number
  police,
  ambulance,
  fire,
  ambulanceFire,
  civilDefence,
  womenChild,
  child,
  womenFamily,
  health,
  healthNonEmergency,
  policeNonEmergency,
  crisis,
}

class EmergencyNumber {
  final String number;
  final EmergencyKind kind;
  const EmergencyNumber(this.number, this.kind);

  /// The digits to dial (tel: URI).
  String get dial => number.replaceAll(RegExp(r'[^0-9+]'), '');
}

class CountryEmergency {
  final String cc;
  final List<EmergencyNumber> numbers;
  final String source; // official page (display host + link)
  final bool verified;
  const CountryEmergency(this.cc, this.numbers, this.source,
      {this.verified = true});

  /// The number to put first (one-tap SOS-style call).
  EmergencyNumber get primary => numbers.first;
}

const kEmergencyByCountry = <String, CountryEmergency>{
  'BD': CountryEmergency('BD', [
    EmergencyNumber('999', EmergencyKind.all),
    EmergencyNumber('102', EmergencyKind.fire),
    EmergencyNumber('109', EmergencyKind.womenChild),
    EmergencyNumber('1098', EmergencyKind.child),
    EmergencyNumber('16263', EmergencyKind.health),
  ], 'https://dghs.gov.bd/ · https://fireservice.gov.bd/ · http://16263.dghs.gov.bd/'),
  'SA': CountryEmergency('SA', [
    EmergencyNumber('911', EmergencyKind.all),
    EmergencyNumber('999', EmergencyKind.police),
    EmergencyNumber('997', EmergencyKind.ambulance),
    EmergencyNumber('998', EmergencyKind.civilDefence),
  ], 'https://www.my.gov.sa/', verified: false),
  'AE': CountryEmergency('AE', [
    EmergencyNumber('999', EmergencyKind.police),
    EmergencyNumber('998', EmergencyKind.ambulance),
    EmergencyNumber('997', EmergencyKind.civilDefence),
  ], 'https://u.ae/en/help/contact-us'),
  'MY': CountryEmergency('MY', [
    EmergencyNumber('999', EmergencyKind.all),
    EmergencyNumber('15999', EmergencyKind.womenFamily),
  ], 'https://www.malaysia.gov.my/en/topics/mers-999-emergency-line'),
  'QA': CountryEmergency('QA', [
    EmergencyNumber('999', EmergencyKind.all),
  ], 'https://hukoomi.gov.qa/', verified: false),
  'OM': CountryEmergency('OM', [
    EmergencyNumber('9999', EmergencyKind.all),
  ], 'https://gov.om/en/emergency-numbers'),
  'KW': CountryEmergency('KW', [
    EmergencyNumber('112', EmergencyKind.all),
  ], 'https://www.moi.gov.kw/main/'),
  'SG': CountryEmergency('SG', [
    EmergencyNumber('999', EmergencyKind.police),
    EmergencyNumber('995', EmergencyKind.ambulanceFire),
  ], 'https://www.police.gov.sg/Contact-Us · https://www.scdf.gov.sg/'),
  'IT': CountryEmergency('IT', [
    EmergencyNumber('112', EmergencyKind.all),
  ], 'https://112.gov.it/'),
  'GB': CountryEmergency('GB', [
    EmergencyNumber('999', EmergencyKind.all),
    EmergencyNumber('112', EmergencyKind.all),
    EmergencyNumber('111', EmergencyKind.healthNonEmergency),
    EmergencyNumber('101', EmergencyKind.policeNonEmergency),
  ], 'https://www.gov.uk/guidance/999-and-112-the-uks-national-emergency-numbers'),
  'US': CountryEmergency('US', [
    EmergencyNumber('911', EmergencyKind.all),
    EmergencyNumber('988', EmergencyKind.crisis),
  ], 'https://www.911.gov/ · https://988lifeline.org/'),
};

/// A country we have no official table for: 112 is the emergency number
/// every GSM/3GPP phone must treat as an emergency call (3GPP TS 22.101).
const kEmergencyFallback = CountryEmergency(
    '', [EmergencyNumber('112', EmergencyKind.all)],
    'https://www.3gpp.org/ (TS 22.101)');

String? _iso(String? s) {
  final v = (s ?? '').trim().toUpperCase();
  return RegExp(r'^[A-Z]{2}$').hasMatch(v) ? v : null;
}

/// The country the phone is in. [network] = mobile network country (where
/// the phone is now), [data] = country of the nearest place in our own list
/// for the GPS position, [sim] = the SIM's home country.
String? pickEmergencyCountry({String? network, String? data, String? sim}) =>
    _iso(network) ?? _iso(data) ?? _iso(sim);

/// Numbers for the picked country (fallback: 112).
CountryEmergency emergencyFor(String? cc) =>
    kEmergencyByCountry[_iso(cc)] ?? kEmergencyFallback;
