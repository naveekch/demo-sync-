# Option B — Hybrid RDBMS + Document DB — WEDAS-1082

> **Story**: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> **Subtask**: WEDAS-1082 — Document Option B - Hybrid RDBMS + Document DB  
> **Date**: 2026-07-16  
> **Authors**: Naveen Chelluboina, team

---

## 1. Overview

Option B proposes a **hybrid architecture** combining:
- **Aurora PostgreSQL** for configuration/reference data and transactional writes
- **Amazon DocumentDB** (MongoDB-compatible) for appointment documents, search, and high-read workloads

---

## 2. Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        DAP DR App                             │
│                                                              │
│  ┌────────────────────┐    ┌──────────────────────────┐     │
│  │  Config Service     │    │  Appointment Service      │     │
│  │  (Spring Data JPA)  │    │  (Spring Data MongoDB)    │     │
│  └─────────┬──────────┘    └────────────┬─────────────┘     │
│            │                            │                    │
│            ▼                            ▼                    │
│  ┌────────────────────┐    ┌──────────────────────────┐     │
│  │  Aurora PostgreSQL  │    │   Amazon DocumentDB       │     │
│  │  (Config/Reference) │    │   (Appointments/Search)   │     │
│  └────────────────────┘    └──────────────────────────┘     │
└──────────────────────────────────────────────────────────────┘
```

### 2.1 Data Partitioning

| Database | Data Domains | Rationale |
|----------|-------------|-----------|
| **Aurora PostgreSQL** | Operating hours, time slots, territories, resources, shifts, skills, territory members, constraints, scheduler config | Relational integrity; JOIN-heavy availability calculations |
| **DocumentDB** | Appointments (denormalized documents), attendees (embedded), notes (embedded), notifications, audit logs | Document-per-appointment pattern; fast reads without JOINs |

---

## 3. Document Schema Design (DocumentDB)

### 3.1 Appointment Document

```json
{
  "_id": "uuid-appointment-id",
  "sfId": "08p000000000001AAA",
  "status": "Scheduled",
  "schedStartTime": "2026-07-20T10:00:00Z",
  "schedEndTime": "2026-07-20T11:00:00Z",
  "durationInMinutes": 60,
  "appointmentMode": "INDIVIDUAL",
  "appointmentType": "Standard",
  "eventType": "1:1",
  "meetingMethod": "VIRTUAL",
  "language": "English",
  
  "customer": {
    "type": "Account",
    "sfId": "001000000000001",
    "partyId": "PID123456",
    "mid": "MID789",
    "firstName": "John",
    "lastName": "Doe"
  },
  
  "territory": {
    "id": "uuid-territory",
    "sfId": "13q000000000001",
    "name": "Boston Branch",
    "branchNumber": "B001"
  },
  
  "assignedResources": [
    {
      "id": "uuid-resource-1",
      "sfId": "ServiceResource-001",
      "name": "Jane Advisor",
      "corpId": "a123456",
      "isPrimary": true
    }
  ],
  
  "attendees": [
    {
      "id": "uuid-attendee-1",
      "email": "spouse@email.com",
      "relationship": "Spouse",
      "status": "Enrolled"
    }
  ],
  
  "notes": [
    {
      "type": "Customer",
      "status": "Pre",
      "detail": "Discuss retirement planning",
      "submitterCorpId": "a123456"
    }
  ],
  
  "engagement": {
    "channelTypeId": "uuid-channel",
    "channelName": "Virtual"
  },
  
  "workType": {
    "id": "uuid-worktype",
    "name": "Financial Consultation",
    "durationInMinutes": 60
  },
  
  "virtualMeeting": {
    "link": "https://zoom.us/j/123456",
    "provider": "Zoom"
  },
  
  "cancellation": null,
  "rescheduleComments": null,
  
  "audit": {
    "createdAt": "2026-07-16T08:00:00Z",
    "updatedAt": "2026-07-16T08:00:00Z",
    "createdInDR": false,
    "drModified": false
  },
  
  "notifications": [
    {
      "type": "Confirmation",
      "channel": "Customer Email",
      "status": "Success",
      "sentAt": "2026-07-16T08:01:00Z"
    }
  ]
}
```

### 3.2 Indexes (DocumentDB)

```javascript
// Primary lookups
db.appointments.createIndex({ "sfId": 1 }, { unique: true });
db.appointments.createIndex({ "_id": 1 });

