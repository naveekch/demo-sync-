# Database Selection Metrics Formula and Scorecard

> Date: 2026-07-23

---

## 1. How To Score

Use a weighted score from 0 to 100.

$$\text{Score}_{\text{total}} = \sum_{i=1}^{8} w_i \times S_i$$

Where:

- $w_i$ is the metric weight (sum of all weights = 100)
- $S_i$ is the normalized metric score from 0 to 100

Database rating bands:

| Total Score | Rating |
|---|---|
| 90 to 100 | Excellent fit |
| 75 to 89 | Good fit |
| 60 to 74 | Conditional fit |
| below 60 | Not fit |

---

## 2. Metric Set

| ID | Metric | Weight |
|---|---|---|
| M1 | Correctness score | 30 |
| M2 | Atomicity score | 15 |
| M3 | Failback determinism score | 15 |
| M4 | Performance score | 10 |
| M5 | Recovery score | 10 |
| M6 | Operational simplicity score | 10 |
| M7 | Cost efficiency score | 5 |
| M8 | Flexibility score | 5 |

---

## 3. Formulas

### M1 Correctness score

$$M_1 = 100 \times \left(1 - \frac{\text{overlap\_violations}}{\text{booking\_attempts}}\right)$$

- overlap_violations: confirmed commits that violate advisor-time overlap rule under concurrency testing
- booking_attempts: total create or reschedule attempts in the same test run

Target: 100. Any score below 100 means the DB cannot guarantee correctness alone.

### M2 Atomicity score

$$M_2 = 100 \times \left(1 - \frac{\text{partial\_write\_incidents}}{\text{total\_write\_transactions}}\right)$$

- partial_write_incidents: operations where not all required entities in the appointment write set were persisted together

Target: 100 for single-engine ACID. Lower for multi-engine designs.

### M3 Failback determinism score

$$M_3 = 100 \times \frac{\text{matched\_upserts}}{\text{failback\_rows\_processed}}$$

- matched_upserts: records deterministically matched by sf_id and upserted exactly once
- failback_rows_processed: total rows in the failback batch

Target: 99.9 or above.

### M4 Performance score

$$M_4 = 50 \times \min\!\left(1,\; \frac{\text{target\_p95\_ms}}{\text{observed\_p95\_ms}}\right) + 50 \times \min\!\left(1,\; \frac{\text{observed\_tps}}{\text{target\_tps}}\right)$$

Scale: 0 to 100. At our scale all three options are expected to exceed targets, so scores cluster near the top.

### M5 Recovery score

$$M_5 = 50 \times \min\!\left(1,\; \frac{\text{target\_RTO\_min}}{\text{observed\_RTO\_min}}\right) + 50 \times \min\!\left(1,\; \frac{\text{target\_RPO\_min}}{\text{observed\_RPO\_min}}\right)$$

Lower observed RTO/RPO (better recovery) clamps at 1.0 and earns full marks for that half.

### M6 Operational simplicity score

$$M_6 = 100 - \left(12 \times E + 8 \times R + 6 \times M + 5 \times J\right)$$

Where (all values are "extra above baseline of 1"):

- $E$ = extra DB engines beyond the first (0 or 1)
- $R$ = extra failover runbooks beyond the first (0 or 1)
- $M$ = extra migration pipelines beyond the first (0 or 1)
- $J$ = app-side join overhead level (0 = native SQL joins, 1 = moderate app stitching, 2 = heavy app-side joins)

Clamp result to 0 to 100.

### M7 Cost efficiency score

$$M_7 = 100 \times \min\!\left(\frac{\text{monthly\_budget}}{\text{observed\_monthly\_cost}},\; 1\right)$$

Within or under budget = 100. Over budget scales proportionally down.

### M8 Flexibility score

$$M_8 = 100 \times \min\!\left(\frac{\text{target\_schema\_change\_days}}{\text{observed\_schema\_change\_days}},\; 1\right)$$

Measures how quickly schema can evolve. Faster than target = 100.

---

## 4. Level Ratings Per Metric

| Metric Score | Level |
|---|---|
| 95 to 100 | Level 5 |
| 85 to 94 | Level 4 |
| 70 to 84 | Level 3 |
| 50 to 69 | Level 2 |
| below 50 | Level 1 |

---

## 5. Prefilled Scorecard (Projected Estimates)

Values below are projected based on architecture analysis and known system characteristics. Replace with measured values after load testing and chaos testing.

### 5.1 Input Values Used

| Input | Option A (PG) | Option B (Mongo) | Option C (Hybrid) |
|---|---|---|---|
| overlap_violations (100 concurrent conflict test) | 0 | 2 | 2 |
| booking_attempts (test run) | 5,000 | 5,000 | 5,000 |
| partial_write_incidents | 0 | 0 | 5 |
| total_write_transactions | 5,000 | 5,000 | 5,000 |
| matched_upserts / failback_rows | 990/1,000 | 970/1,000 | 960/1,000 |
| target_p95_ms / observed_p95_ms | 100/45 | 100/30 | 100/35 |
| observed_tps / target_tps | 500/250 | 500/250 | 500/250 |
| target_RTO / observed_RTO (min) | 15/12 | 15/14 | 15/19 |
| target_RPO / observed_RPO (min) | 5/3 | 5/4 | 5/4 |
| extra engines (E) | 0 | 0 | 1 |
| extra runbooks (R) | 0 | 0 | 1 |
| extra migrations (M) | 0 | 0 | 1 |
| app join level (J) | 0 | 2 | 1 |
| monthly_budget | $1,000 | $1,000 | $1,000 |
| observed_monthly_cost | $900 | $950 | $1,340 |
| target_schema_change_days | 3 | 3 | 3 |
| observed_schema_change_days | 4 | 1 | 2 |

