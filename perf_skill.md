# Retention & Performance Requirements — WEDAS-1084

> **Story**: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> **Subtask**: WEDAS-1084 — Define Retention & Performance Requirements  
> **Date**: 2026-07-16  
> **Authors**: Naveen Chelluboina, team

---

## 1. Data Retention Requirements

### 1.1 Retention by Data Domain

| Data Domain | Retention Period | Rationale | Cleanup Strategy |
|-------------|-----------------|-----------|-----------------|
| **Active Appointments** (Scheduled, Rescheduled) | Until appointment date + 7 days | Must be queryable during and shortly after appointment | Archive after 7 days past |
| **Canceled Appointments** | 30 days post-cancellation | Needed for DEP reconciliation and audit | DELETE after 30 days |
| **DR-Created Appointments** | Until failback reconciliation + 30 days | Must survive failback process; audit trail | Archive after confirmed sync to SF |
| **Configuration Data** | Indefinite (latest version) | Always needed for availability computation | Overwrite on sync; no history |
| **Shifts** | Rolling 90-day window | Future shifts for availability; past shifts for conflict validation | DELETE shifts older than 90 days |
| **Service Resources** | Indefinite (active only) | Advisors referenced by appointments | Soft-delete (is_active = false) |
| **Notification Records** | 90 days | Troubleshooting notification failures | DELETE after 90 days |
| **DEP Publishing Records** | 90 days | Audit trail for event publishing | DELETE after 90 days |
| **Audit Logs (DR actions)** | 1 year | Compliance and incident investigation | Move to S3/cold storage after 1 year |
| **Appointment Action Failures** | Until resolved + 30 days | Retry queue; operational monitoring | DELETE resolved records after 30 days |

### 1.2 Storage Growth Projections

| Timeframe | Active Data Size | Archive Size | Total |
|-----------|-----------------|--------------|-------|
| Initial load | ~200 MB | 0 | ~200 MB |
| After 30 days DR active | ~250 MB | ~50 MB | ~300 MB |
| After 90 days DR active | ~300 MB | ~150 MB | ~450 MB |
| Steady-state (ongoing) | ~300 MB | Moved to S3 | ~300 MB active |

### 1.3 Backup Retention

| Backup Type | Retention | Frequency |
|-------------|-----------|-----------|
| Aurora automated backups | 35 days | Continuous |
| Manual snapshots (pre-failover) | 90 days | On DR activation |
| Point-in-time recovery | 35 days | Continuous (Aurora native) |
| Export to S3 (cold archive) | 1 year | Weekly |

---

## 2. Performance SLAs

### 2.1 Latency Requirements (P95)

| Operation | Target P95 Latency | Maximum Acceptable | Notes |
|-----------|-------------------|-------------------|-------|
| **Create Appointment** | < 100 ms (DB portion) | < 500 ms (incl. Graph API) | Graph API call dominates total time |
| **Get Appointment by ID** | < 20 ms | < 50 ms | Primary key lookup |
| **Search Appointments** | < 100 ms | < 200 ms | Paginated, indexed queries |
| **Cancel Appointment** | < 50 ms | < 100 ms | Single UPDATE |
| **Reschedule Appointment** | < 100 ms | < 300 ms | UPDATE + note INSERT |
| **Get Availability** | < 300 ms (DB portion) | < 2 seconds (total incl. Graph) | Microsoft Graph API is the bottleneck |
| **Branch Availability** | < 50 ms | < 100 ms | Config lookup only; no Graph |
| **Next Availability** | < 500 ms | < 3 seconds | May iterate multiple days |

### 2.2 Throughput Requirements

| Metric | Target | Peak (2x normal) | Burst (5x) |
|--------|--------|-------------------|------------|
| **Writes (appointments/sec)** | 50 TPS | 100 TPS | 250 TPS |
| **Reads (queries/sec)** | 500 TPS | 1,000 TPS | 2,500 TPS |
| **Availability checks/sec** | 200 TPS | 400 TPS | 1,000 TPS |
| **Concurrent connections** | 100 | 200 | 500 |

### 2.3 Availability (DR Database Itself)

| Metric | Target | Notes |
|--------|--------|-------|
| **Database uptime** | 99.99% | Aurora Multi-AZ SLA |
| **Writer failover time** | < 30 seconds | Aurora automatic failover |
| **Read replica lag** | < 100 ms | Aurora synchronous replication |
| **Backup success rate** | 100% | Monitored; alerts on failure |

---

## 3. Recovery Objectives

### 3.1 RPO (Recovery Point Objective)

| Data Type | RPO Target | Mechanism |
|-----------|-----------|-----------|
| **Appointments (DEP-synced)** | < 5 minutes | DEP real-time event consumption |
| **Appointments (DR-created)** | 0 (no data loss) | Committed to Aurora with WAL |
| **Configuration data** | < 1 hour | Hourly sync from SF |
| **Shifts** | < 1 hour | Hourly sync from SF |

