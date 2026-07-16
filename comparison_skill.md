# Comparison Matrix & Recommendation — WEDAS-1083

> **Story**: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> **Subtask**: WEDAS-1083 — Create Comparison Matrix and Recommendation  
> **Date**: 2026-07-16  
> **Authors**: Naveen Chelluboina, team

---

## 1. Scoring Criteria

Each criterion scored 1-5 (5 = best). Weight reflects importance to Phase 1 DR requirements.

---

## 2. Comparison Matrix

| # | Criterion | Weight | Option A (Aurora PG) | Option B (PG + DocumentDB) | Notes |
|---|-----------|--------|---------------------|---------------------------|-------|
| 1 | **Data Consistency** | 25% | ⭐⭐⭐⭐⭐ (5) | ⭐⭐⭐ (3) | A: ACID across all tables. B: No cross-DB transactions; race conditions for double-booking |
| 2 | **Operational Simplicity** | 20% | ⭐⭐⭐⭐⭐ (5) | ⭐⭐⭐ (3) | A: Single DB to monitor/backup/failover. B: Two systems, double the runbooks |
| 3 | **Read Performance** | 15% | ⭐⭐⭐⭐ (4) | ⭐⭐⭐⭐⭐ (5) | B: No JOINs for document fetch. A: Views + indexes still very fast for this scale |
| 4 | **Write Performance** | 10% | ⭐⭐⭐⭐ (4) | ⭐⭐⭐⭐⭐ (5) | B: Single doc write. A: Multi-table INSERT in transaction still < 50ms |
| 5 | **Schema Flexibility** | 10% | ⭐⭐⭐ (3) | ⭐⭐⭐⭐⭐ (5) | B: Schema-less documents evolve freely. A: ALTERs needed but manageable with Flyway |
| 6 | **Failback Simplicity** | 10% | ⭐⭐⭐⭐⭐ (5) | ⭐⭐⭐ (3) | A: Direct SQL export matches SF structure. B: Must flatten documents + join PG config |
| 7 | **Team Expertise** | 5% | ⭐⭐⭐⭐⭐ (5) | ⭐⭐⭐ (3) | Team is SQL-native; MongoDB patterns require ramp-up |
| 8 | **Cost** | 5% | ⭐⭐⭐⭐⭐ (5) | ⭐⭐⭐ (3) | A: ~$900/mo. B: ~$1,340/mo (+50%) |

---

## 3. Weighted Scores

| Criterion | Weight | Option A Score | Weighted A | Option B Score | Weighted B |
|-----------|--------|---------------|------------|----------------|------------|
| Data Consistency | 0.25 | 5 | 1.25 | 3 | 0.75 |
| Operational Simplicity | 0.20 | 5 | 1.00 | 3 | 0.60 |
| Read Performance | 0.15 | 4 | 0.60 | 5 | 0.75 |
| Write Performance | 0.10 | 4 | 0.40 | 5 | 0.50 |
| Schema Flexibility | 0.10 | 3 | 0.30 | 5 | 0.50 |
| Failback Simplicity | 0.10 | 5 | 0.50 | 3 | 0.30 |
| Team Expertise | 0.05 | 5 | 0.25 | 3 | 0.15 |
| Cost | 0.05 | 5 | 0.25 | 3 | 0.15 |
| **TOTAL** | **1.00** | | **4.55** | | **3.70** |

---

## 4. Decision Drivers

### 4.1 Why Consistency Matters Most (25% weight)

The #1 function of the DR system is **preventing double-bookings**. When an appointment is created:
- We must atomically check advisor availability AND insert the appointment
- With Option A, this is a single `INSERT ... WHERE NOT EXISTS (conflict subquery)` in one transaction
- With Option B, we must read PostgreSQL (shifts) AND write DocumentDB (appointment) — no atomicity between them

### 4.2 Why Operational Simplicity Matters (20% weight)

DR is activated during an **outage** — the worst time to debug complex distributed systems. Single-database simplicity means:
- One connection string to configure
- One backup to verify
- One failover to execute
- One monitoring dashboard to watch
- One team on-call instead of two specialty teams

### 4.3 Why Performance Difference is Negligible at Our Scale

- **200K active appointments** fits entirely in Aurora's buffer pool (~200 MB)
- A JOIN-based `v_appointment_full` view with proper indexes returns in < 10ms at this scale
- The performance advantage of DocumentDB only materializes at millions of documents or extreme concurrency
- Availability calculation is bottlenecked by **Microsoft Graph API** (external), not database queries

---

## 5. Trade-offs Documented

| Choosing Option A Means... | Accepting That... |
|---------------------------|-------------------|
| ACID consistency guaranteed | Schema changes require DDL migrations |
| Simpler operations | JOINs needed for full appointment reads |
| Lower cost | No horizontal auto-sharding |
| Faster failback | ENUM changes need careful planning |
| One codebase pattern (JPA) | Less "trendy" than document stores |

| Choosing Option B Means... | Accepting That... |
|---------------------------|-------------------|
| Fastest possible reads | Distributed transaction risk for writes |
| Flexible document evolution | Two systems to operate and monitor |
| Future horizontal scale | Higher cost and team ramp-up |
| Natural API-response shape | Failback requires document flattening + reconciliation |

---

## 6. Recommendation

### **✅ RECOMMENDED: Option A — Single Aurora PostgreSQL**

**Rationale**:
1. **Consistency wins for DR** — The entire purpose of the DR system is to reliably accept appointments without errors. ACID transactions prevent double-bookings without complex distributed coordination.
2. **Simplicity wins for incidents** — DR is activated during emergencies. Fewer moving parts = fewer failure modes.
3. **Performance is sufficient** — At ~200K records and expected ~500 TPS peak, PostgreSQL with proper indexes easily meets SLAs (< 50ms for all operations).
4. **Schema already exists** — `aurora_scheduler_schema.sql` is implementation-ready, validated against the SF codebase, with indexes tuned for known query patterns.
5. **Failback is straightforward** — SQL export maps directly to SF object structure; no document-to-relational translation needed.
6. **Cost is lower** — ~$440/month savings with simpler architecture.
7. **Team velocity** — SQL/JPA is the team's native language; no MongoDB learning curve delays delivery.

### When to Revisit

Reconsider Option B if:
- Appointment volume exceeds 5M active records
- Read traffic exceeds 50,000 TPS sustained
- API response shape changes frequently and unpredictably
- Multiple teams need independent schema evolution

---

## 7. Sign-Off

| Role | Name | Date | Approved |
|------|------|------|----------|
| Tech Lead | | | ☐ |
| Architect | | | ☐ |
| Product Owner | | | ☐ |
| DBA | | | ☐ |
