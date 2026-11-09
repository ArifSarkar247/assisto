#!/usr/bin/env python3
"""Plan future IELTS mocks (004..N) so topics never repeat and formats rotate. Stdlib only.

    python3 tools/lp/blueprint.py [--upto 200]   -> tools/lp/blueprints/ielts_plan.json

Each entry is a writing brief for an author (see AUTHORING_SPEC.md). Topics already used by existing bundles
are skipped. When a bank runs out the slot says "EXTEND BANK" instead of repeating a topic.
"""
from __future__ import annotations

import argparse
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

AC_READING = """The history of standard time zones|How bats navigate in total darkness|Seed banks and the future of crops|The economics of open-source software|Why some languages have no words for numbers|Mangrove forests as nurseries of the sea|The science of procrastination|Early printing and the spread of literacy|Glaciers as archives of past climate|How cities lose heat at night|The rise of the container ship|Ant colonies as problem solvers|The psychology of queuing|Desalination: promise and cost|Ancient Roman concrete|Tea and the making of a global trade|The microbiome of soil|Memory palaces and the art of remembering|Noise pollution in the oceans|The development of the modern bicycle|How children acquire grammar|The return of the beaver to European rivers|Paper money and trust|Spider silk as an engineering material|Light pollution and migratory birds|The invention of refrigeration|Placebo effects in medicine|Rice terraces and water management|The decline of handwriting|Volcanic soils and early farming|Why we yawn|The archaeology of shipwrecks|Bioluminescence in the deep sea|Urban heat islands|The origins of board games|Crowd behaviour and safety design|The economics of tipping|Moss as an air-quality indicator|Mapping the ocean floor|Lighthouses to satellites: a history of navigation|The psychology of colour in packaging|Locust swarms|The cotton gin and its consequences|Bamboo as a building material|Sleep and teenage learning|Sand: a resource running out|Wind-catchers and passive cooling|The domestication of the horse|Citizen science and bird counts|Coral spawning and the moon|The economics of free public transport|Animal camouflage and military design|Salt in human history|Early warning systems for floods|Language death and revival|Plastic-eating bacteria|The first public libraries|Mushrooms and forest networks|Measuring intelligence in birds|The physics of musical instruments|Food deserts in cities|Smell and memory|The history of anaesthesia|How rivers change course|Insect farming for animal feed|Children and screen time research|The engineering of suspension bridges|Coffee leaf rust|The four-day working week|Tidal energy|Ancient trade on the Silk Roads|Elephants and long-distance communication|Rewilding farmland|How vaccines are tested|The history of the postal service|Fog harvesting in deserts|Musical training and the brain|Earthworms and soil health|The invention of the barcode|Jellyfish blooms|Graffiti as urban art|The economics of attention|Archaeology from the air|Hydrogen-powered ships|Birdsong dialects|The history of chocolate|Bilingualism and ageing|Seaweed farming|Electric aviation|Wolves and river ecosystems|Bridges built from living roots|The sociology of fan communities|Thermal imaging in conservation|Cork harvesting|The quantified self movement|Desert locust prediction|Sundials and early timekeeping|The ethics of zoos|Peatlands and carbon|Recycled water and public opinion|Glass sponges|Monsoon prediction""".split("|")

GT_LONG = """The story of the travelling library van|Lighthouses of the northern coast|A history of the pocket watch|The return of the village bakery|How public parks were invented|The rise of community gardens|A short history of the umbrella shop|The canal boats of the industrial age|Street food markets around the world|The decline and revival of the cinema|The history of the school uniform|Night trains in modern travel|Volunteer firefighters in rural areas|The story of the bus timetable|How seaside holidays began|The first department stores|Repair cafés and the throwaway culture|The craft of hand-made shoes|Postcards and holiday communication|Rural broadband projects|The history of the crossword|Bee-keeping in towns|Mountain rescue teams|The life of a ferry captain|Marathon running for everyone|Public clocks and town squares|The revival of the tram|Allotments and urban food|The story of tinned food|Ice-cream vans and summer trade""".split("|")

GT_SHORT = """adverts for six weekend courses|timetable of a ferry service|notices at a community sports hall|offers from four mobile phone shops|rules of a city campsite|descriptions of five museums|guide to a recycling centre|advertisements for flats to rent|leaflet on a summer festival|information on four gyms|rules for library members|five local restaurants|swimming-pool notice and price list|holiday cottage descriptions|evening classes at a college|guide to a farmers' market|bus and tram passes|five volunteering opportunities|rules at a youth hostel|home-delivery grocery services""".split("|")

