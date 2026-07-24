# Locked Decisions and Core Requirements

> Date: 2026-07-23

---

## 1. Locked Decisions (Team Confirmed)

| # | Decision | Implementation Direction |
|---|---|---|
| 1 | Dual identity on every record | id UUID PK plus sf_id external id for sync/failback/upsert |
| 2 | Customer is flat and request-fed | Store only customerId/MID, type, name, email, phone |
| 3 | Remove Account vs Lead parent from DR | No parent polymorphic fields in DR; resolve in SF failback |
| 4 | Customer to appointment is many-to-one | One customer to many appointments, matched by customerId/MID |
| 5 | Customer, User, Advisor are separate entities | service_resource references app_user; scheduler can exist without advisor row |
| 6 | Do not store volatile profile metadata | Fetch role/level data from source systems at runtime when needed |
| 7 | Failback is manual batch delta job | Upsert DR deltas to SF and write sf_id back on success |
| 8 | Duration comes from work_type | Advisor does not own duration |
| 9 | Skills filtering out of scope for Wealth | Defer skill-driven availability |
| 10 | Service territory grouping required | Group-level rules for caps, operating hours, and time zone |
| 11 | Wealth and WPA share one data model | Reuse DB model and APIs; UI may differ |

---

## 2. Architecture Requirements

### 2.1 Core Correctness Requirements

| ID | Requirement | Why It Matters |
|---|---|---|
| R1 | Prevent overlapping advisor appointments at write time | Core business invariant |
| R2 | Commit appointment write set atomically | Avoid partial records during outage |
| R3 | Deterministic identity matching for sync/failback | Prevent duplicate and orphan rows |
| R4 | Customer matching by customerId/MID only | Matches existing DEP and SF resolution pattern |
| R5 | Failback delta extraction by sf_id null and outbox state | Idempotent reconciliation |

### 2.2 Functional Requirements

| ID | Requirement | Notes |
|---|---|---|
| F1 | Support create/get/search/cancel/reschedule | Phase 1 API baseline |
| F2 | Support availability with territory rules and shifts | Includes group-level rules |
| F3 | Support user and advisor separation | Advisor is optional subset |
| F4 | Work type drives slot duration | Shared behavior across Wealth and WPA |

### 2.3 Non-Functional Requirements

| ID | Requirement | Target |
|---|---|---|
| N1 | RTO | less than 15 minutes |
| N2 | RPO for appointments | less than 5 minutes |
| N3 | P95 create DB latency | less than 100 ms |
| N4 | Operational simplicity | Single runbook preferred for outage mode |
| N5 | Cost discipline | Avoid dual-engine overhead unless required by scale |

---

## 3. Requirement Priority

| Priority | Includes |
|---|---|
| Must | R1, R2, R3, R4, R5, F1, F2, N1, N2 |
| Should | F3, F4, N3, N4 |
| Could | Additional denormalized projections for read optimization |

---

## 4. Acceptance Conditions

1. Storage layer blocks double booking without relying only on application race checks.
2. Appointment write path is atomic for core transactional entities.
3. Failback process is repeatable and idempotent on retries.
4. Data model excludes Account/Lead polymorphic dependency in DR.
5. Model supports both Wealth and WPA using same schema.