// Search params
db.appointments.createIndex({ "status": 1, "schedStartTime": 1, "schedEndTime": 1 });
db.appointments.createIndex({ "assignedResources.corpId": 1, "schedStartTime": 1 });
db.appointments.createIndex({ "territory.branchNumber": 1, "schedStartTime": 1 });
db.appointments.createIndex({ "customer.partyId": 1 });
db.appointments.createIndex({ "customer.mid": 1 });

// Conflict detection
db.appointments.createIndex({ 
  "assignedResources.id": 1, 
  "schedStartTime": 1, 
  "schedEndTime": 1, 
  "status": 1 
});
```

---

## 4. Relational Schema (Aurora PostgreSQL — Config Only)

A reduced version of `aurora_scheduler_schema.sql` containing only Sections 1-2 and Section 6:
- operating_hours, time_slot, service_territory
- service_resource, service_territory_member, shift, skill, service_resource_skill
- work_type, work_type_group, engagement_channel_type
- scheduler_config, scheduler_global
- max_appointment_per_day_constraint, max_appointment_constraint_member
- resource_alignment

**Excluded from PostgreSQL** (moved to DocumentDB):
- service_appointment → appointment document
- assigned_resource → embedded in document
- service_appointment_attendee → embedded in document
- appointment_note → embedded in document
- notification_record → embedded in document
- publishing_event_record → separate collection
- external_event_record → separate collection

---

## 5. Synchronization Strategy

### 5.1 Cross-Database Consistency

```
SF Config Sync ──────────┐
                         ▼
                  ┌─────────────┐
                  │   Aurora     │ (config, resources, shifts)
                  │  PostgreSQL  │
                  └─────────────┘
                         │
                         │ (resource IDs referenced in docs)
                         ▼
DEP Events ────────► ┌─────────────┐
                     │  DocumentDB  │ (appointments)
                     └─────────────┘
