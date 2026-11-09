# Hey Assisto — evaluation report

Generated 2026-10-23 06:16 UTC by tools/wakeword/pipeline.py

Shipped candidate: **reg_h128_lowneg_ensemble** (chosen by validation far-field recall at Normal). Thresholds (validation only, 13.231 h): {'low': 0.978582, 'normal': 0.952574, 'high': 0.921705} = logits {'low': 4.65, 'normal': 3.65, 'high': 3.0} / T 1.216667; app patience {'low': 2, 'normal': 1, 'high': 1}; in-graph smoothing k=2 frames; cooldown 2000 ms.

## Targets (shipped candidate, Normal)

- Plain Bangla (eval_bn) < 1.0 FA / 10 h -> MET
- TV-like Bangla + music (eval_tv) < 1.0 FA / 10 h -> NOT MET
- Far-field 1-2 m (synthetic) FRR < 10% -> MET
- Test negative hours 23.5 >= 20.0 -> MET
- False rejects are measured on SYNTHETIC far-field speech; confirm on a real phone (owner_actions/PHONE_TEST_CHECKLIST.md, owner_actions/WAKEWORD_RECORDING_BN.md). 0 false accepts in 10 h still allows a true rate up to ~3 per 10 h (95% bound).

### Shipped candidate: reg_h128_lowneg_ensemble

| test set | hours | level | false accepts | per 10 h | 95% upper / 10 h |
|---|---|---|---|---|---|
| eval_bn | 10.0 | low | 0 | 0.0 | 2.996 |
| eval_bn | 10.0 | normal | 0 | 0.0 | 2.996 |
| eval_bn | 10.0 | high | 0 | 0.0 | 2.996 |
| eval_tv | 10.0 | low | 1 | 1.0 | 4.744 |
| eval_tv | 10.0 | normal | 3 | 3.0 | 7.754 |
| eval_tv | 10.0 | high | 3 | 3.0 | 7.754 |
| eval_en | 2.0 | low | 0 | 0.0 | 14.979 |
| eval_en | 2.0 | normal | 0 | 0.0 | 14.979 |
| eval_en | 2.0 | high | 0 | 0.0 | 14.979 |
| eval_tv_en | 1.497 | low | 0 | 0.0 | 20.012 |
| eval_tv_en | 1.497 | normal | 0 | 0.0 | 20.012 |
| eval_tv_en | 1.497 | high | 0 | 0.0 | 20.012 |

| false-reject set | level | clips | detected | FRR |
|---|---|---|---|---|
| synthetic_far_field_1_2m | low | 500 | 436 | 0.128 |
| synthetic_far_field_1_2m | normal | 500 | 461 | 0.078 |
| synthetic_far_field_1_2m | high | 500 | 465 | 0.07 |
| synthetic_near_0_3_0_8m | low | 500 | 458 | 0.084 |
| synthetic_near_0_3_0_8m | normal | 500 | 475 | 0.05 |
| synthetic_near_0_3_0_8m | high | 500 | 480 | 0.04 |
| sim_room_tv_on_5_15db | low | 500 | 397 | 0.206 |
| sim_room_tv_on_5_15db | normal | 500 | 432 | 0.136 |
| sim_room_tv_on_5_15db | high | 500 | 440 | 0.12 |

## Every candidate (Normal level)

| candidate | thresholds | eval_bn FA/10h | eval_tv FA/10h | eval_en FA/10h | eval_tv_en FA/10h | FRR synthetic_far_field_1_2m | FRR synthetic_near_0_3_0_8m | FRR sim_room_tv_on_5_15db |
|---|---|---|---|---|---|---|---|---|
| reg_h128_seed_1234 | 0.952574 | 0.0 | 2.0 | 0.0 | 0.0 | 0.092 | 0.05 | 0.142 |
| reg_h128_seed_2025 | 0.945318 | 0.0 | 1.0 | 0.0 | 0.0 | 0.082 | 0.054 | 0.162 |
| reg_h128_seed_7 | 0.947846 | 0.0 | 3.0 | 0.0 | 0.0 | 0.08 | 0.06 | 0.14 |
| reg_h128_ensemble | 0.952574 | 0.0 | 1.0 | 0.0 | 0.0 | 0.088 | 0.048 | 0.144 |
| reg_h128_lowneg_seed_1234 | 0.952574 | 0.0 | 0.0 | 0.0 | 0.0 | 0.108 | 0.05 | 0.164 |
| reg_h128_lowneg_seed_2025 | 0.952574 | 0.0 | 3.0 | 0.0 | 0.0 | 0.09 | 0.05 | 0.162 |
| reg_h128_lowneg_seed_7 | 0.952574 | 0.0 | 1.0 | 0.0 | 0.0 | 0.102 | 0.062 | 0.168 |
| reg_h128_lowneg_ensemble | 0.952574 | 0.0 | 3.0 | 0.0 | 0.0 | 0.078 | 0.05 | 0.136 |
| reg_h128_d3_seed_1234 | 0.952574 | 0.0 | 1.0 | 0.0 | 0.0 | 0.13 | 0.076 | 0.21 |
| reg_h128_d3_seed_2025 | 0.952574 | 0.0 | 2.0 | 0.0 | 0.0 | 0.098 | 0.06 | 0.172 |
| reg_h128_d3_seed_7 | 0.952574 | 0.0 | 1.0 | 0.0 | 0.0 | 0.13 | 0.088 | 0.188 |
| reg_h128_d3_ensemble | 0.952574 | 0.0 | 1.0 | 0.0 | 0.0 | 0.104 | 0.062 | 0.172 |

