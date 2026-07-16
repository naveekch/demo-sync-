# Option A — Single RDBMS (Aurora PostgreSQL) — WEDAS-1081

> **Story**: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> **Subtask**: WEDAS-1081 — Document Option A - Single RDBMS  
> **Date**: 2026-07-16  
> **Authors**: Naveen Chelluboina, team

---

## 1. Overview

Option A proposes a **single Aurora PostgreSQL** database as the DR data store. All configuration, resource, appointment, and audit data lives in one relational database with full ACID guarantees.

---

## 2. Schema Design

### 2.1 Database Engine
- **Engine**: Amazon Aurora PostgreSQL 15+ (compatible with RDS PostgreSQL 15+)
- **Extensions**: `pgcrypto` (UUID generation), `postgis` (geolocation for proximity searches)
- **Instance Class**: db.r6g.large (multi-AZ for DR)

### 2.2 Schema Structure (12 Sections)

Refer to [`aurora_scheduler_schema.sql`](../../aurora_scheduler_schema.sql) for full DDL. Summary:

| Section | Tables | Purpose |
|---------|--------|---------|
| 1. Reference/Config | operating_hours, service_territory, time_slot, engagement_channel_type, work_type, work_type_group, delivery_platform, registration_platform, registration_delivery_mapping, master_data_catalog, scheduler_config, scheduler_global | Static/slow-change config |
| 2. People/Resources | sf_user, account (partial), lead (partial), service_resource, skill, service_resource_skill, service_territory_member, shift, resource_alignment | Advisor and territory data |
| 3. Appointment Core | event_request, service_appointment, assigned_resource, service_appointment_attendee, appointment_note | Transactional appointment data |
| 4. 1:Many/Workshop | event_audience, event_participant, event_additional_attendee | Out of Phase 1 scope but schema-ready |
| 5. Notification/Integration | notification_record, publishing_event_record, external_event_record, edl_event_record, service_appointment_event_outbox | DR audit trail |
| 6. Constraints | max_appointment_per_day_constraint, max_appointment_constraint_member | Appointment capacity limits |
| 7. Optimization | resource_optimization_output | Analytics (optional) |
| 8. Operational/Audit | appointment_action_failure, service_territory_member_history, scheduler_log, scheduled_job_run_tracker, participant_bin, crt_settings | Error tracking, audit |
| 9. Indexes | 15+ indexes | Query performance |
| 10. Triggers | updated_at auto-maintenance, participant count | Data integrity |
| 11. Views | v_appointment_full, v_advisor_schedule | Common read patterns |

### 2.3 Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| UUID primary keys | Avoids collision with SF 18-char IDs; `sf_id CHAR(18)` stored separately for sync |
| PostgreSQL ENUMs | Mirror SF picklists; type safety at DB level |
| PostGIS GEOGRAPHY | Required for WEPA proximity availability (ST_Distance) |
| JSONB for payloads | Notification/publishing request/response stored as flexible JSON |
| Outbox table pattern | Replaces SF Platform Events; poller publishes to SNS/EventBridge |
| Single-row scheduler_global | Mirrors SF hierarchy custom setting; enforced at app layer |

---

## 3. Replication Strategy

