# Option A — PostgreSQL Only (Aurora PostgreSQL) — WEDAS-1081

> Story: WEDAS-1025 — DR Database Selection and Data Model Strategy 
> Subtask: WEDAS-1081 — Document Option A 
> Updated: 2026-07-23 | Revised: 2026-07-30 (Serverless v2 as Phase 1 primary; buffer-aware/allow_overlap constraint; skills gated-off; territory FKs) 
> Authors: Naveen Chelluboina, team

---

## 1. Overview

Single Aurora PostgreSQL database holds everything: config, resources, appointments, audit, and integration state. One engine, one transaction boundary, one operational surface.

---

## 2. Architecture

### 2.1 Phase 1 — Baseline (1 writer + 1 reader on Aurora Serverless v2, ~$150–200/mo idle)

*Start here. Handles our current ~200 MB / few TPS workload with room to spare. The diagram shows the logical writer + reader topology — it's identical on Serverless v2, which auto-scales compute (the `db.r6g.large` labels are the Provisioned equivalent at load, ~$900/mo). See §3.8 for the flavor decision.*

```
┌─────────────────────────────────────────────────────────────────────┐
│ DAP DR App (Spring Boot) │
│ │
│ CREATE / CANCEL GET / SEARCH / AVAILABILITY │
│ RESCHEDULE writes reads (9 out of every 10 ops) │
│ │ │ │
│ ▼ ▼ │
│ Writer endpoint Reader endpoint │
│ (RDS Proxy pool) (RDS Proxy pool) │
└──────────┬──────────────────────────────┬───────────────────────────┘
 │ │
 ▼ ▼
┌──────────────────┐ ┌──────────────────┐
│ WRITER instance │ │ READER instance │
│ db.r6g.large │ │ db.r6g.large │
│ (AZ-a) │ │ (AZ-b) │
│ │ │ │
│ ALL writes go │ │ ALL reads go │
│ here only │ │ here │
└────────┬─────────┘ └────────┬─────────┘
 │ │
 │ sync lag: ~5–20 ms │
 │ (shared storage, not │
 │ streaming replication) │
 ▼ ▼
┌─────────────────────────────────────────────────────────┐
│ SHARED AURORA STORAGE LAYER │
│ │
│ AZ-a ████████ copy 1 (primary write) │
│ ████████ copy 2 │
│ AZ-b ████████ copy 3 │
│ ████████ copy 4 ← reader serves from here │
│ AZ-c ████████ copy 5 │
│ ████████ copy 6 │
│ │
│ 6 copies across 3 availability zones │
│ Writes quorum: 4 of 6 copies must confirm │
│ Reads: any available copy │
│ Storage auto-grows: starts at 10 GB → up to 128 TB │
└─────────────────────────────────────────────────────────┘
```

