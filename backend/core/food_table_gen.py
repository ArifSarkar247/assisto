#!/usr/bin/env python3
"""Regenerate backend/core/logic/food_table_data.py from the ORIGINAL source
files (p2food). Every number in the app's food table comes from here — no
hand-typed nutrition values.

Sources (download yourself; not committed):
  FCT  = Food Composition Table for Bangladesh 2013, INFS Univ. of Dhaka / FAO,
         https://www.fao.org/fileadmin/templates/food_composition/documents/FCDB_7_4_14.xlsx
         sheet "UserDB_Main_table" (convert to CSV first: s_5.csv)
  USDA = FoodData Central, FNDDS survey foods CSV 2024-10-31 (public domain),
         https://fdc.nal.usda.gov/fdc-datasets/FoodData_Central_survey_food_csv_2024-10-31.zip

Usage: python3 -I backend/core/food_table_gen.py <fct_main_table.csv> <fndds_dir> > backend/core/logic/food_table_data.py
"""
import csv
import re
import sys

# (id, group, bn, en, src, code, synonyms, portions, note)
#   portions: (pid, bn, en, grams, basis)  basis: 'usda:<fdc_id>' (FNDDS
#   portion weight) or 'home' (household measure, approximate, user-editable)
CUP_RICE = 158      # usda 2708408 "1 cup, cooked"
SPEC = [
    ("bhat", "rice", "ভাত (সাদা)", "Rice (white, boiled)", "fct", "01_0041", "bhat vat rice",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 2 * CUP_RICE, "home"),
      ("cup", "১ কাপ", "1 cup", CUP_RICE, "usda:2708408"),
      ("half", "আধা কাপ", "½ cup", CUP_RICE // 2, "usda:2708408")], ""),
    ("lal_bhat", "rice", "লাল চালের ভাত", "Brown rice (parboiled, boiled)", "fct", "01_0039", "lal chal brown rice",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 2 * CUP_RICE, "home"),
      ("cup", "১ কাপ", "1 cup", CUP_RICE, "usda:2708408")], ""),
    ("khichuri", "rice", "খিচুড়ি", "Khichuri (plain)", "fct", "01_0035", "khichuri khichdi",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 392, "home"),
      ("cup", "১ কাপ", "1 cup", 196, "usda:2706490")], ""),
    ("pulao", "rice", "পোলাও", "Pulao (plain)", "fct", "01_0036", "polao pulao",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 392, "home"),
      ("cup", "১ কাপ", "1 cup", 196, "usda:2706490")], ""),
    ("biriyani", "rice", "বিরিয়ানি / কাচ্চি (মাংস)", "Biryani / kacchi (meat)", "usda", "2706490", "biriyani biryani kacchi tehari",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 392, "home"),
      ("cup", "১ কাপ", "1 cup", 196, "usda:2706490")], "foreign"),
    ("biriyani_chicken", "rice", "মুরগির বিরিয়ানি", "Chicken biryani", "usda", "2706538", "chicken biriyani murgi",
     [("plate", "১ প্লেট (≈২ কাপ)", "1 plate (≈2 cups)", 392, "home"),
      ("cup", "১ কাপ", "1 cup", 196, "usda:2706538")], "foreign"),
    ("ruti", "bread", "রুটি", "Ruti (chapati)", "fct", "01_0042", "ruti roti chapati",
     [("piece", "১টি (মাঝারি)", "1 medium", 40, "usda:2707713"),
      ("large", "১টি (বড়)", "1 large", 52, "usda:2707713")], ""),
    ("paratha", "bread", "পরোটা", "Paratha", "usda", "2707715", "porota paratha",
     [("piece", "১টি", "1 piece", 70, "usda:2707715")], "foreign"),
    ("puri", "bread", "পুরি / লুচি", "Puri / luchi", "usda", "2707714", "puri luchi",
     [("piece", "১টি", "1 piece", 36, "usda:2707714")], "foreign"),
    ("dal", "dal", "ডাল (তেল-ফোড়নসহ)", "Dal (with tempering)", "usda", "2707427", "dal daal dahl",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 240, "usda:2707427"),
      ("half", "আধা বাটি", "½ bowl", 120, "usda:2707427")], "foreign"),
    ("dal_mosur", "dal", "মসুর ডাল (সেদ্ধ, তেল ছাড়া)", "Red lentil (boiled, no oil)", "fct", "02_0015", "mosur masoor lentil",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 180, "usda:2707425"),
      ("half", "আধা বাটি", "½ bowl", 90, "usda:2707425")], ""),
    ("dal_mung", "dal", "মুগ ডাল (সেদ্ধ, তেল ছাড়া)", "Mung dal (boiled, no oil)", "fct", "02_0013", "mung moong",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 180, "usda:2707425"),
      ("half", "আধা বাটি", "½ bowl", 90, "usda:2707425")], ""),
    ("machh_curry", "curry", "মাছের তরকারি / ঝোল", "Fish curry", "usda", "2706460", "machh mach fish curry jhol rui ilish",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 240, "usda:2706460"),
      ("piece", "১ টুকরো + ঝোল (≈আধা কাপ)", "1 piece + gravy (≈½ cup)", 120, "home")], "foreign"),
    ("murgi_curry", "curry", "মুরগির তরকারি / রোস্ট", "Chicken curry", "usda", "2706437", "murgi chicken curry roast mangsho",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 240, "usda:2706437"),
      ("piece", "১ টুকরো + ঝোল (≈আধা কাপ)", "1 piece + gravy (≈½ cup)", 120, "home")], "foreign"),
    ("gorur_mangsho", "curry", "গরুর মাংস ভুনা / তরকারি", "Beef curry", "usda", "2706388", "gorur mangsho beef curry bhuna kala bhuna",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 240, "usda:2706388"),
      ("piece", "২-৩ টুকরো + ঝোল (≈আধা কাপ)", "2-3 pieces + gravy (≈½ cup)", 120, "home")], "foreign"),
    ("sobji", "curry", "সবজি / লাবড়া", "Vegetable curry", "usda", "2710067", "sobji shobji labra vegetable niramish",
     [("bati", "১ বাটি (১ কাপ)", "1 bowl (1 cup)", 240, "usda:2710067"),
      ("half", "আধা বাটি", "½ bowl", 120, "usda:2710067")], "foreign"),
    ("lal_shak", "veg", "লাল শাক (সেদ্ধ, তেল ছাড়া)", "Red amaranth leaves (boiled, no oil)", "fct", "04_0032", "lal shak shak sag",
     [("bati", "১ বাটি (≈আধা কাপ)", "1 bowl (≈½ cup)", 100, "home")], ""),
    ("korola_bhaji", "veg", "করলা ভাজি", "Bitter gourd fry", "fct", "03_0048", "korola bhaji karela",
     [("bati", "১ ছোট বাটি", "1 small bowl", 50, "home")], ""),
    ("dheros_bhuna", "veg", "ঢেঁড়স-টমেটো ভুনা", "Okra-tomato bhuna", "fct", "03_0046", "dheros vendi okra bhuna",
     [("bati", "১ ছোট বাটি", "1 small bowl", 100, "home")], ""),
    ("alu_bhorta", "veg", "আলু ভর্তা (তেল ছাড়া)", "Mashed potato (bhorta, no oil)", "fct", "05_0021", "alu bhorta vorta potato mash",
     [("scoop", "১ গোল্লা (≈আধা কাপ)", "1 scoop (≈½ cup)", 100, "home")], "add_oil"),
    ("kachki_bhaja", "fish", "কাচকি মাছ ভাজা", "Small fish (kachki) fry", "fct", "09_0071", "kachki chhoto mach bhaja",
     [("bati", "১ ছোট বাটি", "1 small bowl", 50, "home")], ""),
    ("macher_kopta", "fish", "মাছের কোপ্তা", "Fish ball (kopta)", "fct", "09_0072", "kopta fish ball",
     [("piece", "১টি", "1 piece", 30, "home")], ""),
    ("handi_kabab", "meat", "গরুর হাঁড়ি কাবাব", "Beef handi kabab", "fct", "10_0016", "kabab kebab handi",
     [("bati", "১ ছোট বাটি", "1 small bowl", 100, "home")], ""),
    ("dim_siddho", "egg", "ডিম সেদ্ধ", "Egg, boiled", "fct", "11_0005", "dim egg siddho boiled",
     [("piece", "১টি", "1 egg", 50, "usda:2707154")], ""),
    ("dim_bhaji", "egg", "ডিম ভাজি / মামলেট", "Egg, fried (oil)", "usda", "2707158", "dim bhaji omelette mamlet fried egg",
     [("piece", "১টি", "1 egg", 55, "usda:2707155")], "foreign"),
    ("singara", "snack", "সিঙারা / সমুচা", "Singara / samosa", "usda", "2708730", "singara shingara samosa somucha",
     [("piece", "১টি (মাঝারি)", "1 medium", 75, "usda:2708730"),
      ("small", "১টি (ছোট)", "1 small", 25, "usda:2708730")], "near_match"),
    ("piyaju", "snack", "পিঁয়াজু / বেগুনি / পাকোড়া", "Piyaju / beguni / pakora", "usda", "2710066", "piyaju peyaju beguni pakora bora",
     [("piece", "১টি", "1 piece", 12, "usda:2710066")], "near_match"),
    ("muri", "snack", "মুড়ি", "Muri (puffed rice)", "fct", "01_0023", "muri puffed rice",
     [("cup", "১ কাপ (≈১৪ গ্রাম)", "1 cup (≈14 g)", 14, "home")], ""),
    ("chira", "snack", "চিড়া (শুকনো)", "Chira (rice flakes, dry)", "fct", "01_0010", "chira poha",
     [("cup", "আধা কাপ (≈৪০ গ্রাম)", "½ cup (≈40 g)", 40, "home")], ""),
    ("payesh", "sweet", "পায়েস", "Payesh", "fct", "12_0013", "payesh kheer",
     [("bati", "১ ছোট বাটি (≈আধা কাপ)", "1 small bowl (≈½ cup)", 120, "home")], ""),
    ("misti_doi", "sweet", "মিষ্টি দই", "Misti doi (sweet curd)", "fct", "12_0003", "misti doi curd yogurt",
     [("cup", "১ ছোট কাপ", "1 small cup", 113, "usda:2705418")], ""),
    ("laddu", "sweet", "লাড্ডু", "Laddu", "usda", "2710351", "laddu ladoo",
     [("piece", "১টি", "1 piece", 60, "usda:2710351")], "foreign"),
    ("dudh_cha", "drink", "দুধ চা (চিনিসহ)", "Milk tea (with sugar)", "fct", "14_0007", "cha tea dudh",
     [("cup", "১ কাপ (≈১২৫ মিলি)", "1 cup (≈125 ml)", 125, "home")], ""),
    ("liquor_cha", "drink", "লিকার চা (চিনিসহ)", "Black tea (with sugar)", "fct", "14_0008", "liquor cha tea red",
     [("cup", "১ কাপ (≈১২৫ মিলি)", "1 cup (≈125 ml)", 125, "home")], ""),
    ("aam", "fruit", "আম (ফজলি, পাকা)", "Mango (Fazli, ripe)", "fct", "08_0025", "aam mango",
     [("cup", "১ কাপ টুকরো", "1 cup pieces", 165, "usda:2709242")], ""),
    ("kola", "fruit", "কলা (সাগর, পাকা)", "Banana (Sagar, ripe)", "fct", "08_0004", "kola banana",
     [("piece", "১টি", "1 banana", 126, "usda:2709224")], ""),
    ("peyara", "fruit", "পেয়ারা", "Guava", "fct", "08_0015", "peyara guava",
     [("piece", "১টি (মাঝারি)", "1 medium", 100, "home")], ""),
    ("kathal", "fruit", "কাঁঠাল (পাকা)", "Jackfruit (ripe)", "fct", "08_0017", "kathal jackfruit",
     [("cup", "১ কাপ কোয়া", "1 cup pods", 150, "home")], ""),
    ("lichu", "fruit", "লিচু", "Lychee", "fct", "08_0024", "lichu lychee",
     [("ten", "১০টি (শাঁস)", "10 (flesh)", 100, "home")], ""),
    ("pepe", "fruit", "পেঁপে (পাকা)", "Papaya (ripe)", "fct", "08_0035", "pepe papaya",
     [("cup", "১ কাপ টুকরো", "1 cup pieces", 145, "home")], ""),
    ("tormuj", "fruit", "তরমুজ", "Watermelon", "fct", "08_0042", "tormuj watermelon",
     [("cup", "১ কাপ টুকরো", "1 cup pieces", 150, "home")], ""),
    ("chini", "extra", "চিনি", "Sugar", "fct", "15_0008", "chini sugar",
     [("tsp", "১ চা-চামচ", "1 teaspoon", 4, "home")], ""),
    ("shorisha_tel", "extra", "সরিষার তেল / রান্নার তেল", "Mustard / cooking oil", "fct", "13_0008", "tel oil shorisha mustard",
     [("tsp", "১ চা-চামচ", "1 teaspoon", 5, "home")], ""),
    # No cited value found (FCT 2013 + FNDDS checked 3 Nov 2026): listed so the
    # photo/manual pick still works, but NEVER given a number.
    ("fuchka", "snack", "ফুচকা", "Fuchka", "none", "", "fuchka phuchka panipuri", [("plate", "১ প্লেট", "1 plate", 0, "home")], ""),
    ("chotpoti", "snack", "চটপটি", "Chotpoti", "none", "", "chotpoti chatpati", [("plate", "১ প্লেট", "1 plate", 0, "home")], ""),
    ("pitha", "sweet", "পিঠা (ভাপা/চিতই/পাটিসাপটা)", "Pitha", "none", "", "pitha bhapa chitoi patishapta", [("piece", "১টি", "1 piece", 0, "home")], ""),
    ("rosogolla", "sweet", "রসগোল্লা / মিষ্টি", "Rosogolla / mishti", "none", "", "rosogolla roshogolla mishti misti chomchom kalojam", [("piece", "১টি", "1 piece", 0, "home")], ""),
    ("jilapi", "sweet", "জিলাপি", "Jilapi", "none", "", "jilapi jalebi", [("piece", "১টি", "1 piece", 0, "home")], ""),
    ("haleem", "curry", "হালিম", "Haleem", "none", "", "haleem halim", [("bati", "১ বাটি", "1 bowl", 0, "home")], ""),
    ("shutki_bhorta", "veg", "শুঁটকি / অন্য ভর্তা", "Shutki / other bhorta", "none", "", "shutki bhorta vorta begun", [("scoop", "১ গোল্লা", "1 scoop", 0, "home")], ""),
]