### 3.1 Aurora Multi-AZ Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Aurora Cluster                        │
│                                                      │
│  ┌──────────────┐    ┌──────────────┐               │
│  │ Writer (AZ-a)│───▶│ Reader (AZ-b)│  sync replic. │
│  └──────────────┘    └──────────────┘               │
│         │                    │                       │
│         ▼                    ▼                       │
│  ┌──────────────────────────────────┐               │
│  │     Shared Storage (6 copies)    │               │
│  │     across 3 AZs                 │               │
│  └──────────────────────────────────┘               │
└─────────────────────────────────────────────────────┘
```

- **Replication**: Synchronous within cluster (6 storage copies across 3 AZs)
- **Failover**: Automatic writer failover in < 30 seconds
- **Read replicas**: 1-2 readers for availability queries (read-heavy workload)

### 3.2 Cross-Region (Optional Future)
- Aurora Global Database for cross-region DR (< 1 second replication lag)
- Not required for Phase 1 (same-region Multi-AZ is sufficient)

---

## 4. RPO / RTO Estimates

| Metric | Value | Justification |
|--------|-------|---------------|
| **RPO** (Recovery Point Objective) | **< 5 minutes** | DEP real-time sync; config sync hourly; Aurora continuous backup |
| **RTO** (Recovery Time Objective) | **< 15 minutes** | Manual failover switch in DAP Core API routing config; Aurora writer failover < 30s |
| **Data Loss Window** | Near-zero for appointments (DEP); up to 1 hour for config | Config delta applied on failover activation |

---

## 5. Performance Characteristics

### 5.1 Read Performance

| Query Pattern | Expected Latency | Optimization |
|--------------|------------------|--------------|
| Get Appointment by ID | < 5 ms | Primary key lookup |
| Search Appointments (paginated) | < 50 ms | Composite indexes on status + time + territory |
| Get Availability (compute) | < 200 ms | Indexed shifts + territory members; Graph API dominates |
| Branch Availability | < 20 ms | time_slot table scan with OH filter |

### 5.2 Write Performance

| Operation | Expected Latency | Notes |
|-----------|------------------|-------|
| Create Appointment (full) | < 50 ms | Insert SA + AR + attendees in transaction |
| Cancel Appointment | < 10 ms | Single UPDATE |
| Reschedule | < 30 ms | UPDATE SA + INSERT note |
| Bulk sync (1000 records) | < 2 seconds | Batch INSERT with ON CONFLICT |

### 5.3 Throughput

| Metric | Capacity | Based On |
|--------|----------|----------|
| Peak writes | ~500 TPS | db.r6g.large; appointment creation burst |
| Peak reads | ~5,000 TPS | Read replicas for availability |
| Concurrent connections | 200 | Connection pooling via PgBouncer |

---

## 6. Licensing & Cost

| Component | Monthly Cost (Estimate) | Notes |
|-----------|------------------------|-------|
| Aurora PostgreSQL db.r6g.large (writer) | ~$500 | Multi-AZ |
| Aurora Reader (1 instance) | ~$350 | Availability queries |
| Storage (200 MB + growth) | ~$30 | Aurora I/O-Optimized |
| Backup/Snapshots | ~$20 | Continuous + daily |
| **Total** | **~$900/month** | Production DR cluster |

- **No license fees** — PostgreSQL is open-source
- **Aurora pricing** is compute + I/O based (no per-seat licensing)

---

## 7. Advantages

| # | Advantage |
|---|-----------|
| 1 | **ACID transactions** — appointment creation with attendees + assigned resources is atomic |
| 2 | **Strong consistency** — no eventual consistency issues for double-booking prevention |
| 3 | **Single query language** — all operations use standard SQL |
| 4 | **Referential integrity** — FK constraints prevent orphaned records |
| 5 | **Mature tooling** — pgAdmin, DataGrip, Flyway migrations, Spring Data JPA |
| 6 | **PostGIS support** — native geospatial queries for proximity availability |
| 7 | **Low operational complexity** — one database to monitor, backup, failover |
| 8 | **Schema mirrors SF** — 1:1 mapping simplifies sync logic |
| 9 | **Aurora storage auto-scales** — no capacity planning for disk |
| 10 | **Existing schema ready** — `aurora_scheduler_schema.sql` already validated |

---

## 8. Disadvantages / Risks

| # | Risk | Mitigation |
|---|------|------------|
| 1 | Schema migrations require DDL changes | Use Flyway; version all migrations |
| 2 | Large JOIN queries for full appointment view | Pre-built `v_appointment_full` view; materialized view option |
| 3 | ENUM changes require ALTER TYPE | Plan picklist values conservatively; add `TEXT` fallback columns |
| 4 | Single writer bottleneck under extreme load | Aurora auto-scaling writer; architect for read-replica offload |
| 5 | No native document flexibility | Use JSONB columns for semi-structured data (request/response payloads) |

---

## 9. Technology Stack Integration

```
DAP DR App (Spring Boot)
    │
    ├── Spring Data JPA / Hibernate
    │       └── Entity classes mapping to Aurora tables
    ├── HikariCP connection pool
    │       └── Writer endpoint (writes) + Reader endpoint (reads)
    ├── Flyway
    │       └── Schema versioning and migrations
    └── Spring @Transactional
            └── Atomic appointment creation
```

---

## 10. Proof of Concept Readiness

The existing `aurora_scheduler_schema.sql` provides:
- ✅ All 30+ tables with proper types, constraints, indexes
- ✅ ENUMs matching SF picklists
- ✅ PostGIS for proximity
- ✅ Outbox pattern for DEP publishing
- ✅ Audit triggers for updated_at
- ✅ Views for common read patterns
- ✅ Indexes tuned for known query patterns from Apex audit

**Verdict**: Option A is implementation-ready with minimal additional design.