**Key points:**
- The writer and reader are **separate compute instances** but share the **same storage** — there's no traditional replication stream copying data between them. The reader just reads from the shared layer.
- **Sync lag ~5–20 ms** — much lower than traditional Postgres streaming replication (~seconds) because there's no data to copy, just a page-cache invalidation signal.
- If the **writer fails**, Aurora promotes the reader to writer in **< 30 seconds** (no data to catch up on — shared storage means it's already there).
- **RDS Proxy** sits in front of both endpoints — it pools connections so the app doesn't open hundreds of raw DB connections.

---

### 2.2 Phase 2 — Scale up (1 writer + 2 readers, ~$1,250/mo)

*Add a second reader if read load grows — availability queries are the main driver.*

```
┌─────────────────────────────────────────────────────────────────────┐
│ DAP DR App │
│ writes reads (load-balanced) │
│ │ │ │ │
└─────────────┼────────────────────┼───────────┼───────────────────────┘
 │ │ │
 ▼ ▼ ▼
 ┌────────────────┐ ┌──────────────┐ ┌──────────────┐
 │ WRITER (AZ-a) │ │ READER 1 │ │ READER 2 │
 │ db.r6g.large │ │ (AZ-b) │ │ (AZ-c) │
 │ │ │ db.r6g.large │ │ db.r6g.medium│
 └───────┬────────┘ └──────┬───────┘ └──────┬───────┘
 │ │ │
 └──────────────────┴──────────────────┘
 │
 SHARED STORAGE
 (same 6-copy layer)
```

**Why 2 readers here:** availability queries are the heaviest reads — they join shifts, the advisor's primary/secondary territory, existing appointments, and operating hours. At higher advisor concurrency, offloading those to two readers prevents them from competing with API reads.

**Cost:** ~$1,250/mo (add ~$350 for the second reader). Still well under the hybrid's $1,340 — *and* correctness stays intact.

---

### 2.3 The full scaling ladder (before you'd ever need a different engine)

```
Current state
 │
 ▼
① Vertical resize → bigger instance (db.r6g.xlarge → 2xlarge)
 │ takes minutes, no schema change
 ▼
② Add read replicas → up to 15 on Aurora; add one at a time
 │ each one adds ~$350/mo read capacity
 ▼
③ Connection pooling → RDS Proxy already in place
 │ handles connection spikes without DB changes
 ▼
④ Aurora Serverless v2 → auto-scales compute; cheaper when idle
 │ ~$150–200/mo idle; bursts for DR activation
 ▼
⑤ RANGE partition → split service_appointment by sched_start_time
 │ e.g. monthly partitions; hot data stays small
 ▼
⑥ Archive old partitions → detach + archive closed/past appointments
 │ keeps working set small
 ▼
⑦ Different architecture → only if >5M records AND >50:1 reads AND
 500+ sustained write TPS all at once
 (we are orders of magnitude away from this)
```

**Extensions**: `pgcrypto` (UUID), `postgis` (proximity), `btree_gist` (overlap exclusion)

---

## 3. AWS PostgreSQL Flavors — Which One and Why

AWS offers three ways to run PostgreSQL. They all run the same PostgreSQL engine (same SQL, same extensions, same `btree_gist`), but differ in how they handle storage, failover, scaling, and pricing.

### 3.1 The Three Flavors

```
┌──────────────────────────────────────────────────────────────────────┐
│ │
│ RDS PostgreSQL Aurora PostgreSQL Aurora Serverless v2│
│ (Standard) (Provisioned) (Auto-scaling) │
│ │
│ Traditional DB Re-architected Aurora engine + │
│ on EBS volumes storage layer elastic compute │
│ │
│ Manual failover Auto failover Auto failover + │
│ or Multi-AZ standby < 30 seconds auto scale up/down│
│ │
│ 2 copies (primary 6 copies across 6 copies across │
│ + standby in Multi-AZ) 3 AZs 3 AZs │
│ │
│ You manage storage Storage auto-grows Storage auto-grows│
│ size (EBS gp3/io1) to 128 TB to 128 TB │
│ │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.2 Feature Comparison Against Our Requirements

| Requirement | RDS PostgreSQL | Aurora Provisioned | Aurora Serverless v2 |
|---|---|---|---|
| **Failover speed** (RTO target < 15 min) | 60-120 seconds (DNS propagation + EBS mount) | **< 30 seconds** (shared storage, no remount) | **< 30 seconds** (same Aurora storage) |
| **Replication durability** (zero data loss) | 2 copies (primary + standby) across 2 AZs | **6 copies across 3 AZs** — survives loss of entire AZ with zero data loss | Same as Aurora Provisioned |
| **Read replicas** (availability offload) | Up to 5, with replication lag | **Up to 15**, minimal lag (shared storage) | Up to 15 |
| **Storage management** | Manual provisioning (EBS volume type/size) | **Auto-grows** to 128 TB, no capacity planning | Auto-grows |
| **btree_gist / EXCLUDE constraint** | Yes (same PG engine) | Yes (same PG engine) | Yes (same PG engine) |
| **PostGIS** | Yes | Yes | Yes |
| **JSONB** | Yes | Yes | Yes |
| **Point-in-time recovery** | Up to 35 days | Up to 35 days | Up to 35 days |
| **Automatic backups** | Yes | Yes (continuous, incremental) | Yes |
| **Connection pooling** | Need external PgBouncer | **RDS Proxy** built-in | RDS Proxy built-in |
| **Cost optimization for idle DR** | Pay for full instance 24/7 | Pay for full instance 24/7 | **Scales to 0.5 ACU when idle** — pay only for what you use |
| **Spring Data JPA compatibility** | Full | Full | Full |

### 3.3 Cost Comparison (Our Workload: 200 MB, ~5,000 writes/day)

| Component | RDS PostgreSQL | Aurora Provisioned | Aurora Serverless v2 |
|---|---|---|---|
| Writer instance | ~$400/mo (db.r6g.large, Multi-AZ) | ~$500/mo (db.r6g.large) | ~$200-500/mo (scales 0.5-8 ACU based on load) |
| Reader instance | ~$200/mo | ~$350/mo | ~$100-350/mo (auto-scales) |
| Storage | ~$30/mo (20 GB gp3) | ~$30/mo (I/O Optimized) | ~$30/mo |
| Backup | ~$10/mo | ~$20/mo | ~$20/mo |
| **Total (active DR)** | **~$640/mo** | **~$900/mo** | **~$350-900/mo** |
| **Total (idle/standby)** | **~$640/mo** (same — instance runs 24/7) | **~$900/mo** (same) | **~$150-200/mo** (scales down when idle) |

### 3.4 Why Aurora (Either Flavor) Beats Standard RDS

*These factors apply to both Aurora Provisioned and Aurora Serverless v2 — the choice between those two is a cost/usage-pattern decision covered in §3.8.*

| Factor | Why It Matters for DR |
|---|---|
| **30-second failover vs 60-120 seconds** | DR is activated during an outage. Every second counts. Aurora's shared-storage architecture eliminates the EBS remount step that slows RDS failover |
| **6 copies across 3 AZs vs 2 copies** | Standard RDS can lose data if both the primary and standby AZ fail simultaneously. Aurora survives losing 2 of 6 copies for reads, 3 of 6 for writes — far more resilient |
| **15 read replicas vs 5** | Availability queries are read-heavy (10:1). More replica headroom means less risk of reader saturation during a DR event when all traffic redirects here |
| **No storage management** | During an outage, you don't want to deal with EBS volume full alerts or manual resize. Aurora storage just grows |
| **RDS Proxy** | Built-in connection pooling. No external PgBouncer to deploy and manage |

### 3.5 When Aurora Serverless v2 Is Worth Considering

Aurora Serverless v2 uses the same Aurora storage engine but auto-scales compute (measured in ACUs — Aurora Capacity Units). It's worth considering because:

- **DR is idle most of the time.** The database sits there receiving sync data but handling no API traffic. Serverless v2 scales down to 0.5 ACU (~$0.06/instance-hr, at ~$0.12/ACU-hr) during idle — saving ~$700/month vs a provisioned instance running 24/7
- **When DR activates, it scales up.** Burst to 8+ ACUs within seconds to handle the redirected traffic
- **Same Aurora storage, same failover, same extensions.** No feature compromise

| Scenario | Serverless v2 Cost | Provisioned Cost |
|---|---|---|
| Idle standby — compute only (95% of the time) | ~$90/mo | ~$900/mo |
| Active DR burst (5% of the time, 1-2 days/month) | ~$60-100/mo | Already paid |
| **Blended monthly** | **~$150-200/mo** | **~$900/mo** |

*The ~$90 idle row is **compute only** (two 0.5-ACU floors ≈ $44 each). Adding storage (~$30) and backup (~$20) brings the blended idle total to the ~$150–200/mo used elsewhere in this doc.*

**Trade-off**: cold-start latency when scaling from minimum. First few requests after activation may see 1-2 seconds of added latency while compute scales. Acceptable if DR activation is a manual process with a few minutes of warm-up built in.

### 3.6 When Standard RDS PostgreSQL Makes Sense

- Budget-constrained environments where the lower instance cost (~$640 vs ~$900) matters more than failover speed
- Non-DR workloads where 60-120 second failover is acceptable
- Teams that already have deep RDS operational experience and don't want to learn Aurora-specific behaviors

For a DR system where fast failover and durability are the entire point, the RDS cost saving doesn't justify the capability trade-off.

### 3.7 Recommendation

| Priority | Choice | Reason |
|---|---|---|
| **Primary (Phase 1)** | **Aurora Serverless v2** | DR is idle ~95% of the time → ~$150–200/mo idle vs ~$900 fixed. Same engine, same <30s failover, same `btree_gist`. Accept the 1–2 s cold-start behind manual failover |
| **Switch target (if DR becomes full-time)** | **Aurora PostgreSQL Provisioned** (reserved) | Steady 24/7 load → fixed reservable instance is cheaper and has no cold-start. Instance-class change on the same cluster, not a migration |
| **Not recommended for this use case** | RDS PostgreSQL Standard | Slower failover, fewer replicas, manual storage — solves none of the problems DR cares about |

All three run the same PostgreSQL engine. The SQL schema, `btree_gist` constraint, JSONB, PostGIS, Spring Data JPA code — all identical across flavors. The choice is purely about infrastructure behavior, not application code.

### 3.8 Detailed Cost Breakdown & Flavor Selection

> **Assumptions:** us-east-1, on-demand pricing, ~200 MB data, baseline **1 writer + 1 reader**. Figures are **planning estimates — validate against the AWS Pricing Calculator** before finalizing. DR runs as a **standby**: idle ~95% of the time, active only during an outage or a drill.

#### Itemized monthly cost (baseline: 1 writer + 1 reader)

| Component | RDS PostgreSQL | Aurora Provisioned | Aurora Serverless v2 |
|---|---|---|---|
| Writer | ~$400 (Multi-AZ) | ~$500 (r6g.large) | ~$44 idle (0.5 ACU) → ~$350 at load |
| Reader (1) | ~$200 | ~$350 | ~$44 idle → ~$175 at load |
| Storage (~10 GB, auto-grows) | ~$30 | ~$30 | ~$30 |
| Backup / PITR | ~$10 | ~$20 | ~$20 |
| RDS Proxy | built-in / minimal | built-in / minimal | built-in / minimal |
| **Total — running at load** | **~$640** | **~$900** | **~$575** |
| **Total — idle standby** | **~$640** (fixed 24/7) | **~$900** (fixed 24/7) | **~$150–200** |

RDS and Provisioned bill the **same whether busy or idle** — the instances run 24/7. Serverless v2 bills per **ACU-hour** (~$0.12/ACU-hr), so an idle DR falls to the 0.5-ACU floor (~$44/instance/mo).

#### Provisioned vs Serverless — the decision is about *usage pattern*

| Usage pattern | Aurora Provisioned | Aurora Serverless v2 | Cheaper |
|---|---|---|---|
| **Idle standby** (today — idle ~95%) | ~$900/mo fixed | ~$150–200/mo | **Serverless (~5–6×)** |
| **Occasional activation** (a few drills/outages a month) | ~$900/mo fixed | ~$200–300/mo | Serverless |
| **Full-time, always at load** (2-yr scenario) | ~$900/mo, **reservable to ~$500–600** | ~$700–900+/mo, not reservable | **Provisioned** |

**Why it flips:** Serverless wins when idle because it scales to a 0.5-ACU floor. But a full-time system runs hot 24/7, so its ACU-hours accumulate to roughly a provisioned instance's cost — *and* Provisioned can layer **Reserved Instances / Savings Plans (~40–50% off)** for steady load, which Serverless can't. So the cheapest choice depends entirely on whether it's a standby or an always-on system.

#### The 2-year "what if DR becomes full-time?" answer

- **Today (standby):** pick **Serverless v2** — idle savings dominate.
- **If it goes full-time:** switch to **Provisioned** (reserved) — predictable, cheaper at steady load, no cold-start.

**The reassurance — switching is nearly free.** Almost nothing else changes between the two:

- Same Aurora engine, same storage, same 6-copy / 3-AZ durability, same <30s failover, same extensions (`btree_gist`, PostGIS), same SQL, **same application code**.
- Moving Serverless v2 ⇄ Provisioned is an **instance-class change on the same cluster** — minutes of failover, **no data migration, no schema change, no code change**.
- The only real differences are **infrastructure / billing behavior**, not features: Serverless auto-scales compute (per-ACU billing, possible 1–2s cold-start on wake); Provisioned is a fixed, reservable instance with no cold-start.

**So we are not locked in.** Start on Serverless v2 for a cheap standby; if DR is promoted to full-time, flip to Provisioned with a config change. The decision is reversible and low-risk.

#### Recommendation

| Horizon | Pick | Why |
|---|---|---|
| **Phase 1 — DR standby (now → ~2 yrs)** | **Aurora Serverless v2** | DR is idle ~95% of the time → ~$150–200/mo idle vs ~$900 provisioned fixed. Same engine, same failover, same everything. |
| **If promoted to full-time (~2 yr scenario)** | **Aurora Provisioned** (reserved) | Steady 24/7 load → fixed reservable instance cheaper + no cold-start |
| **Not recommended** | RDS PostgreSQL | Slower failover, fewer replicas, manual storage — wrong for DR |

**Why Serverless v2 is the clear Phase 1 pick:** DR is a standby that sleeps until a Salesforce outage. Paying ~$900/mo for a fixed instance that sits idle 95% of the time is wasteful. Serverless v2 scales down to 0.5 ACU (~$0.06/hr) when idle and bursts up in seconds when activated. You get identical correctness guarantees, identical failover (<30s), identical extensions — for roughly **5–6× less cost** during standby.

**The cold-start trade-off:** when Serverless scales up from idle, the first few requests may see 1–2 seconds of added latency while compute spins up. For a **manual failover** (someone clicks "activate DR"), this is fine — build a brief warm-up step into the runbook. If failover ever becomes automated, re-evaluate Provisioned at that point.

**Switching later is a config change, not a migration:** Serverless v2 ⇄ Provisioned is an instance-class swap on the same cluster. No data migration, no schema change, no code change. Start cheap, switch when the usage pattern justifies it.

---

## 4. Locked Decision Alignment

| Locked Decision | How PG-Only Handles It |
|---|---|
| 1. Dual identity (UUID + sf_id) | Native columns — `id UUID PK`, `sf_id CHAR(18) UNIQUE` |
| 2. Customer is flat and request-fed | Simple `customer` table with customer_id, type, name, email, phone |
| 3. No Account/Lead polymorphic parent | No account/lead tables needed; customer_id is the only reference |
| 4. Customer → many appointments via customerId/MID | FK from `service_appointment.customer_ref_id` to `customer.id`; business key match on `customer.customer_id` |
| 5. User/Advisor separation | `app_user` (corp_id, name, email) + `service_resource` (advisor attrs, FK to app_user) |
| 6. No volatile profile metadata | Not stored; columns don't exist |
| 7. Failback = batch delta job | `SELECT * FROM service_appointment WHERE sf_id IS NULL` + outbox table tracks publish state |
| 8. Duration from work_type | `work_type.duration_minutes` joined at read time |
| 9. Skills gated off for Wealth (runtime skill-agnostic) | `skill` / `service_resource_skill` / `work_type_required_skill` are modeled now but gated off via `appointment_scheduling_policy.enforce_skills = FALSE`; WEPA (Phase 2) turns them on — nothing to retrofit |
| 10. Territory grouping is first-class | `service_territory_group` → `service_territory` hierarchy with hours, caps, timezone |
| 11. Shared model for Wealth + WPA | One schema, one set of APIs |

---

## 5. Pros

### 5.1 Correctness — The Deciding Advantage

**Only PG can guarantee no double-booking at the storage layer.**

Double-booking is a time-range overlap problem. Two bookings `10:00–11:00` and `10:30–11:30` are different values but still collide. PG handles this declaratively:

```sql
CREATE EXTENSION btree_gist;

ALTER TABLE assigned_resource
ADD CONSTRAINT no_double_book
EXCLUDE USING gist (
 service_resource_id WITH =,
 tstzrange(sched_start_time, block_end_time) WITH &&
) WHERE (status <> 'Canceled' AND allow_overlap = FALSE);
```

Two details in that constraint:
- **`block_end_time`, not `sched_end_time`** — the range covers the *block* the advisor's calendar reserves, which is `sched_end_time + work_type.buffer_minutes`. `block_end_time` is a **stored column** on `assigned_resource` (set at booking) because `timestamptz + interval` is only `STABLE` in PostgreSQL and can't appear in a GiST/EXCLUDE expression. `sched_end_time` stays the customer-facing meeting end; when buffer is 0 the two are equal.
- **`allow_overlap = FALSE`** — `allow_overlap` is a column on `assigned_resource`, default FALSE. Phase 1 Wealth is strict (always FALSE, no override). The WEPA (Phase 2) super-scheduler can set it TRUE to intentionally permit an overlap; such a row drops out of the partial index entirely, so the flag is gated behind `appointment_scheduling_policy.allow_overlap_override` and never set on a Wealth row.

This fires on every write path — API create, reschedule, sync import, bulk load — with zero application code. O(log n) at 200K rows = ~18 comparisons, sub-millisecond.

No document store has an equivalent construct. Application-level checks race under concurrency and get bypassed by non-API write paths (sync, migration).

### 5.2 Atomicity — One Transaction for Everything

A single appointment create touches 6 tables (appointment, assigned_resource, attendees, notes, notification, outbox). In PG this is one `BEGIN ... COMMIT`. Either all 6 succeed or none do. No partial state, no saga compensation, no retry logic.

### 5.3 Availability Queries Are Native JOINs

Availability calculation pulls shifts + the advisor's primary/secondary territory + existing appointments + operating hours + work type duration. In PG this is one SQL query with indexed joins. No app-side stitching across stores.

### 5.4 Failback Is a Simple Query

```sql
SELECT sa.*, c.customer_id, c.first_name, c.last_name
FROM service_appointment sa
JOIN customer c ON c.id = sa.customer_ref_id
WHERE sa.sf_id IS NULL;
```

One query extracts the delta. Direct column mapping to SF upsert payload. No document flattening or cross-engine reconciliation.

### 5.5 Operational Simplicity

| Dimension | Value |
|---|---|
| DB engines to operate | 1 |
| Connection strings | 2 (writer + reader) |
| Failover procedures | 1 |
| Monitoring dashboards | 1 |
| Schema migration tool | Flyway only |
| Data access layer | Spring Data JPA only |
| Backup strategy | 1 (Aurora continuous) |

During an outage — which is when DR is active — fewer moving parts means fewer things to debug.

### 5.6 Document Flexibility Via JSONB

PG is multi-model. Semi-structured or evolving payloads (notification request/response, integration metadata) use `JSONB` columns with GIN indexes. You get document flexibility without leaving the relational engine.

### 5.7 Cost

| Component | Monthly |
|---|---|
| Writer (db.r6g.large, Multi-AZ) | ~$500 |
| Reader (1 instance) | ~$350 |
| Storage + backup | ~$50 |
| **Total** | **~$900** |

No license fees. PostgreSQL is open-source.

### 5.8 Scaling Ladder (Before You'd Ever Need Another Engine)

1. Vertical resize (minutes)
2. Up to 15 read replicas
3. Connection pooling (RDS Proxy)
4. Serverless v2 autoscaling
5. RANGE partitioning by `sched_start_time`
6. Aurora storage autoscales to 128 TB

At 200 MB and a few TPS, we are orders of magnitude below needing step 2.

### 5.9 Team Fit

Team is SQL-native. Spring Data JPA, Flyway, pgAdmin, DataGrip — all known. No learning curve delay.

### 5.10 Aurora Durability

6 copies of data across 3 AZs. Writer failover in < 30 seconds. Continuous backup with point-in-time recovery up to 35 days.

---

## 6. Cons

| # | Disadvantage | Severity | Mitigation |
|---|---|---|---|
| 1 | Schema changes require DDL migrations | Low | Flyway handles this; team already practices versioned migrations |
| 2 | Full appointment GET requires JOINs across 6-8 tables | Low | Pre-built `v_appointment_full` view; at 200 MB the working set is in memory, JOINs return in < 10 ms |
| 3 | ENUM changes need ALTER TYPE | Low | Plan picklist values conservatively; use TEXT fallback for volatile fields |
| 4 | Single writer instance | Low | At a few TPS this is not a bottleneck; Aurora autoscaling writer available if needed |
| 5 | No native horizontal sharding | Low | Not needed at our scale; vertical + replicas + partitioning cover the growth path |
| 6 | Schema is rigid compared to schemaless stores | Low | JSONB columns provide flexibility where needed; core appointment structure is stable |
| 7 | Read latency is slightly higher than a document store for single-record fetch | Negligible | ~5 ms vs ~3 ms; both invisible to users when Graph API adds ~2 seconds |

---

## 7. Performance

### 7.1 Reads

| Query | P95 Latency |
|---|---|
| Get appointment by ID | < 5 ms |
| Search appointments (paginated) | < 50 ms |
| Get availability (DB portion) | < 200 ms |
| Branch availability | < 20 ms |

### 7.2 Writes

| Operation | P95 Latency |
|---|---|
| Create appointment (full 6-table transaction) | < 50 ms |
| Cancel | < 10 ms |
| Reschedule | < 30 ms |
| Bulk sync (1,000 rows) | < 2 seconds |

### 7.3 Throughput

| Metric | Capacity |
|---|---|
| Write TPS (peak) | ~500 |
| Read TPS (with replica) | ~5,000 |
| Concurrent connections | 200 (pooled) |

---

## 8. Recovery

| Metric | Target | Expected |
|---|---|---|
| RPO | < 5 min | < 3 min (DEP real-time + Aurora WAL) |
| RTO | < 15 min | ~12 min (detect + switch routing + verify) |
| Writer failover | automatic | < 30 seconds |
| Data loss on AZ failure | zero | 6-copy synchronous replication |

---

## 9. Technology Stack

```
Spring Boot App
 ├── Spring Data JPA / Hibernate → Entity classes
 ├── HikariCP → Writer + Reader pools
 ├── Flyway → Versioned migrations
 └── @Transactional → Atomic appointment ops
```

---

## 10. Verdict

Option A is the recommended choice. It is the only option that can enforce the core business invariant (no overlapping advisor bookings) at the storage layer. It satisfies all locked decisions natively, keeps operations simple during outages, and has no scale limitation at our current or projected workload.

**Required before go-live**: enable `btree_gist` extension and add the exclusion constraint on `assigned_resource`.