def num(v):
    v = str(v or "").strip().strip("[]")
    try:
        return round(float(v), 2)
    except ValueError:
        return None   # 'Tr' (trace) / blank -> unknown, never guessed


def load_fct(path):
    out = {}
    for row in csv.reader(open(path, encoding="utf-8")):
        if len(row) > 11 and re.match(r"^\d\d_\d{4}$", row[0] or ""):
            m = re.match(r"\s*\(?(\d+)\)?", row[6])
            kcal = int(m.group(1)) if m else None
            if row[6].strip().startswith("("):
                kcal = int(re.match(r"\((\d+)\)", row[6].strip()).group(1))
            out[row[0]] = {"name": row[1].strip(), "kcal": kcal, "protein": num(row[8]),
                           "fat": num(row[9]), "carb": num(row[10]), "fibre": num(row[11])}
    return out


def load_usda(d):
    want = {"208": "kcal", "203": "protein", "204": "fat", "205": "carb", "291": "fibre"}
    names = {r["fdc_id"]: r["description"] for r in csv.DictReader(open(d + "/food.csv"))}
    out = {}
    for r in csv.DictReader(open(d + "/food_nutrient.csv")):
        k = want.get(r["nutrient_id"])
        if k:
            out.setdefault(r["fdc_id"], {"name": names.get(r["fdc_id"], "")})[k] = round(float(r["amount"]), 2)
    return out


def main(fct_csv, usda_dir):
    fct, usda = load_fct(fct_csv), load_usda(usda_dir)
    rows = []
    for (did, group, bn, en, src, code, syn, portions, note) in SPEC:
        if src == "fct":
            v = fct[code]
        elif src == "usda":
            v = usda[code]
            v["kcal"] = int(round(v["kcal"]))
        else:
            v = {"name": "", "kcal": None, "protein": None, "fat": None, "carb": None, "fibre": None}
        rows.append({"id": did, "group": group, "bn": bn, "en": en, "src": src, "code": code,
                     "src_name": v["name"], "per100": {k: v[k] for k in ("kcal", "protein", "fat", "carb", "fibre")},
                     "syn": syn, "note": note,
                     "portions": [{"id": p[0], "bn": p[1], "en": p[2], "g": p[3], "basis": p[4]} for p in portions]})
    print('"""GENERATED by backend/core/food_table_gen.py — do not hand-edit numbers.\n'
          'Sources: FCT Bangladesh 2013 (INFS/FAO) + USDA FNDDS 2024-10-31 (public domain)."""')
    print("# flake8: noqa")
    print("ROWS = [")
    for r in rows:
        print("    %r," % (r,))
    print("]")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
