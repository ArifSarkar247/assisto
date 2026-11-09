# City Service API contract (citydata, owner order 9 Nov 11:45 — ONE FINAL)

Owner of this API: the citydata agent (data + routing backend). Screens: cityapp.
Base: `/api/v1/city/…` (normal Assisto auth; `Accept-Language: bn|en` for
messages). All names come as `name` (English/OSM) + `name_bn` (Bangla, may be
empty → show `name`). Status codes on routes/stops/gates/fares are machine
words; the app localizes them:

| word | show (en) | show (bn) |
|---|---|---|
| `verified` | Verified | যাচাই করা |
| `reported` | Reported by users | ব্যবহারকারীদের তথ্য |
| fare `official` | Official | সরকারি ভাড়া |
| fare `reported` | Reported by users | ব্যবহারকারীদের জানানো ভাড়া |
| fare `estimate` | Estimate | আনুমানিক |

Every fare object: `{low, high, label, basis, checked:"YYYY-MM-DD", source, source_url}`
(+ metro `card` = smart-card price; CNG `meter` and `overcharge_note:true` →
show "Show this if overcharged" + the complaint button from `complaint`).
`low == high` → show one number. Never show ride share as one number.

## 1. Where am I / is there data
`GET city/where?lat=&lon=` → `{city:"dhaka"|"chattogram"|null, has_data:bool,
name, name_bn, counts:{routes,stops,stations}, coverage_pct, google_maps:url|null}`.
No data → honest empty state + "Open in Google Maps" (`google_maps` is a
`https://www.google.com/maps/dir/?api=1&…&travelmode=transit` link; no API call).

## 2. Plan a trip
`GET city/plan?from=LAT,LON&to=LAT,LON[&at=HH:MM][&modes=metro,bus,leguna,water,rickshaw]`
```
{ok, city, options:{cheapest, fastest, fewest_changes, safer_night},   # any may be missing
 other_ways:[{mode:"cng"|"ride_bike"|"ride_car"|"rickshaw"|"walk", minutes, km, fare}],
 warnings:["metro_hours"...], crow_km, ms, fare_sources:[…], complaint:{number,fallback,…},
 attribution:"© OpenStreetMap contributors (ODbL)", data_version}
option = {minutes, fare:{low,high,label:"official"|"estimate"|"mixed"}, changes, walk_m,
          modes:[…], status, legs:[leg…]}
leg (walk|rickshaw) = {mode, meters, minutes, from:{…}, to:{…}, fare|null}
leg (metro|bus|leguna|water) = {mode, route, route_bn, ref, route_id, status, source,
   board:{id,name,name_bn,lat,lon,status}, alight:{…}, towards:{…}, stops, via[], via_bn[],
   wait_min, minutes, km, fare, headway_min, exit_gate?:{ref,name,side:"N|E|S|W",lat,lon,near[]}}
```
No data for the city → `200 {ok:false, reason:"no_data", google_maps}`; no route
found → `{ok:false, reason:"no_route", other_ways, google_maps}`. Budget: < 500 ms.

## 3. Offline package (phone cache)
`GET city/package?city=dhaka[&v=<version>]` → gzip JSON `{v, city, net:{stops:{cols,rows},
routes:[…], gates:[…]}, overrides, rates, attribution}` or `{unchanged:true}`.
The phone can show stations/gates/routes and route offline from it.

## 4. Metro guide
`GET city/stations?city=dhaka` → `[{id,code,name,name_bn,lat,lon,gates}]` (line order).
`GET city/station/<id>?lat=&lon=` → `{station, gates:[{ref,name,side,lat,lon,near[],
stands[],buses[],lift,escalator,status}], which_gate, connecting_buses[], hours, frequency,
recharge[]}` — `lat/lon` = the user's destination → `which_gate` (geofence screen).
`GET city/metro` → line info: hours (Sat–Thu / Fri), first/last train, headways, fare rule
+ chart anchors, sources with dates.

## 5. Search / directories
`GET city/search?q=&city=` → stops, stations, routes (for "From here to New Market which bus").
`GET city/route/<id>` → full ordered stop list, company, ref, fare rule, status, sources.
`GET city/stops/near?lat=&lon=` → nearest stops with their routes.
`GET city/terminals`, `city/ghats`, `city/offices` → directory items
`{id,kind,name,name_bn,lat,lon,address,hours,papers[],routes[],routes_bn[] (same order/length as routes),status,sources:[{url,date}]}`.

## 6. Live reports (60-minute expiry, moderated)
`GET city/reports?lat=&lon=[&km=3]` → `[{id,kind,lat,lon,count,minutes_ago,route_id}]`
`POST city/reports {kind, lat, lon, route_id?}` kinds: `jam`, `road_closed`, `waterlogging`,
`bus_not_coming`, `bus_crowded`, `seats_free` → `{id,count}`. Same user + kind within
300 m/60 min counts once; 20/hour/user; `POST city/reports/<id>/flag` (abuse) → hidden after 3
flags or by the owner.

## 7. Corrections + user facts
`POST city/correction {target:"stop|route|gate|station|fare|terminal|office|other",
target_id, kind, text, lat?, lon?}` → 201 (Owner Admin → City data → Corrections).
`POST city/fare-report {mode:"rickshaw|leguna|bus|cng|water", km|from+to, paid}` →
crowd fare (rickshaw/leguna become "Reported by users" after enough reports).
`POST city/night-rating {route_id, stars:1..5}` → feeds Safer at night.

## 8. Trip learning (consent, no names)
`GET/POST city/trips/consent {on:bool}`; `POST city/trips {mode:"bus", points:[[unix_s,lat,lon],…]}`
(only with consent; first/last 300 m trimmed server-side; raw points deleted ≤ 7 days;
results stay Reported until several different trips confirm; never sold or shared).

## 9. Women (added 9 Nov for cityapp)
`GET city/women?city=` → `{women_buses:[{route_id,route,route_bn,company,from,to,hours,status,sources}],
reserved_seats:{text,text_bn,status,checked,source_url}, metro_women_coach:{…}, night:[{route_id,stars,count}]}`.
Every route (plan legs + `city/route/<id>`) carries `women_only: bool`. `women_buses` is empty until a
public BRTC list is confirmed (see CITY_DATA_GAPS_BN.md) — show the honest empty state.

## 10. Paid listings (Ad label)
Reuse `GET nearby/sponsored?lat=&lon=&cat=` (flag `nearby_sponsored`). Ads never appear in route
results, step lists, live reports or any safety screen; the router never reads listings.

Changes to this contract: additive only; announced in this file.