GT_WORK = """new staff induction and dress code|guide to workplace first aid|staff leave and shift-swap policy|working from home guidelines|how to claim travel expenses|customer complaint procedure|safe lifting at work|staff training budget rules|company car-park rules|fire evacuation procedure|probation period explained|using the staff canteen|IT security for new employees|applying for internal promotion|flexible working requests|reporting accidents at work|uniform and protective equipment|staff discount scheme|annual appraisal guide|night-shift safety""".split("|")

L1 = """booking a kayak lesson|joining a choir|enquiring about a language course|reporting a lost bag at a station|booking a birthday party venue|renting a bicycle for a week|registering at a medical centre|hiring a removal van|booking a cooking class|ordering a cake for an event|joining a gym|enquiring about a part-time job at a café|booking a hotel conference room|arranging a house cleaning service|signing up for a photography club|booking a city walking tour|enquiring about a homestay|booking a driving lesson|insurance claim for a broken phone|booking a campsite pitch|enrolling a child in a holiday camp|hiring a car at an airport|joining a library|booking tickets for a theatre group|ordering a sofa delivery|booking a pet hotel|joining a running club|enquiring about a volunteer role|booking a ferry with a car|renting a storage unit""".split("|")

L2 = """tour of a botanical garden|radio report on a new bus route|introduction to a science museum|talk on a town's recycling scheme|guide to a music festival site|briefing for new library volunteers|tour of a restored theatre|talk about a nature reserve|information on a charity bike ride|introduction to a farm open day|guide to a shopping centre redevelopment|radio talk on a food festival|talk for new members of a sailing club|tour of a historic railway|orientation at a holiday resort|talk on a community art project|briefing on a marathon route|tour of a newspaper office|talk on home energy saving|guide to a sports stadium""".split("|")

L3 = """students planning a survey on commuting|tutor feedback on a business case study|students preparing a presentation on urban trees|discussing a field trip to a wetland|students comparing research methods|planning a podcast for a media course|discussing a placement at a museum|students analysing a marketing campaign|tutor and student on dissertation topics|students reviewing a psychology experiment|planning a group report on tourism|discussing an architecture model|students evaluating online learning|discussing a nutrition study|students preparing a debate on transport|feedback on a geography poster|students planning an exhibition|discussing a history source analysis|students reviewing an engineering prototype|planning a sociology interview study""".split("|")

L4 = """the history of the compass|how deserts form|sleep in marine mammals|the economics of fair trade|the development of written numbers|bird migration and magnetism|the architecture of termite mounds|the history of glass making|noise and wellbeing in offices|traditional star navigation at sea|soil erosion and farming|the physics of rainbows|the science of fermentation|early cinema technology|urban foxes|the psychology of first impressions|the history of maps|plant communication|the economics of water pricing|tsunamis and early warning|the evolution of the eye|the history of public health|rewilding rivers|biomimicry in design|the decline of pollinators|the history of shipping containers|polar ice cores|the psychology of motivation|ancient irrigation|wind turbine design""".split("|")

T2 = [("opinion", "Governments should spend more on public transport than on new roads."),
      ("discussion", "Some think children should start school at four, others at seven."),
      ("problem_solution", "Many young people in cities cannot afford to rent a home."),
      ("advantages", "More people now shop online rather than in local stores."),
      ("two_part", "Many people today do not know their neighbours. Why? Is this a problem?"),
      ("opinion", "Unpaid community service should be compulsory for teenagers."),
      ("discussion", "Some say museums should be free; others say visitors should pay."),
      ("problem_solution", "Traffic noise affects health in many cities."),
      ("advantages", "Some companies now let employees choose their own working hours."),
      ("two_part", "Fewer people read newspapers. Why? What effects does this have?"),
      ("opinion", "Tourism does more harm than good to historic places."),
      ("discussion", "Some prefer to work for large companies, others for small businesses."),
      ("problem_solution", "Many older people feel lonely."),
      ("advantages", "Students increasingly study abroad for their first degree."),
      ("two_part", "Fast food is popular worldwide. Why? Should governments act?"),
      ("opinion", "Advertising aimed at children should be banned."),
      ("discussion", "Some think sport at school should be competitive, others not."),
      ("problem_solution", "Much food is wasted by households and supermarkets."),
      ("advantages", "Cities are building more high-rise housing."),
      ("two_part", "People are living longer. What problems does this cause? Solutions?")]

