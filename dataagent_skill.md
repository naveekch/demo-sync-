# DR Data Scope Document — WEDAS-1080

> **Story**: WEDAS-1025 — DR Database Selection and Data Model Strategy  
> **Subtask**: WEDAS-1080 — Define DR Data Scope Document  
> **Date**: 2026-07-16  
> **Authors**: Naveen Chelluboina, team

---

## 1. Purpose

Define all data domains requiring DR coverage, their ownership, criticality ratings, and sync requirements to support core appointment operations (Create, Get, Cancel, Reschedule, Availability) when Salesforce Scheduler is unavailable.

---

## 2. DR-Supported Operations (Phase 1)

| Operation | HTTP | DR Scope | Notes |
|-----------|------|----------|-------|
| Get Availability (Regular) | GET | ✅ In Scope | Requires shifts, territories, resources, Outlook/Graph |
| Get Availability (Branch) | GET | ✅ In Scope | Configured availability from time slots |
| Get Availability (Next) | GET | ✅ In Scope | Next available slot calculation |
| Create Appointment | POST | ✅ In Scope | Write to DR DB + notify + DEP publish |
| Get Appointment by ID | GET | ✅ In Scope | Read from DR DB |
| Get Appointment by Search | GET | ✅ In Scope | Read from DR DB |
| Cancel Appointment | DELETE | ✅ In Scope | Update status + delete Outlook event + notify + DEP |
| Reschedule Appointment | PUT | ✅ In Scope | Update times/status + notify + DEP |
| Edit Appointment | PATCH | ❌ Out of Scope | Returns 501 |
| Get Availability (Edit) | GET | ❌ Out of Scope | Returns 501 |

---

## 3. Data Domain Inventory

### 3.1 Configuration Data (Static/Slow-Change)

| # | Data Domain | SF Object | Criticality | Sync Frequency | Owner |
|---|-------------|-----------|-------------|----------------|-------|
| 1 | Operating Hours | `OperatingHours` | **Critical** | Daily | Platform |
| 2 | Time Slots | `TimeSlot` | **Critical** | Daily | Platform |
| 3 | Service Territories (Branches) | `ServiceTerritory` | **Critical** | Daily | Platform |
| 4 | Work Types | `WorkType` | Medium | Daily | Platform |
| 5 | Work Type Groups | `WorkTypeGroup` | Medium | Daily | Platform |
| 6 | Engagement Channel Types | `EngagementChannelType` | **Critical** | Daily | Platform |
| 7 | Scheduler Config (metadata) | `DAP_Scheduler_Config__mdt` | Medium | Deploy-time | Platform |
| 8 | Scheduler Global Settings | `Dap_Scheduler_Global__c` | Medium | Daily | Platform |
| 9 | Delivery Platforms | `DAP_Delivery_Platform__c` | Low | Weekly | Platform |
| 10 | Registration Platforms | `DAP_Registration_Platform__c` | Low | Weekly | Platform |
| 11 | Registration-Delivery Mappings | `DAP_Registration_Delivery_Mapping__c` | Low | Weekly | Platform |
| 12 | Max Appointment Constraints | `DAP_Max_Appointment_Per_Day_Constraint__c` | Medium | Daily | Platform |
| 13 | Constraint Members | `DAP_Max_Appointment_Constraint_Member__c` | Medium | Daily | Platform |

### 3.2 Resource Data (Medium-Change)

| # | Data Domain | SF Object | Criticality | Sync Frequency | Owner |
|---|-------------|-----------|-------------|----------------|-------|
| 14 | Service Resources (Advisors) | `ServiceResource` | **Critical** | Daily + hourly delta | Platform |
| 15 | Service Territory Members | `ServiceTerritoryMember` | **Critical** | Daily + hourly delta | Platform |
| 16 | Shifts | `Shift` | **Critical** | Daily + hourly delta | Platform |
| 17 | Skills | `Skill` | Low | Daily | Platform |
| 18 | Service Resource Skills | `ServiceResourceSkill` | Low | Daily | Platform |
| 19 | Resource Alignments | `DAP_Resource_Alignment__c` | Medium | Daily | Platform |

### 3.3 Appointment Data (High-Change — Transactional)

