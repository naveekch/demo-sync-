# Three DB Options - Architecture Fit Analysis

> Date: 2026-07-23

---

## 1. Options Evaluated

- Option A: PostgreSQL only
- Option B: Mongo only
- Option C: Hybrid (PostgreSQL for config plus document store for appointments)

---

## 2. Requirement Fit Matrix

| Requirement | A PG-only | B Mongo-only | C Hybrid |
|---|---|---|---|
| R1 No overlap booking guarantee at DB layer | Full fit | Not fit | Not fit if appointments in document store |
| R2 Atomic create write set | Full fit | Partial fit | Not fit across engines |
| R3 Deterministic sync/failback identities | Full fit | Full fit | Full fit |
| R4 CustomerId/MID-centered model | Full fit | Full fit | Full fit |
| R5 Delta failback with idempotency | Full fit | Partial fit | Partial fit |
| F2 Availability with joins and rules | Full fit | Partial fit (app-side joins) | Partial fit (cross-engine assembly) |
| N1 RTO less than 15 min | Full fit | Partial fit | Higher risk |
| N4 Operational simplicity | Full fit | Medium fit | Low fit |
| N5 Cost discipline | Full fit | Medium fit | Low fit |

---

## 3. Suitability Narrative

### Option A: PostgreSQL only

Best architecture fit. It satisfies correctness and outage-operability requirements with one transactional store. JSONB covers needed document flexibility without splitting systems.

### Option B: Mongo only

Strong document ergonomics, but no native overlap exclusion semantics. It can be made safer with app locking patterns, but that weakens deterministic correctness under concurrency and integration bypass paths.

### Option C: Hybrid

Looks attractive for read shape and flexibility, but correctness and atomicity burdens increase because appointment invariants and reference joins are split across engines. Outage runbooks and failback complexity increase.

---

## 4. Proof Point For Disqualification Risk

Double-booking is a time-range overlap problem, not key equality:

- Booking A: 10:00 to 11:00
- Booking B: 10:30 to 11:30

Any design that depends only on unique keys for exact start and end equality cannot reject this overlap at storage level. For locked requirements, this is disqualifying unless solved by the primary appointment store itself.

---

## 5. Architecture Recommendation

Choose Option A for Phase 1 and Phase 2 baseline.

Keep Option C as a future optimization path only if measured scale triggers are exceeded and correctness controls remain enforceable in the appointment write path.
