// quranshikhi (owner order 9 Nov 21:55): Quran Shikhi shows Bangla AND
// English together - the only exception to strict language separation; the
// learner can hide either line. These are the bilingual labels of the letter
// lesson (our own words). Lives under lib/l10n/ because it carries Bangla
// script (lang gate). Every explanation is educational text written by
// Assisto and stays "under review" until an alem / qari approves it.
import '../quran_learn/qaida_model.dart';

const kQsMakhraj = QlText('মাখরাজ (উচ্চারণের জায়গা)', 'Makhraj (where the sound comes from)');
const kQsName = QlText('হরফের নাম', 'Letter name');
const kQsForms = QlText('চার রূপ (ডান থেকে বাঁয়ে)', 'Four forms (right to left)');
const kQsIsolated = QlText('একা', 'Alone');
const kQsInitial = QlText('শুরুতে', 'At the start');
const kQsMedial = QlText('মাঝে', 'In the middle');
const kQsFinal = QlText('শেষে', 'At the end');
const kQsNoLeftJoin = QlText(
    'এই হরফ পরের হরফের সাথে জোড়া লাগে না, তাই এর শুধু দুই রূপ।',
    'This letter never joins the letter after it, so it has only two forms.');
const kQsNoJoin = QlText('হামযা (ء) একা বসে, কোনো হরফের সাথে জোড়া লাগে না।',
    'Hamza (ء) stands alone and joins no letter.');
const kQsUnderReview = QlText('আলেম / ক্বারীর যাচাইয়ের অপেক্ষায়',
    'Under review by an alem / qari');
const kQsPronHint = QlText('উচ্চারণ সহায়িকা (আনুমানিক)', 'Pronunciation hint (approximate)');

/// Line toggle labels, each in its own script.
const kQsLineBn = 'বাংলা';
const kQsLineEn = 'English';
