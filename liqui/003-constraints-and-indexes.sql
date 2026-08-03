--liquibase formatted sql



--  DR Scheduler — constraints + indexes. Converted from Flyway V3__constraints_and_indexes.sql.

--  Depends on 001 (btree_gist) and 002 (tables).



--changeset team:003-exclude-no-double-book

--comment: R1 — same advisor cannot hold two overlapping BLOCK ranges (meeting + buffer). Partial: Canceled and allow_overlap=TRUE rows are excluded. tstzrange default [) makes back-to-back non-overlapping.

ALTER TABLE assigned_resource

    ADD CONSTRAINT no_double_book

    EXCLUDE USING gist (

        service_resource_id                         WITH =,

        tstzrange(sched_start_time, block_end_time) WITH &&

    ) WHERE (status <> 'Canceled' AND allow_overlap = FALSE);

--rollback ALTER TABLE assigned_resource DROP CONSTRAINT IF EXISTS no_double_book;



--changeset team:003-indexes

--comment: secondary indexes for hot paths (PK / UNIQUE / the GiST above are already indexed)

CREATE INDEX idx_sa_status_start        ON service_appointment (status, sched_start_time);

CREATE INDEX idx_sa_customer_start      ON service_appointment (customer_ref_id, sched_start_time);

CREATE INDEX idx_sa_territory_start     ON service_appointment (service_territory_id, sched_start_time);

CREATE INDEX idx_ar_resource_appt       ON assigned_resource (service_resource_id, service_appointment_id);

CREATE INDEX idx_sr_primary_territory   ON service_resource (primary_territory_id);

CREATE INDEX idx_sr_secondary_territory ON service_resource (secondary_territory_id);

CREATE INDEX idx_shift_resource_time    ON shift (service_resource_id, start_time, end_time);

CREATE INDEX idx_work_type_group        ON work_type (work_type_group_id);

CREATE INDEX idx_srs_skill              ON service_resource_skill (skill_id);

CREATE INDEX idx_maxappt_territory      ON max_appointment_per_day_constraint (service_territory_id, is_active);

CREATE INDEX idx_outbox_published       ON service_appointment_event_outbox (published, created_at);

CREATE INDEX idx_outbox_failback_status ON service_appointment_event_outbox (failback_status);

--rollback DROP INDEX IF EXISTS idx_sa_status_start;

--rollback DROP INDEX IF EXISTS idx_sa_customer_start;

--rollback DROP INDEX IF EXISTS idx_sa_territory_start;

--rollback DROP INDEX IF EXISTS idx_ar_resource_appt;

--rollback DROP INDEX IF EXISTS idx_sr_primary_territory;

--rollback DROP INDEX IF EXISTS idx_sr_secondary_territory;

--rollback DROP INDEX IF EXISTS idx_shift_resource_time;

--rollback DROP INDEX IF EXISTS idx_work_type_group;

--rollback DROP INDEX IF EXISTS idx_srs_skill;

--rollback DROP INDEX IF EXISTS idx_maxappt_territory;

--rollback DROP INDEX IF EXISTS idx_outbox_published;

--rollback DROP INDEX IF EXISTS idx_outbox_failback_status;
