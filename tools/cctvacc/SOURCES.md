# CCTV smart-alert accuracy — clip sources and licences

Openly licensed videos from **Wikimedia Commons**, as published on each
file page (licence as declared there; author / credit as Commons shows it).
Nothing is committed: `fetch.py` downloads each ORIGINAL on the CI runner,
checks its SHA-1 against the value Commons publishes, re-encodes it once
to H.264 (same frame times) and deletes it after the run.

Labels are written BY A PERSON from the contact sheets (`sheets.py`, one
picture per 1-2 s) — never from any model output. A label is a time
interval in seconds where at least one person is visible anywhere in the
picture (people on motorbikes count; statues, dogs and other animals do
not). Privacy: no faces are identified and no identity is used; the
harness only counts person boxes.

Split: odd clip ids = development (thresholds are tuned there), even ids
= held-out (reported).

| id | scene | camera | night | person intervals (s) | length | licence | author / credit | source |
|---|---|---|---|---|---|---|---|---|
| c01 | walkway_cctv | fixed CCTV (dusk, sodium light; shakes ~12 s: 2007 earthquake) | no | 0-96 | 96s | Public domain | PUCP CCTV | [2007 Lima PUCP CCTV.webm](https://commons.wikimedia.org/wiki/File:2007_Lima_PUCP_CCTV.webm) |
| c02 | rain | fixed (rain on water) | no | none | 21s | CC0 | AnRo0002 | [20141103Regen.ogv](https://commons.wikimedia.org/wiki/File:20141103Regen.ogv) |
| c03 | rain | fixed (rain on a road) | no | none | 19s | CC0 | AnRo0002 | [20160513Regen Hockenheim.ogv](https://commons.wikimedia.org/wiki/File:20160513Regen_Hockenheim.ogv) |
| c05 | pet | hand-held, nearly still (two dogs) | no | none | 17s | CC0 | Umngeni | [Africanis Dogs Resting In Grass.ogv](https://commons.wikimedia.org/wiki/File:Africanis_Dogs_Resting_In_Grass.ogv) |
| c06 | rain | montage of fixed shots (rain in trees), cuts every ~10 s | no | none | 61s | CC BY-SA 4.0 | Musicaline | [Averse de pluie.webm](https://commons.wikimedia.org/wiki/File:Averse_de_pluie.webm) |
| c10 | night_ir | IR trail camera (badger), 3 nights | yes | none | 56s | CC BY-SA 4.0 | Lionel Allorge | [Blaireau à Saint-Rémy-lès-Chevreuse en février 2020.webm](https://commons.wikimedia.org/wiki/File:Blaireau_%C3%A0_Saint-R%C3%A9my-l%C3%A8s-Chevreuse_en_f%C3%A9vrier_2020.webm) |
| c11 | gate_street | fixed, busy pedestrian street | no | 0-44 | 44s | CC BY-SA 3.0 | OsvaldoGago | [Calle Preciados Madrid.ogv](https://commons.wikimedia.org/wiki/File:Calle_Preciados_Madrid.ogv) |
| c13 | pet | close-up kitten (pet in front of the lens) | no | none | 15s | Public domain | Legendaryreel.pull1 | [Cat meowing into camera.webm](https://commons.wikimedia.org/wiki/File:Cat_meowing_into_camera.webm) |
| c14 | pet | hand-held dog-park montage (dogs; people in 3 parts) | no | 27-35, 43-47, 113-121 | 120s | CC BY-SA 3.0 | Rubi2011 | [Dog park.theora.ogv](https://commons.wikimedia.org/wiki/File:Dog_park.theora.ogv) |
| c15 | gate_street | hand-held, person walking a big dog (6-10 s: dog only) | no | 0-5.5, 10.5-17 | 17s | CC BY-SA 3.0 | Sage Ross | [Dog walking in the Mission in San Francisco.ogv](https://commons.wikimedia.org/wiki/File:Dog_walking_in_the_Mission_in_San_Francisco.ogv) |
| c16 | night_ir | IR camera in an attic (marten) | yes | none | 14s | CC BY-SA 3.0 | Lionel Allorge | [Fouine dans un grenier de Saint-Calais le 10 décembre 2020.webm](https://commons.wikimedia.org/wiki/File:Fouine_dans_un_grenier_de_Saint-Calais_le_10_d%C3%A9cembre_2020.webm) |
| c17 | night_ir | IR trail camera (foxes, close) | yes | none | 20s | Public domain | USFWS Mountain-Prairie | [Fox Squad on the National Elk Refuge.webm](https://commons.wikimedia.org/wiki/File:Fox_Squad_on_the_National_Elk_Refuge.webm) |
| c19 | headlights | hand-held night traffic + headlights (people on motorbikes and walking) | yes | 0-41 | 41s | CC BY-SA 2.0 | Nick Nguyen | [Hanoi traffic.ogv](https://commons.wikimedia.org/wiki/File:Hanoi_traffic.ogv) |
| c21 | headlights | fixed night city view (moving headlights far away) | yes | none | 45s | CC BY-SA 4.0 | Matti Blume | [Night, Cape Town (00001).webm](https://commons.wikimedia.org/wiki/File:Night,_Cape_Town_(00001).webm) |
| c23 | gate_street | fixed, pedestrian underpass (gate-like) | no | 0-36 | 36s | CC BY-SA 3.0 | Juan de Vojníkov | [Praha, Fugnerovo náměstí, podchod pod Sokolskou.ogv](https://commons.wikimedia.org/wiki/File:Praha,_Fugnerovo_n%C3%A1m%C4%9Bst%C3%AD,_podchod_pod_Sokolskou.ogv) |
| c24 | gate_street | fixed, Shibuya crossing at dusk (cars + crowds) | no | 0-90 | 90s | CC BY 2.0 | Emran Kassim from Nagoya, Aichi, Japan | [Shibuya Crossing.ogv](https://commons.wikimedia.org/wiki/File:Shibuya_Crossing.ogv) |
| c25 | pet_animal | home surveillance camera at night (bear on a driveway; IR/colour switching) | yes | none | 34s | Public domain | WBNS 10TV | [Surveillance camera captures bear in Franklin County for first time in nearly 20 years.webm](https://commons.wikimedia.org/wiki/File:Surveillance_camera_captures_bear_in_Franklin_County_for_first_time_in_nearly_20_years.webm) |
| c27 | night_ir | trail camera, day (elk) | no | none | 10s | Public domain | USFWS Mountain-Prairie | [Trail Camera.webm](https://commons.wikimedia.org/wiki/File:Trail_Camera.webm) |
| c28 | tree | hand-held, tree moving in wind | no | none | 14s | CC BY-SA 4.0 | דוד שי | [Trees in the wind.webm](https://commons.wikimedia.org/wiki/File:Trees_in_the_wind.webm) |
| c29 | tree | fixed, tilted; tree and cage in wind | no | none | 17s | CC0 | Sillerkiil | [Tuuleheide Viimsis 2020 .webm](https://commons.wikimedia.org/wiki/File:Tuuleheide_Viimsis_2020_.webm) |
| c30 | night_ir | trail camera, day (weasel) | no | none | 10s | Public domain | USFWS Mountain-Prairie | [Weasel on Trail Camera.webm](https://commons.wikimedia.org/wiki/File:Weasel_on_Trail_Camera.webm) |
| c31 | tree | fixed, tree branches in wind | no | none | 5s | CC BY-SA 4.0 | Oakley413 | [Wind in tree AppletonFarms Massachusetts 2024-10.webm](https://commons.wikimedia.org/wiki/File:Wind_in_tree_AppletonFarms_Massachusetts_2024-10.webm) |
| c32 | night_ir | trail camera, day (wolf) | no | none | 10s | Public domain | USFWS Mountain-Prairie | [Wolf on Trail Camera.webm](https://commons.wikimedia.org/wiki/File:Wolf_on_Trail_Camera.webm) |

## Looked at and NOT used (and why)

- c07 — [BLK-HDPTZ12 Security Camera Parking Lot Surveillance Video.webm](https://commons.wikimedia.org/wiki/File:BLK-HDPTZ12_Security_Camera_Parking_Lot_Surveillance_Video.webm) (Public domain): PTZ parking lot: people too small to label reliably from the contact sheets
- c09 — [Berbera-cityscape-evening.ogv](https://commons.wikimedia.org/wiki/File:Berbera-cityscape-evening.ogv) (CC0): hand-held panning city view (not a fixed camera)
- c12 — [Cars Passing by at Night.webm](https://commons.wikimedia.org/wiki/File:Cars_Passing_by_at_Night.webm) (CC BY-SA 4.0): hand-held night street following cars (not a fixed camera)
- c20 — [Heavy rain in Nanshan District, Shenzhen (20250424).webm](https://commons.wikimedia.org/wiki/File:Heavy_rain_in_Nanshan_District,_Shenzhen_(20250424).webm) (CC BY 4.0): hand-held night rain; a figure at 3-4 s too dark to label
- c22 — [Pouring down in Wikimania 2017.webm](https://commons.wikimedia.org/wiki/File:Pouring_down_in_Wikimania_2017.webm) (CC BY-SA 4.0): hand-held rain montage; tiny people at a far bus shelter not labelable

Totals: 23 clips used, 13.5 minutes, 7 with people, 16 without.
