# Option B — MongoDB Only — WEDAS-1082b

> Story: WEDAS-1025 — DR Database Selection and Data Model Strategy 
> Subtask: WEDAS-1082b — Document Mongo-Only Option 
> Date: 2026-07-23 
> Authors: Naveen Chelluboina, team

---

## 1. Overview

Single MongoDB (or Amazon DocumentDB) instance stores everything — config, resources, appointments, audit. All data modeled as documents. No relational engine in the stack.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│ DAP DR App (Spring Boot) │
│ │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Spring Data MongoDB │ │
│ │ Writer endpoint (writes) │ Reader endpoint (reads)│ │
│ └────────────────────┬───────┴──────────────────────┘ │
│ │ │
│ ▼ │
│ ┌──────────────────────────────────────────────────┐ │
│ │ Amazon DocumentDB (MongoDB 5.0+) │ │
│ │ │ │
│ │ Primary ──sync── Replica │ │
│ │ │ │ │ │
│ │ ▼ ▼ │ │
│ │ ┌──────────────────────────────────┐ │ │
│ │ │ Replicated Storage (3 AZs) │ │ │
│ │ └──────────────────────────────────┘ │ │
│ └──────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

### Collections

| Collection | Purpose |
|---|---|
| `appointments` | Full appointment documents with embedded attendees, notes, advisor snapshots |
| `customers` | Request-fed customer identity documents |
| `users` | App user profiles |
| `serviceResources` | Advisor-specific documents referencing users |
| `serviceTerritories` | Territory and territory group documents |
| `shifts` | Advisor shift schedule documents |
| `territoryMembers` | Advisor-to-territory assignments |
| `workTypes` | Appointment types and durations |
| `channels` | Engagement channel types |
| `operatingHours` | Operating hours with embedded time slots |
| `outbox` | Event outbox for failback deltas |
| `notifications` | Notification tracking |
| `auditLog` | Operational logs |

---

## 3. Locked Decision Alignment

| Locked Decision | How Mongo-Only Handles It | Issue? |
|---|---|---|
| 1. Dual identity | `_id` (UUID) + `sfId` field on every document | No issue |
| 2. Customer is flat | Customer collection with customerId, type, name, email, phone | No issue |
| 3. No Account/Lead parent | Not modeled | No issue |
| 4. Customer → many appointments | Query appointments by `customer.customerId` | No issue |
| 5. User/Advisor separation | Separate `users` and `serviceResources` collections | No issue |
| 6. No volatile metadata | Not stored | No issue |
| 7. Failback batch job | Query `appointments` where `sfId` is null | Straightforward for extraction, but document shape must be flattened to SF structure |
| 8. Duration from work_type | Work type embedded in appointment at write time | Snapshot may drift from master |
| 9. Skills out of scope | N/A | No issue |
| 10. Territory grouping | Nested documents or separate collection with references | **No FK enforcement** — referential integrity is app-side only |
| 11. Shared model for Wealth + WPA | Shared collections | No issue |

---

## 4. Pros

| # | Advantage | Detail |
|---|---|---|
| 1 | Fastest single-record reads | No JOINs — get appointment by ID fetches one document with everything embedded. ~3 ms |
| 2 | Schema-free evolution | Adding a field to appointment means writing it. No DDL migration, no ALTER TABLE, no Flyway |
| 3 | Natural document shape | Appointment + attendees + notes + advisor snapshot = one document that mirrors the API response payload |
| 4 | Single engine | One connection pool, one monitoring dashboard, one failover — same operational simplicity as PG-only |
| 5 | Horizontal auto-sharding | DocumentDB/MongoDB can shard collections when data grows beyond single-node capacity |
| 6 | Compound nested indexes | Index directly on `assignedResources.corpId` or `customer.mid` without denormalization tables |
| 7 | Flexible query shape | Ad-hoc queries on any field path without pre-defining views |
| 8 | Bulk write performance | Single-document writes avoid multi-table transaction overhead. Bulk insert of 1,000 docs in < 1 second |

---

## 5. Cons

| # | Disadvantage | Severity | Detail |
|---|---|---|---|
| 1 | **Cannot enforce no-double-booking** | **Critical** | MongoDB/DocumentDB has no range-overlap exclusion construct. Unique indexes only work for exact-key equality. Two bookings `10:00–11:00` and `10:30–11:30` have different keys and both save. This is not a tuning issue — the engine class simply cannot express it |
| 2 | **No referential integrity** | **High** | No FK constraints between collections. An appointment can reference a non-existent territory, advisor, or work type. All relationship validation is app-side only |
| 3 | **Availability queries require app-side joins** | **High** | Availability calculation needs: shifts + territory members + existing appointments + operating hours + work type duration. In PG this is one SQL query. In Mongo, it's 4-5 separate collection reads stitched together in application code |
| 4 | **Multi-document transactions are limited** | **High** | MongoDB supports multi-doc transactions but with performance penalties (lock escalation, 60-second timeout). DocumentDB has even more restricted support. A 6-entity appointment create uses either multi-doc txn (fragile) or accepts partial writes |
| 5 | **No SQL for complex analytics** | Medium | Aggregation pipeline syntax is powerful but less intuitive than SQL for JOINs, subqueries, and window functions. Debugging availability logic is harder |
| 6 | **Data denormalization leads to drift** | Medium | Advisor names, territory names, work type details embedded in appointment documents become stale when the source document changes. Requires background reconciliation |
| 7 | **Team skill gap** | Medium | Team is SQL-native. MongoDB query language, aggregation pipelines, conditional writes, and index tuning require ramp-up time |
| 8 | **Failback flattening** | Medium | Appointment documents must be flattened and decomposed to match SF object structure (separate ServiceAppointment, AssignedResource, Attendee records) |
| 9 | **No declarative constraint system** | Low | Schema validation exists but cannot express business rules like "end_time > start_time" or "status transition is valid." All validation is app-side |
| 10 | **DocumentDB is not full MongoDB** | Low | No `$lookup` across collections, limited change streams, no client-side encryption. Some MongoDB patterns don't transfer |