| # | Data Domain | SF Object | Criticality | Sync Frequency | Owner |
|---|-------------|-----------|-------------|----------------|-------|
| 20 | Service Appointments | `ServiceAppointment` | **Critical** | Real-time via DEP | Platform |
| 21 | Assigned Resources | `AssignedResource` | **Critical** | Real-time via DEP | Platform |
| 22 | Service Appointment Attendees | `ServiceAppointmentAttendee` | **Critical** | Real-time via DEP | Platform |
| 23 | Appointment Notes | `Dap_Service_Appointment_Note__c` | Medium | Real-time via DEP | Platform |

### 3.4 Customer Data (NOT in DR Scope)

| # | Data Domain | SF Object | Criticality | In DR? | Reason |
|---|-------------|-----------|-------------|--------|--------|
| 24 | Accounts (Customers) | `Account` | N/A | ❌ | CRM-owned; resolve on failback |
| 25 | Leads (Prospects) | `Lead` | N/A | ❌ | CRM-owned; resolve on failback |
| 26 | Users | `User` | Partial | ⚠️ Partial | Only corp_id ↔ resource mapping needed |

> **Note**: Customer identity in DR will use the `customerId` (PartyId/MID/MemberMID) passed in API requests. Full Account resolution happens on failback to SF.

### 3.5 Integration/Audit Data (DR-Generated)

| # | Data Domain | Purpose | Storage | Owner |
|---|-------------|---------|---------|-------|
| 27 | DR Appointment Audit Log | Track all DR-mode changes | DR DB | Platform |
| 28 | Notification Records | Track notification send status | DR DB | Platform |
| 29 | DEP Publishing Records | Track DEP event publishing | DR DB | Platform |
| 30 | External Event Records | Track outbound events | DR DB | Platform |

---

## 4. Data Volume Estimates

| Data Domain | Estimated Record Count | Growth Rate | Size Estimate |
|-------------|----------------------|-------------|---------------|
| Service Territories | ~1,500 | Slow | < 1 MB |
| Service Resources | ~15,000 | Slow | ~5 MB |
| Territory Members | ~20,000 | Slow | ~3 MB |
| Shifts (active) | ~50,000 (30-day window) | Daily churn | ~20 MB |
| Time Slots | ~10,000 | Slow | ~2 MB |
| Future Appointments (Scheduled+Rescheduled) | ~200,000 | ~5,000/day | ~100 MB |
| Assigned Resources | ~200,000 | Matches appointments | ~30 MB |
| Attendees | ~50,000 | Subset of appointments | ~10 MB |
| **Total Active Dataset** | | | **~200 MB** |

---

## 5. Sync Strategy

### 5.1 Initial Load
- Full snapshot of all configuration + resource + future appointment data
- Source: Salesforce SOQL Bulk API or Data Loader export
- Target: DR Database
- Expected duration: < 2 hours for full load

### 5.2 Continuous Sync

| Mechanism | Data Domains | Frequency | Direction |
|-----------|-------------|-----------|-----------|
| Scheduled config sync | Config (#1-13), Resources (#14-19) | Daily + hourly delta | SF → DR DB |
| DEP subscription | Appointments (#20-23) | Real-time | SF → DEP → DR DB |
| DR audit write-back | DR changes (#27-30) | On failback | DR DB → SF |

### 5.3 Failback Reconciliation
1. Bulk export DR-created/modified appointments
2. Resolve customer Account/Lead IDs in SF
3. Upsert appointments into SF (suppress DEP + notifications)
4. Mark DR audit records as reconciled

---

## 6. Data Freshness Requirements

| Tier | Max Staleness | Data Domains |
|------|--------------|--------------|
| Real-time (< 5 min) | Appointments, Assigned Resources, Attendees | Via DEP events |
| Near-real-time (< 1 hr) | Shifts, Territory Members, Resources | Hourly sync |
| Daily | Config tables, Work Types, Constraints | Nightly batch |

---

## 7. Exclusions

The following are explicitly **NOT** in DR data scope:
- Full CRM Account/Lead records (only IDs referenced)
- 1:Many Workshop/Event data (WEPA scheduling)
- UPS Publishing records
- Historical/closed appointments
- Notification templates (hard-coded in DR app)
- EAC/Outlook calendar sync (handled separately via Graph API)

---

## 8. Sign-Off

| Role | Name | Date | Approved |
|------|------|------|----------|
| Tech Lead | | | ☐ |
| Architect | | | ☐ |
| Product Owner | | | ☐ |
