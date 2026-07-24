# DR Database Decision — One-Page Summary

> WEDAS-1025 | 2026-07-23 | Architecture Review

---

## The Problem

Salesforce Scheduler goes down. We need a standby database that can accept appointments without double-booking advisors, then sync everything back when Salesforce recovers.

---

## The Numbers

| Metric | Value |
|---|---|
| Total data | ~200 MB |
| Active appointments | ~200K |
| Daily writes | ~5,000 |
| Peak TPS | A few per second |
| Read:write ratio | 10:1 |
| Availability bottleneck | Microsoft Graph API (~2 sec), not the DB |

---

## Three Options Evaluated

```
┌────────────────────────────────────────────────────────────────────┐
│                                                                    │
│   Option A               Option B              Option C            │
│   PostgreSQL only         Mongo only            PG + DocumentDB    │
│                                                                    │
│   ✅ One engine           ❌ No overlap guard    ❌ Two engines     │
│   ✅ One transaction      ❌ App-side joins      ❌ No cross-DB txn │
│   ✅ Overlap constraint   ❌ App-side locking    ❌ Split invariant │
│   ✅ $900/mo              ~$950/mo              ❌ $1,340/mo        │
│   ✅ RTO < 15 min         RTO ~14 min           ❌ RTO ~19 min     │
│                                                                    │
│   Score: 98.6             Score: 83.6            Score: 79.0       │
│   GATES: PASS             GATES: FAIL G1         GATES: FAIL G1+G2 │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## The Deciding Factor

Double-booking is a **time-range overlap** problem, not a key-uniqueness problem.

- `10:00–11:00` and `10:30–11:30` are **different keys** but **still collide**.
- Only PostgreSQL can enforce this at the storage layer (GiST EXCLUDE constraint, O(log n)).
- Document stores can only check exact-key equality — overlap slips through.
- Application-level checks race under concurrency and get bypassed by sync writes.

---

## Locked Team Decisions (11 Items)

1. Dual identity: UUID PK + Salesforce sf_id on every record
2. Customer table is flat, fed from API request only
3. No Account/Lead polymorphic parent in DR — resolve in SF at failback
4. One customer → many appointments, matched by customerId/MID
5. Separate entities: Customer, User, Advisor (advisor is subset of user)
6. No volatile profile metadata stored (call source systems at runtime)
7. Failback = manual batch job: find deltas, upsert to SF, write back sf_id
8. Appointment duration comes from work_type, not advisor
9. Skills filtering out of scope for Wealth
10. Service territory grouping is first-class (hours, caps, time zone)
11. Same DB and model for Wealth and WPA

---

## Scorecard Summary

| Metric (weight) | A: PG | B: Mongo | C: Hybrid |
|---|---:|---:|---:|
| Correctness (30%) | 100 | 50 | 50 |
| Atomicity (15%) | 100 | 100 | 99.9 |
| Failback determinism (15%) | 99 | 97 | 96 |
| Performance (10%) | 100 | 100 | 100 |
| Recovery (10%) | 100 | 100 | 89.5 |
| Operational simplicity (10%) | 100 | 90 | 69 |
| Cost efficiency (5%) | 100 | 100 | 74.6 |
| Schema flexibility (5%) | 75 | 100 | 100 |
| **Weighted total** | **98.6** | **83.6** | **79.0** |
| **Gate check** | **Pass** | **Fail** | **Fail** |

---

## Data Model at a Glance (19 Tables)

```
 ┌──────────┐     ┌──────────────────┐     ┌────────────────────┐
 │ CUSTOMER │────▶│SERVICE_APPOINTMENT│◀────│   WORK_TYPE        │
 └──────────┘     │  status, times   │     └────────────────────┘
                  │  territory, chan  │◀────┐
                  └───────┬──────────┘     │ ENGAGEMENT_CHANNEL
                          │                └────────────────────┘
              ┌───────────┼───────────┐
              ▼           ▼           ▼
      ┌──────────┐ ┌──────────┐ ┌──────────┐
      │ASSIGNED  │ │ATTENDEE  │ │  NOTE    │
      │RESOURCE  │ └──────────┘ └──────────┘
      └────┬─────┘
           ▼
   ┌──────────────┐     ┌──────────┐     ┌──────────────────┐
   │SERVICE       │────▶│ APP_USER │     │SERVICE_TERRITORY │
   │RESOURCE      │     └──────────┘     │  GROUP           │
   └──────┬───────┘                      └────────┬─────────┘
          │                                       ▼
   ┌──────┴───────┐                      ┌──────────────────┐
   │SHIFT │ STM   │                      │SERVICE_TERRITORY │
   └──────┴───────┘                      └──────────────────┘
```

---

## Recommendation

**Aurora PostgreSQL (Option A).** Enable `btree_gist` and add the exclusion constraint before go-live.

## When to Revisit

Only if: >5M active records, >500 sustained write TPS, or >50:1 read:write with DB as proven bottleneck.