---

## 6. The Overlap Problem — Why App-Level Checks Don't Save It

### The invariant

Never book the same advisor at two overlapping times.

### What Mongo can do

Unique compound index on `{advisorId, startTime, endTime}`. This prevents exact duplicates — same advisor, same start, same end. That's equality, not overlap.

### What Mongo cannot do

Reject `{advisor: A, start: 10:00, end: 11:00}` when `{advisor: A, start: 10:30, end: 11:30}` already exists. These are different keys. Both save. Both are valid under any index Mongo can create.

### App-level workarounds and why they fail

| Approach | Failure Mode |
|---|---|
| Read-then-write: query for conflicts, then insert if zero | **Race condition**. Two concurrent requests both read zero conflicts and both insert. The window is small but guaranteed to fire under load |
| Advisory lock in Redis/app: acquire lock on advisorId before check | **Bypass**. Sync writes from DEP and bulk imports write directly to DB without acquiring the app lock. The guard is walked around |
| Multi-document transaction with serializable isolation | **Performance and fragility**. Mongo serializable transactions are expensive, have a 60-second timeout, and DocumentDB support is limited. Not viable for a hot write path |

In PG, the `EXCLUDE USING gist` constraint fires on every write path — API, sync, bulk load — with zero app code and O(log n) performance.

---

## 7. Cost

| Component | Monthly |
|---|---|
| DocumentDB db.r6g.large (primary) | ~$600 |
| DocumentDB replica (1 instance) | ~$300 |
| Storage | ~$50 |
| **Total** | **~$950** |

Comparable to PG-only, slightly higher because DocumentDB instance pricing is marginally higher than Aurora PG.

---

## 8. Performance

### Reads

| Query | P95 Latency |
|---|---|
| Get appointment by ID | < 3 ms |
| Search appointments (compound index) | < 30 ms |
| Get availability (4-5 collection reads + app stitch) | < 300 ms |
| Branch availability (operating hours lookup) | < 20 ms |

### Writes

| Operation | P95 Latency |
|---|---|
| Create appointment (single doc) | < 20 ms |
| Cancel (single doc update) | < 10 ms |
| Reschedule (single doc update) | < 15 ms |
| Bulk sync (1,000 docs) | < 1 second |

### Throughput

| Metric | Capacity |
|---|---|
| Write TPS (peak) | ~2,000 (auto-scales) |
| Read TPS (with replica) | ~10,000 |
| Document size | ~2-5 KB |

---

## 9. Recovery

| Metric | Target | Expected |
|---|---|---|
| RPO | < 5 min | ~4 min (DEP sync) |
| RTO | < 15 min | ~14 min (single engine, less familiar tooling may slow drill) |
| Primary failover | automatic | ~30 seconds |
| Data loss on AZ failure | zero | 3-AZ replication |

RTO is within target but tighter than PG-only because team familiarity is lower.

---

## 10. Technology Stack

```
Spring Boot App
 ├── Spring Data MongoDB → Repository interfaces
 ├── MongoTemplate → Complex aggregation queries
 ├── No Flyway → Schema-less (validation via JSON Schema optional)
 └── @Transactional → Multi-doc txn (limited, fragile)
```

---

## 11. Verdict

Option B is not recommended. It matches PG-only on cost and operational simplicity (single engine), and beats it on raw read speed and schema flexibility. But it cannot enforce the core business invariant — no overlapping advisor bookings — at the storage layer. That single gap is disqualifying.

The advantages it offers (faster reads, flexible schema, auto-sharding) solve problems we don't have: our data is 200 MB, our reads are Graph-API-bound, our schema is stable, and we are orders of magnitude below sharding thresholds.

### Where Mongo-only would make sense instead

A system where:
- The critical invariant is key equality (e.g., "one document per entity"), not range overlap
- Reads vastly dominate writes (>50:1) and read latency is the actual bottleneck
- Schema changes frequently and unpredictably
- Data exceeds single-node capacity and needs horizontal sharding
- The team has MongoDB experience

Our scheduler DR meets none of these conditions.