### 3.2 RTO (Recovery Time Objective)

| Scenario | RTO Target | Steps |
|----------|-----------|-------|
| **DR Activation** (SF goes down) | < 15 minutes | 1. Detect SF outage (5 min)<br>2. Update routing config (2 min)<br>3. Verify DR DB health (3 min)<br>4. Validate last sync timestamp (3 min)<br>5. Traffic flows to DR |
| **DR Deactivation** (failback to SF) | < 2 hours | 1. Bulk export DR changes<br>2. Reconcile with SF<br>3. Suppress DEP/notifications<br>4. Upsert to SF<br>5. Verify<br>6. Switch routing back |
| **Aurora Writer Failure** | < 30 seconds | Automatic Multi-AZ failover |
| **Full Region Failure** | < 1 hour | Restore from snapshot in secondary region (future: Aurora Global DB) |

### 3.3 Acceptable Data Loss Window

| Scenario | Acceptable Loss |
|----------|----------------|
| Normal DR operation | 0 (all writes committed) |
| DR activation moment | Up to 5 min of SF changes (DEP lag) |
| Aurora writer crash | 0 (synchronous replication to 6 copies) |
| Entire AZ failure | 0 (Multi-AZ) |

---

## 4. Consistency Requirements

| Requirement | Level | Implementation |
|-------------|-------|---------------|
| **No double-booking** | Strong consistency (serializable) | `SELECT FOR UPDATE` on advisor time slot during create |
| **Appointment status transitions** | Strong consistency | Application-level state machine + DB constraint |
| **Config reads during availability** | Read-committed | Standard PostgreSQL isolation |
| **Notification delivery tracking** | Eventual consistency | Acceptable: notifications are best-effort |
| **DEP publishing** | At-least-once | Outbox pattern with deduplication at consumer |

---

## 5. Monitoring & Alerting Thresholds

### 5.1 Database Metrics

| Metric | Warning Threshold | Critical Threshold | Action |
|--------|-------------------|-------------------|--------|
| CPU utilization | > 70% for 5 min | > 90% for 2 min | Scale up / investigate queries |
| Free memory | < 2 GB | < 1 GB | Scale up instance |
| Connection count | > 150 | > 180 (of 200 max) | Check connection leaks |
| Replication lag | > 50 ms | > 500 ms | Investigate writer load |
| Disk queue depth | > 10 | > 50 | I/O bottleneck |
| Long-running queries | > 5 seconds | > 30 seconds | Kill + investigate |
| Failed transactions/min | > 5 | > 20 | Application error investigation |

### 5.2 Data Freshness Metrics

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| Last DEP sync timestamp | > 10 min stale | > 30 min stale | Check DEP subscription health |
| Last config sync timestamp | > 2 hours stale | > 6 hours stale | Check sync job |
| Last shift sync timestamp | > 2 hours stale | > 6 hours stale | Check sync job |

---

## 6. Capacity Planning

### 6.1 Instance Sizing

| Workload | Instance Class | vCPUs | RAM | Justification |
|----------|---------------|-------|-----|---------------|
| **Writer** | db.r6g.large | 2 | 16 GB | Handles all writes + availability computation |
| **Reader** | db.r6g.large | 2 | 16 GB | Offloads search queries + appointment GETs |
| **Burst scenario** | db.r6g.xlarge | 4 | 32 GB | Scale-up if DR active > 24 hours with peak traffic |

### 6.2 Connection Pool Settings

```yaml
# HikariCP configuration
spring:
  datasource:
    writer:
      hikari:
        maximum-pool-size: 30
        minimum-idle: 10
        connection-timeout: 5000
        idle-timeout: 300000
    reader:
      hikari:
        maximum-pool-size: 50
        minimum-idle: 20
        connection-timeout: 5000
        idle-timeout: 300000
```

---

## 7. Performance Testing Plan

| Test Type | Tool | Target | Success Criteria |
|-----------|------|--------|------------------|
| Load test (steady) | JMeter/Gatling | 500 TPS mixed read/write for 30 min | P95 < latency targets; 0 errors |
| Stress test (peak) | JMeter/Gatling | 2,500 TPS for 5 min | < 1% error rate; graceful degradation |
| Soak test | JMeter/Gatling | 200 TPS for 4 hours | No memory leaks; stable latency |
| Failover test | Manual | Writer failure during load | < 30s recovery; 0 committed data loss |
| Conflict test | Custom script | 100 concurrent creates for same advisor/slot | Exactly 1 succeeds; 99 get 409 |

---

## 8. Sign-Off

| Role | Name | Date | Approved |
|------|------|------|----------|
| Tech Lead | | | ☐ |
| Architect | | | ☐ |
| SRE Lead | | | ☐ |
| Product Owner | | | ☐ |
