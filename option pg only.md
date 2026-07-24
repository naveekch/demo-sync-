# Option A — PostgreSQL Only (Aurora PostgreSQL) — WEDAS-1081

> Story: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> Subtask: WEDAS-1081 — Document Option A  
> Updated: 2026-07-23  
> Authors: Naveen Chelluboina, team

---

## 1. Overview

Single Aurora PostgreSQL database holds everything: config, resources, appointments, audit, and integration state. One engine, one transaction boundary, one operational surface.

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    DAP DR App (Spring Boot)               │
│                                                          │
│  ┌──────────────────────────────────────────────────┐   │
│  │       Spring Data JPA / Hibernate                 │   │
│  │   Writer endpoint (writes) │ Reader endpoint (reads)│  │
│  └────────────────────┬───────┴──────────────────────┘  │
│                       │                                  │
│                       ▼                                  │
│  ┌──────────────────────────────────────────────────┐   │
│  │              Aurora PostgreSQL 15+                 │   │
│  │                                                    │   │
│  │   Writer (AZ-a) ──sync──▶ Reader (AZ-b)          │   │
│  │          │                      │                  │   │
│  │          ▼                      ▼                  │   │
│  │   ┌──────────────────────────────────┐            │   │
│  │   │   Shared Storage (6 copies / 3 AZs)│          │   │
│  │   └──────────────────────────────────┘            │   │
│  └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

**Extensions**: `pgcrypto` (UUID), `postgis` (proximity), `btree_gist` (overlap exclusion)

---

## 3. AWS PostgreSQL Flavors — Which One and Why

AWS offers three ways to run PostgreSQL. They all run the same PostgreSQL engine (same SQL, same extensions, same `btree_gist`), but differ in how they handle storage, failover, scaling, and pricing.

### 3.1 The Three Flavors

```
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│   RDS PostgreSQL          Aurora PostgreSQL       Aurora Serverless v2│
│   (Standard)              (Provisioned)           (Auto-scaling)     │
│                                                                      │
│   Traditional DB          Re-architected          Aurora engine +    │
│   on EBS volumes          storage layer           elastic compute    │
│                                                                      │
│   Manual failover         Auto failover           Auto failover +   │
│   or Multi-AZ standby     < 30 seconds            auto scale up/down│
│                                                                      │
│   2 copies (primary       6 copies across         6 copies across   │
│   + standby in Multi-AZ)  3 AZs                   3 AZs             │
│                                                                      │
│   You manage storage      Storage auto-grows      Storage auto-grows│
│   size (EBS gp3/io1)      to 128 TB               to 128 TB         │
│                                                                      │
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

### 3.4 Why Aurora Provisioned Is the Primary Recommendation

| Factor | Why It Matters for DR |
|---|---|
| **30-second failover vs 60-120 seconds** | DR is activated during an outage. Every second counts. Aurora's shared-storage architecture eliminates the EBS remount step that slows RDS failover |
| **6 copies across 3 AZs vs 2 copies** | Standard RDS can lose data if both the primary and standby AZ fail simultaneously. Aurora survives losing 2 of 6 copies for reads, 3 of 6 for writes — far more resilient |
| **15 read replicas vs 5** | Availability queries are read-heavy (10:1). More replica headroom means less risk of reader saturation during a DR event when all traffic redirects here |
| **No storage management** | During an outage, you don't want to deal with EBS volume full alerts or manual resize. Aurora storage just grows |
| **RDS Proxy** | Built-in connection pooling. No external PgBouncer to deploy and manage |

### 3.5 When Aurora Serverless v2 Is Worth Considering

Aurora Serverless v2 uses the same Aurora storage engine but auto-scales compute (measured in ACUs — Aurora Capacity Units). It's worth considering because:

- **DR is idle most of the time.** The database sits there receiving sync data but handling no API traffic. Serverless v2 scales down to 0.5 ACU (~$0.12/hour) during idle — saving ~$700/month vs a provisioned instance running 24/7
- **When DR activates, it scales up.** Burst to 8+ ACUs within seconds to handle the redirected traffic
- **Same Aurora storage, same failover, same extensions.** No feature compromise

| Scenario | Serverless v2 Cost | Provisioned Cost |
|---|---|---|
| Idle standby (95% of the time) | ~$90/mo | ~$900/mo |
| Active DR burst (5% of the time, 1-2 days/month) | ~$60-100/mo | Already paid |
| **Blended monthly** | **~$150-200/mo** | **~$900/mo** |

**Trade-off**: cold-start latency when scaling from minimum. First few requests after activation may see 1-2 seconds of added latency while compute scales. Acceptable if DR activation is a manual process with a few minutes of warm-up built in.

### 3.6 When Standard RDS PostgreSQL Makes Sense

- Budget-constrained environments where the lower instance cost (~$640 vs ~$900) matters more than failover speed
- Non-DR workloads where 60-120 second failover is acceptable
- Teams that already have deep RDS operational experience and don't want to learn Aurora-specific behaviors

For a DR system where fast failover and durability are the entire point, the RDS cost saving doesn't justify the capability trade-off.

### 3.7 Recommendation

| Priority | Choice | Reason |
|---|---|---|
| **Primary** | **Aurora PostgreSQL Provisioned** | Fastest failover, most durable, simplest storage, proven at scale. Use db.r6g.large for writer + 1 reader |
| **Cost-optimized alternative** | **Aurora Serverless v2** | Same engine, same guarantees, but dramatically cheaper when DR is idle. Evaluate if the 1-2 second cold-start on activation is acceptable |
| **Not recommended for this use case** | RDS PostgreSQL Standard | Slower failover, fewer replicas, manual storage — solves none of the problems DR cares about |

All three run the same PostgreSQL engine. The SQL schema, `btree_gist` constraint, JSONB, PostGIS, Spring Data JPA code — all identical across flavors. The choice is purely about infrastructure behavior, not application code.

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
| 9. Skills out of scope | No skill tables needed for Phase 1 |
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
    tstzrange(sched_start_time, sched_end_time) WITH &&
) WHERE (status <> 'Canceled');
```

This fires on every write path — API create, reschedule, sync import, bulk load — with zero application code. O(log n) at 200K rows = ~18 comparisons, sub-millisecond.

No document store has an equivalent construct. Application-level checks race under concurrency and get bypassed by non-API write paths (sync, migration).

### 5.2 Atomicity — One Transaction for Everything

A single appointment create touches 6 tables (appointment, assigned_resource, attendees, notes, notification, outbox). In PG this is one `BEGIN ... COMMIT`. Either all 6 succeed or none do. No partial state, no saga compensation, no retry logic.

### 5.3 Availability Queries Are Native JOINs

Availability calculation pulls shifts + territory members + existing appointments + operating hours + work type duration. In PG this is one SQL query with indexed joins. No app-side stitching across stores.

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
    ├── Spring Data JPA / Hibernate  →  Entity classes
    ├── HikariCP                     →  Writer + Reader pools
    ├── Flyway                       →  Versioned migrations
    └── @Transactional               →  Atomic appointment ops
```

---

## 10. Verdict

Option A is the recommended choice. It is the only option that can enforce the core business invariant (no overlapping advisor bookings) at the storage layer. It satisfies all locked decisions natively, keeps operations simple during outages, and has no scale limitation at our current or projected workload.

**Required before go-live**: enable `btree_gist` extension and add the exclusion constraint on `assigned_resource`.