### 5.2 Derived Metric Scores

| Metric | Formula Result A | Formula Result B | Formula Result C |
|---|---|---|---|
| M1 | 100 × (1 - 0/5000) = **100** | 100 × (1 - 2/5000) = **99.96** | 100 × (1 - 2/5000) = **99.96** |
| M2 | 100 × (1 - 0/5000) = **100** | 100 × (1 - 0/5000) = **100** | 100 × (1 - 5/5000) = **99.90** |
| M3 | 100 × 990/1000 = **99.0** | 100 × 970/1000 = **97.0** | 100 × 960/1000 = **96.0** |
| M4 | 50×min(1,100/45) + 50×min(1,500/250) = **100** | 50×min(1,100/30) + 50×min(1,500/250) = **100** | 50×min(1,100/35) + 50×min(1,500/250) = **100** |
| M5 | 50×min(1,15/12) + 50×min(1,5/3) = **100** | 50×min(1,15/14) + 50×min(1,5/4) = **100** | 50×min(1,15/19) + 50×min(1,5/4) = **89.47** |
| M6 | 100 - (12×0+8×0+6×0+5×0) = **100** | 100 - (12×0+8×0+6×0+5×2) = **90** | 100 - (12×1+8×1+6×1+5×1) = **69** |
| M7 | 100×min(1000/900,1) = **100** | 100×min(1000/950,1) = **100** | 100×min(1000/1340,1) = **74.63** |
| M8 | 100×min(3/4,1) = **75** | 100×min(3/1,1) = **100** | 100×min(3/2,1) = **100** |

### 5.3 Important Note on M1

The formula produces near-identical scores for all three options (99.96 vs 100) because even a few violations in thousands of attempts look small as a percentage. This is misleading for a zero-tolerance requirement. That is why M1 is backed by the gate check in the comparison matrix: **any overlap violation at all disqualifies the option**, regardless of the percentage score. The gate check and M1 score work together.

Adjusted M1 values for the scorecard below apply a hard penalty: if the option cannot enforce the constraint at the storage layer, M1 is capped at 50 regardless of observed test outcome, because bypass paths (sync writes, future integrations) will eventually produce violations.

### 5.4 Final Weighted Scorecard

| Metric | Weight | A (PG) | B (Mongo) | C (Hybrid) |
|---|---:|---:|---:|---:|
| M1 Correctness | 30 | 100 | 50 | 50 |
| M2 Atomicity | 15 | 100 | 100 | 99.90 |
| M3 Failback determinism | 15 | 99.0 | 97.0 | 96.0 |
| M4 Performance | 10 | 100 | 100 | 100 |
| M5 Recovery | 10 | 100 | 100 | 89.47 |
| M6 Operational simplicity | 10 | 100 | 90 | 69 |
| M7 Cost efficiency | 5 | 100 | 100 | 74.63 |
| M8 Flexibility | 5 | 75 | 100 | 100 |

### 5.5 Weighted Totals (Verified Arithmetic)

**Option A:**

$(30 \times 100) + (15 \times 100) + (15 \times 99) + (10 \times 100) + (10 \times 100) + (10 \times 100) + (5 \times 100) + (5 \times 75) = 3000 + 1500 + 1485 + 1000 + 1000 + 1000 + 500 + 375 = 9860$

$\text{Score}_A = 9860 / 100 = \mathbf{98.60}$ — Excellent fit

**Option B:**

$(30 \times 50) + (15 \times 100) + (15 \times 97) + (10 \times 100) + (10 \times 100) + (10 \times 90) + (5 \times 100) + (5 \times 100) = 1500 + 1500 + 1455 + 1000 + 1000 + 900 + 500 + 500 = 8355$

$\text{Score}_B = 8355 / 100 = \mathbf{83.55}$ — Good fit (but fails gate G1)

**Option C:**

$(30 \times 50) + (15 \times 99.90) + (15 \times 96) + (10 \times 100) + (10 \times 89.47) + (10 \times 69) + (5 \times 74.63) + (5 \times 100) = 1500 + 1498.50 + 1440 + 1000 + 894.70 + 690 + 373.15 + 500 = 7896.35$

$\text{Score}_C = 7896.35 / 100 = \mathbf{78.96}$ — Good fit (but fails gates G1 and G2)

### 5.6 Summary

| Option | Total Score | Rating | Gate Status | Final Verdict |
|---|---:|---|---|---|
| A (PostgreSQL only) | 98.60 | Excellent fit | Pass | Recommended |
| B (Mongo only) | 83.55 | Good fit | Fail G1 | Disqualified |
| C (Hybrid) | 78.96 | Good fit | Fail G1, G2 | Disqualified |

Options B and C score reasonably on non-correctness metrics but are disqualified by the gate check. This demonstrates that the selection is driven by the fundamental overlap constraint requirement, not by an arbitrary preference.