```

**Challenge**: When creating an appointment in DR mode, the app must:
1. Read config from PostgreSQL (availability, territory, resource validation)
2. Write appointment document to DocumentDB
3. These are **two separate databases** — no distributed transaction

### 5.2 Eventual Consistency Handling

| Scenario | Risk | Mitigation |
|----------|------|------------|
| Appointment created but notification write fails | Notification lost | Retry with outbox pattern in DocumentDB |
| Config updated in PG but stale doc references old config | Stale territory/resource name in doc | Denormalize at write time; accept staleness |
| Double-booking during concurrent writes | Two appointments for same advisor/slot | Use DocumentDB conditional writes (`$setOnInsert` + unique compound index) |

---

## 6. RPO / RTO Estimates

| Metric | Value | Notes |
|--------|-------|-------|
| **RPO** | **< 5 minutes** | Same as Option A for appointments (DEP sync) |
| **RTO** | **< 20 minutes** | Slightly higher — two systems to validate on failover |
| **Data Loss Window** | Near-zero for appointments | DocumentDB has same durability guarantees |

---

## 7. Performance Characteristics

### 7.1 Read Performance

| Query Pattern | Expected Latency | Database | Notes |
|--------------|------------------|----------|-------|
| Get Appointment by ID | < 3 ms | DocumentDB | Single document fetch, no JOINs |
| Search Appointments | < 30 ms | DocumentDB | Compound index scan; no JOIN overhead |
| Get Availability | < 200 ms | PostgreSQL + Graph | Shifts + territories from PG; Outlook from Graph |
| Branch Availability | < 20 ms | PostgreSQL | Same as Option A |

### 7.2 Write Performance

| Operation | Expected Latency | Notes |
|-----------|------------------|-------|
| Create Appointment | < 30 ms | Single document insert (no multi-table transaction) |
| Cancel Appointment | < 10 ms | Single document update |
| Reschedule | < 15 ms | Single document update (no separate note insert) |
| Bulk sync (1000 docs) | < 1 second | DocumentDB bulk write |

### 7.3 Throughput

| Metric | Capacity |
|--------|----------|
| Peak writes | ~2,000 TPS (DocumentDB auto-scales) |
| Peak reads | ~10,000 TPS (read replicas) |
| Document size | ~2-5 KB per appointment |

---

## 8. Licensing & Cost

| Component | Monthly Cost (Estimate) | Notes |
|-----------|------------------------|-------|
| Aurora PostgreSQL db.r6g.medium (config only) | ~$300 | Smaller instance — config reads only |
| DocumentDB db.r6g.large (writer) | ~$600 | Appointment operations |
| DocumentDB Reader (1 instance) | ~$400 | Search queries |
| Aurora Storage | ~$10 | Config data is small |
| DocumentDB Storage | ~$30 | Document storage |
| **Total** | **~$1,340/month** | ~50% more than Option A |

---

## 9. Advantages

| # | Advantage |
|---|-----------|
| 1 | **Blazing fast reads** — single document fetch, no JOINs for appointment GET |
| 2 | **Flexible schema** — can evolve appointment shape without ALTER TABLE migrations |
| 3 | **Natural document model** — appointment + attendees + notes = one document (mirrors API response shape) |
| 4 | **Horizontal scaling** — DocumentDB shards automatically |
| 5 | **Search-friendly** — compound indexes on any nested field |
| 6 | **Separation of concerns** — config (relational) vs. transactional (document) |

---

## 10. Disadvantages / Risks

| # | Risk | Severity | Mitigation |
|---|------|----------|------------|
| 1 | **No cross-database transactions** | High | Saga pattern; accept eventual consistency for non-critical data |
| 2 | **Double-booking race condition** | High | Conditional writes + advisor-level locking in DocumentDB |
| 3 | **Two systems to operate** | Medium | More monitoring, more failure modes, more runbooks |
| 4 | **Sync complexity** | Medium | Config IDs in documents must match PG IDs; reference integrity is app-enforced |
| 5 | **Failback complexity** | Medium | Must export documents + join with PG config to reconstruct SF records |
| 6 | **Team skill gap** | Medium | Team knows SQL; MongoDB query patterns require learning |
| 7 | **DocumentDB limitations** | Low | Not full MongoDB (no $lookup across collections, no change streams in all versions) |
| 8 | **Higher cost** | Low | ~$440/month more than Option A |
| 9 | **Data duplication** | Low | Territory/resource names denormalized into documents (can drift) |

---

## 11. Operational Complexity Assessment

| Dimension | Option A (Single RDBMS) | Option B (Hybrid) |
|-----------|------------------------|-------------------|
| Deployment targets | 1 | 2 |
| Connection strings to manage | 2 (writer + reader) | 4 (PG writer + reader, DocDB writer + reader) |
| Monitoring dashboards | 1 | 2 |
| Backup strategies | 1 | 2 |
| Failover procedures | 1 | 2 (must verify both healthy) |
| Schema migration tools | Flyway | Flyway + custom DocumentDB migrations |
| ORM/data access layers | Spring Data JPA | Spring Data JPA + Spring Data MongoDB |
| Integration test complexity | Standard | Requires test containers for both |

---

## 12. When to Choose Option B

Option B is justified **only if**:
1. Read-heavy workload vastly exceeds writes (>50:1 ratio)
2. Appointment document shape changes frequently and unpredictably
3. The system must scale horizontally to handle 10x+ current traffic
4. Query patterns are primarily document-oriented (get full appointment with all nested data)

For Phase 1 DR with ~200K appointments and moderate traffic, these conditions are **not met**.
