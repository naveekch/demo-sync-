# Option C — Hybrid (PostgreSQL + DocumentDB) — WEDAS-1082

> Story: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> Subtask: WEDAS-1082 — Document Hybrid Option  
> Updated: 2026-07-23  
> Authors: Naveen Chelluboina, team

---

## 1. Overview

Two engines: Aurora PostgreSQL for config/reference/resource data, Amazon DocumentDB (MongoDB-compatible) for appointment documents. The idea is "right tool for each job" — relational integrity for config, document flexibility for appointments.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                      DAP DR App (Spring Boot)                 │
│                                                              │
│  ┌─────────────────────┐     ┌────────────────────────┐     │
│  │  Config Service      │     │  Appointment Service    │     │
│  │  (Spring Data JPA)   │     │  (Spring Data MongoDB)  │     │
│  └──────────┬──────────┘     └───────────┬────────────┘     │
│             │                            │                   │
│             ▼                            ▼                   │
│  ┌─────────────────────┐     ┌────────────────────────┐     │
│  │  Aurora PostgreSQL   │     │   Amazon DocumentDB     │     │
│  │  (Config/Resources)  │     │   (Appointments)        │     │
│  └─────────────────────┘     └────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

### Data Split

| Engine | Stores | Why |
|---|---|---|
| PostgreSQL | territories, territory groups, operating hours, time slots, users, advisors, shifts, territory members, work types, channels, constraints, scheduler config | Relational joins for availability |
| DocumentDB | appointments (denormalized with embedded attendees, notes, advisor snapshots) | Document-per-appointment read shape |

---

## 3. Locked Decision Alignment

| Locked Decision | How Hybrid Handles It | Issue? |
|---|---|---|
| 1. Dual identity | Both engines store UUID + sf_id | No issue |
| 2. Customer is flat | Customer embedded in appointment document | No issue |
| 3. No Account/Lead parent | Not modeled | No issue |
| 4. Customer → many appointments | Match by customerId in document query | No issue |
| 5. User/Advisor separation | User + advisor in PG; advisor snapshot embedded in appointment doc | Snapshot drifts if advisor changes |
| 6. No volatile metadata | Not stored | No issue |
| 7. Failback batch job | Must export documents from DocDB, join with PG config to build SF payload | **Added complexity** |
| 8. Duration from work_type | Work type in PG, embedded in doc at write time | Snapshot may drift |
| 9. Skills out of scope | N/A | No issue |
| 10. Territory grouping | Territory group hierarchy in PG | No issue |
| 11. Shared model for Wealth + WPA | Shared PG config; shared document shape | No issue |

---

## 4. Pros

| # | Advantage | Detail |
|---|---|---|
| 1 | Fast single-document reads | Get appointment by ID is one document fetch, no JOINs. ~3 ms vs ~5 ms in PG |
| 2 | Natural API response shape | Document structure mirrors the appointment API response — attendees, notes, advisor all embedded |
| 3 | Schema-free appointment evolution | Adding a new field to appointment doesn't require DDL migration |
| 4 | DocumentDB auto-sharding | Horizontal write scaling built into the engine |
| 5 | Compound indexes on nested fields | Can index `assignedResources.corpId` or `customer.mid` directly |
| 6 | Config stays relational | Availability computation uses SQL joins in PG — correct engine for that job |

---

## 5. Cons

