# Copilot Instructions — DR Scheduler (Aurora PostgreSQL)



Guidance for AI-assisted code in this repo. Follow these rules when generating Java/Spring code,

JPA entities, repositories, services, and Liquibase changelogs.



## What this project is

Disaster-recovery (DR) standby for the Salesforce Scheduler (financial-advisor appointment

booking). The database is active only during a Salesforce outage. It is a Java + Spring Boot

service on Aurora PostgreSQL. Correctness during that outage is the whole point — never

double-book an advisor.



## Stack (use these; don't introduce alternatives without asking)

- Java 21, Spring Boot 3.x

- Spring Web (REST controllers)

- **Spring Data JPA + Hibernate** (ORM) — the persistence default

- **Liquibase** for schema migrations (formatted-SQL changelogs)

- HikariCP connection pool (Spring Boot default)

- Aurora PostgreSQL 15, single writer endpoint via RDS Proxy (Phase 1)



## THE GOLDEN RULE: the database owns correctness

The no-double-booking rule is enforced by a PostgreSQL `EXCLUDE` constraint

(`no_double_book` on `assigned_resource`) — **NOT in Java**.

- DO NOT write service code that queries for overlapping appointments as the *correctness*

  mechanism ("check then insert"). That races under concurrency. Insert, and let the DB reject.

- On an overlap, PostgreSQL raises SQLSTATE **`23P01`** (exclusion_violation) → Hibernate throws

  `DataIntegrityViolationException` → translate it to a domain `SlotUnavailableException` → HTTP **409**.



## Hibernate / JPA rules

- `spring.jpa.hibernate.ddl-auto: validate` — ALWAYS. Never `update`/`create`/`create-drop`.

  Liquibase owns the schema; Hibernate only maps to it.

- Never add or alter a column by editing an `@Entity` and relying on Hibernate to change the DB.

  Schema changes go through a Liquibase changeset (see "DB changelog" below).

- DB-managed columns must be mapped read-only so Hibernate reads them back instead of writing them:

  - `block_end_time` — set by a BEFORE trigger (`sched_end_time + work_type.buffer_minutes`).

    Map `@Generated`, `insertable=false, updatable=false`. **Never set it in Java.**

  - `created_at` / `updated_at` — DB `DEFAULT now()` + an `updated_at` trigger. Map read-only;

    do not also set them with `@CreationTimestamp`/`@UpdateTimestamp` (don't fight the trigger).

- `id` (UUID PK): generate app-side with `UUID.randomUUID()` so Hibernate has the id without a

  round-trip. `sf_id` (Salesforce id, `CHAR(18)`, nullable, UNIQUE): NULL means "created in DR,

  not yet failed back" — never invent a value.

- After updating a `service_appointment` (reschedule/cancel/work-type change), a trigger updates

  its child `assigned_resource` rows. If you read those children back in the same transaction,

  call `entityManager.refresh()` to avoid a stale first-level cache.

- Timestamps are `TIMESTAMPTZ` → map to `OffsetDateTime`/`Instant`, never `LocalDateTime`.



## Transactions

- One booking = one `@Transactional` service method that writes ~6 tables (service_appointment,

  assigned_resource, attendees, note, notification, outbox) — all commit together or none.

- Keep `@Transactional` on the service layer, not on controllers or repositories.



## allow_overlap (super-scheduler override)

- `assigned_resource.allow_overlap` defaults FALSE; a TRUE row is exempt from the double-book

  constraint. Only set TRUE **server-side** after verifying BOTH: (a) the booking user holds the

  super-scheduler permission (from entitlements — never trust a client-sent flag), AND

  (b) the work_type_group's policy has `allow_overlap_override = TRUE`. For Wealth (Phase 1) it is

  always FALSE.



## What the "DB changelog" is

The DB changelog is the **Liquibase migration set** — the versioned source of truth for the

schema. Liquibase records applied changesets in a `DATABASECHANGELOG` table and applies any new

ones at application startup (before the app serves traffic).



Files (in a real app under `src/main/resources/db/changelog/`; in this repo under `new/liquibase/`):

- `db.changelog-master.yaml` — master; `include`s the change files in order.

- `001-extensions.sql` — `CREATE EXTENSION btree_gist` (required for the constraint) + `pgcrypto`.

- `002-baseline-schema.sql` — all 24 tables.

- `003-constraints-and-indexes.sql` — the `no_double_book` EXCLUDE constraint + hot-path indexes.

- `004-triggers.sql` — `updated_at`, `block_end_time`, and parent→child sync triggers.



### Rules for changing the schema

- **NEVER edit a changeset that has already been applied** — Liquibase checksums it and will fail.

  Add a NEW changeset instead.

- New changes = a new formatted-SQL file (e.g. `005-<name>.sql`) added to the master `include`s,

  or a new `--changeset` appended to a file that has not shipped yet.

- Each file's first line is `--liquibase formatted sql`; each change starts with

  `--changeset team:<unique-id>`.

- Any changeset containing a plpgsql body (`$$ ... $$`) or a `DO $$` block MUST set

  `splitStatements:false`. Use `runOnChange:true` only on `CREATE OR REPLACE FUNCTION`.

- Provide a `--rollback` for every changeset.

- Correctness features (EXCLUDE constraint, triggers, extensions) are raw SQL — do NOT try to

  express them through Liquibase's XML/YAML DSL (it can't model them).



## Schema quick reference

- Every table: `id UUID` PK + nullable `sf_id`. Master/config tables have `is_active` (soft delete).

- Core booking: `service_appointment` (header) 1—* `assigned_resource` (advisor rows; carries the

  timing + `allow_overlap` that the constraint reads).

- `work_type.buffer_minutes` (0/15/30/45/60) extends the advisor's blocked time beyond the meeting

  → feeds `block_end_time`.

- `service_resource` = advisor, with `primary_territory_id` + optional `secondary_territory_id`.

- Skills tables exist but are gated OFF in Phase 1 (read only when

  `appointment_scheduling_policy.enforce_skills = TRUE`).

- Failback: `service_appointment_event_outbox` (one row per DR-side change) drives the upsert back

  to Salesforce after the outage.



## Code-generation conventions

- Simple reads → Spring Data JPA repositories. The complex availability query (joins shifts ×

  territory × existing appointments × operating hours) → jOOQ or Spring `JdbcClient`, not a giant JPQL.

- Do NOT add a second datasource / read-write split in Phase 1 — single writer endpoint only.

- Map SQLSTATE `23P01` → `SlotUnavailableException` → HTTP 409.