## Seed variance (single-seed models; mean ± sd [min..max])

- **reg_h128 / low**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 0.222 ± 0.416 [0.0..1.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.1649 ± 0.0213 [0.132..0.204]; frr_synthetic_near_0_3_0_8m 0.1251 ± 0.0192 [0.1..0.168]; frr_sim_room_tv_on_5_15db 0.2667 ± 0.0368 [0.224..0.35]
- **reg_h128 / normal**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 1.556 ± 0.956 [0.0..3.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.1013 ± 0.0175 [0.08..0.13]; frr_synthetic_near_0_3_0_8m 0.0611 ± 0.0123 [0.05..0.088]; frr_sim_room_tv_on_5_15db 0.1676 ± 0.0203 [0.14..0.21]
- **reg_h128 / high**: fa_per_10h_eval_bn 0.111 ± 0.314 [0.0..1.0]; fa_per_10h_eval_tv 3.333 ± 1.491 [1.0..5.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.0813 ± 0.0083 [0.064..0.094]; frr_synthetic_near_0_3_0_8m 0.0431 ± 0.0095 [0.026..0.058]; frr_sim_room_tv_on_5_15db 0.1353 ± 0.0117 [0.108..0.152]
- **reg_h128_lowneg / low**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 0.333 ± 0.471 [0.0..1.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.166 ± 0.0059 [0.158..0.172]; frr_synthetic_near_0_3_0_8m 0.1233 ± 0.005 [0.118..0.13]; frr_sim_room_tv_on_5_15db 0.256 ± 0.0107 [0.244..0.27]
- **reg_h128_lowneg / normal**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 1.333 ± 1.247 [0.0..3.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.1 ± 0.0075 [0.09..0.108]; frr_synthetic_near_0_3_0_8m 0.054 ± 0.0057 [0.05..0.062]; frr_sim_room_tv_on_5_15db 0.1647 ± 0.0025 [0.162..0.168]
- **reg_h128_lowneg / high**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 2.0 ± 1.414 [1.0..4.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.0873 ± 0.0057 [0.08..0.094]; frr_synthetic_near_0_3_0_8m 0.05 ± 0.0057 [0.046..0.058]; frr_sim_room_tv_on_5_15db 0.146 ± 0.0049 [0.14..0.152]
- **reg_h128_d3 / low**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 0.333 ± 0.471 [0.0..1.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.1867 ± 0.0168 [0.164..0.204]; frr_synthetic_near_0_3_0_8m 0.1447 ± 0.0188 [0.122..0.168]; frr_sim_room_tv_on_5_15db 0.3087 ± 0.0308 [0.276..0.35]
- **reg_h128_d3 / normal**: fa_per_10h_eval_bn 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv 1.333 ± 0.471 [1.0..2.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.1193 ± 0.0151 [0.098..0.13]; frr_synthetic_near_0_3_0_8m 0.0747 ± 0.0115 [0.06..0.088]; frr_sim_room_tv_on_5_15db 0.19 ± 0.0156 [0.172..0.21]
- **reg_h128_d3 / high**: fa_per_10h_eval_bn 0.333 ± 0.471 [0.0..1.0]; fa_per_10h_eval_tv 3.0 ± 0.0 [3.0..3.0]; fa_per_10h_eval_en 0.0 ± 0.0 [0.0..0.0]; fa_per_10h_eval_tv_en 0.0 ± 0.0 [0.0..0.0]; frr_synthetic_far_field_1_2m 0.084 ± 0.0043 [0.08..0.09]; frr_synthetic_near_0_3_0_8m 0.046 ± 0.0075 [0.038..0.056]; frr_sim_room_tv_on_5_15db 0.1327 ± 0.0025 [0.13..0.136]

Embedding hours: `{"s_bn": 8.0, "s_hi": 3.0, "s_en": 4.0, "s_mspeech": 7.326, "s_musan": 6.0, "s_tv_bn": 8.0, "s_tv_hi": 3.0, "s_tv_en": 4.0, "s_babble_bn": 4.0, "s_bn_slow": 3.0, "s_bn_fast": 3.0, "v_bn": 1.538, "v_bn2": 3.64, "v_hi": 1.5, "v_tv_bn": 1.538, "v_tv_bn2": 3.64, "v_tv_en": 1.0, "v_tts": 0.375, "eval_bn": 10.0, "eval_tv": 10.0, "eval_en": 2.0, "eval_tv_en": 1.497}`