| # | Disadvantage | Severity | Detail |
|---|---|---|---|
| 1 | **Cannot enforce no-double-booking** | **Critical** | Appointments live in DocumentDB. DocumentDB only supports exact-key uniqueness, not time-range overlap exclusion. The core invariant cannot be a storage guarantee |
| 2 | **No cross-engine transaction** | **Critical** | A create writes the appointment (DocDB) + outbox/notification rows. No shared commit boundary. Partial writes are possible, requiring saga/compensation logic that gets exercised for the first time during the outage the system exists to survive |
| 3 | **Failback is harder** | High | Must export documents, flatten embedded entities, re-join with PG config data to reconstruct SF upsert payloads. Two-engine coordination on the worst-case recovery path |
| 4 | **Two engines to operate during outage** | High | Two failovers that must both succeed. Two monitoring dashboards. Two backup strategies. Two connection pools. RTO drifts to ~19 min, missing the 15-min target |
| 5 | **Availability queries cross engines** | Medium | Need shifts and territory members from PG, existing bookings from DocDB, then stitch results in the app layer |
| 6 | **Data duplication and drift** | Medium | Advisor name, territory name, work type name are denormalized into documents at write time. If the source record changes in PG, existing documents are stale |
| 7 | **Two data access layers** | Medium | Spring Data JPA for PG + Spring Data MongoDB for DocDB. Two ORM patterns, two test container setups, two sets of repository interfaces |
| 8 | **Team skill gap** | Medium | MongoDB query patterns, aggregation pipelines, and conditional writes are not the team's native skill set |
| 9 | **DocumentDB is not full MongoDB** | Low | No `$lookup` across collections, limited change streams, no client-side field-level encryption. Some MongoDB patterns simply don't work |
| 10 | **Higher cost** | Low | ~$1,340/month vs ~$900/month for PG-only (+50%) |

---

## 6. The Overlap Problem — Why It's Fatal for This Design

The system's core promise: never book the same advisor at two overlapping times. The overlap test:

```
WHERE advisor_id = :advisor
  AND status <> 'Canceled'
  AND start < :requestedEnd
  AND end   > :requestedStart
```

`10:00–11:00` and `10:30–11:30` are different keys. A unique index on `{advisor, start, end}` accepts both.

**In PG**: solved with `EXCLUDE USING gist (advisor WITH =, tstzrange(start, end) WITH &&)` — declarative, fires on every write path, O(log n).

**In DocumentDB**: no range-overlap construct exists. Options and why they fail:

1. **App-level check-then-insert**: two concurrent requests both read zero conflicts and both insert. Race condition.
2. **DocumentDB conditional write (`$setOnInsert`)**: only works for exact-key conflicts, not overlapping ranges.
3. **Application-level advisory lock**: sync writes and bulk imports bypass the app layer entirely — the lock is walked around.

The invariant and its enforcement are in two different databases. The guarantee is structurally impossible.

---

## 7. Cost

| Component | Monthly |
|---|---|
| Aurora PG db.r6g.medium (config only) | ~$300 |
| DocumentDB db.r6g.large (writer) | ~$600 |
| DocumentDB Reader (1 instance) | ~$400 |
| Storage (both engines) | ~$40 |
| **Total** | **~$1,340** |

50% more than Option A with no correctness advantage.

---

## 8. Recovery

| Metric | Target | Expected |
|---|---|---|
| RPO | < 5 min | ~4 min (DEP sync to DocDB) |
| RTO | < 15 min | **~19 min** (two engines to validate, two failovers) |
| Data loss | zero | Both engines have Multi-AZ replication |

RTO misses the 15-minute target.

---

## 9. Operational Complexity Side-by-Side

| Dimension | Option A (PG-only) | Option C (Hybrid) |
|---|---|---|
| DB engines | 1 | 2 |
| Connection strings | 2 | 4 |
| Monitoring dashboards | 1 | 2 |
| Backup strategies | 1 | 2 |
| Failover procedures | 1 | 2 |
| Migration tools | Flyway | Flyway + custom DocDB scripts |
| Data access layers | JPA | JPA + Spring Data MongoDB |
| Integration test setup | 1 container | 2 containers |

---

## 10. When Hybrid Would Be Justified

Only if all of these are true simultaneously:

- Appointment reads exceed 50:1 over writes with DB as proven bottleneck
- Document shape changes frequently and unpredictably beyond JSONB flexibility
- Horizontal sharding is needed (>5M active records)
- An alternative mechanism for overlap enforcement is proven in production

None of these conditions are met or projected.

---

## 11. Verdict

Option C is not recommended. It puts the one invariant we must guarantee (no overlapping bookings) and the only engine that can enforce it in two different databases. The performance advantage it offers (slightly faster single-document reads) is invisible at our scale and irrelevant when Graph API latency dominates. The added cost, operational complexity, and failed RTO target provide no offsetting benefit.