CUE = """Describe a journey that took longer than expected|Describe a piece of advice you ignored|Describe a building you find beautiful|Describe a time you learned something from a mistake|Describe a festival you enjoy|Describe a book that changed your opinion|Describe a person who is good at their job|Describe a time you had to wait for something|Describe an object you would save in a fire|Describe a public place you would like to improve|Describe a time you were very busy|Describe a skill you want to learn|Describe a family celebration|Describe a time you received good news|Describe a river or lake you have visited|Describe a goal you achieved|Describe a time you helped a stranger|Describe a website you use often|Describe a meal you cooked for others|Describe a time you changed your plans""".split("|")

T1_AC = ["line", "bar", "pie", "table", "process", "map", "bar", "line", "table", "pie"]
T1_GT = [("formal", "complaint"), ("semi-formal", "request"), ("informal", "invitation"),
         ("formal", "application"), ("informal", "thanks"), ("semi-formal", "apology"),
         ("formal", "suggestion"), ("informal", "advice")]
ACC = [("AU", "GB"), ("GB", "US"), ("US", "AU"), ("GB", "AU"), ("US", "GB"), ("AU", "US")]


def used_topics():
    seen = set()
    for p in glob.glob(os.path.join(HERE, "content", "*", "ielts-*-[0-9][0-9][0-9].json")):
        try:
            b = json.load(open(p, encoding="utf-8"))
            for part in b["reading"]["parts"]:
                for tx in part["texts"]:
                    seen.add(tx.get("title", "").lower())
        except Exception:  # noqa: BLE001
            pass
    return seen


class Bank:
    def __init__(self, items, used=()):
        self.items = [i for i in items if i.lower() not in used]
        self.i = 0

    def take(self):
        if self.i >= len(self.items):
            return "EXTEND BANK"
        self.i += 1
        return self.items[self.i - 1]


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--upto", type=int, default=23)   # extend the banks before planning further
    a = ap.parse_args(argv)
    used = used_topics()
    ar, gl, gs, gw = Bank(AC_READING, used), Bank(GT_LONG, used), Bank(GT_SHORT), Bank(GT_WORK)
    l1, l2, l3, l4, cue = Bank(L1), Bank(L2), Bank(L3), Bank(L4), Bank(CUE)
    plan = []
    n_ac, n_gt = 2, 1                       # 001-002 AC, 001 GT exist
    for k in range(4, a.upto + 1):
        gt = k % 2 == 0
        if gt:
            n_gt += 1
            bid = f"ielts-gt-{n_gt:03d}"
        else:
            n_ac += 1
            bid = f"ielts-ac-{n_ac:03d}"
        acc = ACC[k % len(ACC)]
        t2 = T2[k % len(T2)]
        e = {"bundle_id": bid, "module": "general" if gt else "academic", "status": "planned",
             "listening": [
                 {"part": 1, "topic": l1.take(), "accents": list(acc), "types": ["form_completion", "note_completion"][k % 2:k % 2 + 1] + ["table_completion"]},
                 {"part": 2, "topic": l2.take(), "accents": [acc[1]], "types": ["mcq_single", "map_labelling" if k % 3 == 0 else "matching"]},
                 {"part": 3, "topic": l3.take(), "accents": [acc[0], acc[1], "GB" if "GB" not in acc else "US"], "types": ["mcq_single", "mcq_multi", "matching"]},
                 {"part": 4, "topic": l4.take(), "accents": [acc[k % 2]], "types": ["note_completion"]}],
             "reading": ([{"part": 1, "texts": gs.take()}, {"part": 2, "texts": gw.take()},
                          {"part": 3, "title": gl.take()}] if gt else
                         [{"part": i, "title": ar.take()} for i in (1, 2, 3)]),
             "writing": {"task1": ({"kind": "letter", "tone": T1_GT[k % len(T1_GT)][0],
                                    "purpose": T1_GT[k % len(T1_GT)][1]} if gt else
                                   {"kind": "chart", "visual": T1_AC[k % len(T1_AC)]}),
                         "task2": {"essay_type": t2[0], "idea": t2[1] + (" (vary wording)" if k > len(T2) else "")}},
             "speaking": {"cue_card": cue.take()}}
        plan.append(e)
    out = os.path.join(HERE, "blueprints", "ielts_plan.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    json.dump({"format": "assisto.lp.blueprint/1", "note": "Writing briefs; see AUTHORING_SPEC.md",
               "mocks": plan}, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    ext = sum(json.dumps(e).count("EXTEND BANK") for e in plan)
    print(f"{len(plan)} mocks planned -> {out}; {ext} slots need a bigger topic bank")


if __name__ == "__main__":
    main()
