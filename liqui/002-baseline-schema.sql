

--  Conventions: id UUID PK DEFAULT gen_random_uuid(); sf_id CHAR(18) UNIQUE nullable;

--  created_at/updated_at TIMESTAMPTZ DEFAULT now(); is_active on master/config tables.

--  Tables are created in FK-dependency order. Secondary indexes + EXCLUDE live in 003; triggers in 004.



--changeset team:002-baseline-schema

--comment: All 24 baseline tables in FK-dependency order (roots first, transaction tables last).



-- ===== Reference / config roots (no outgoing FKs) =====



CREATE TABLE operating_hours (

    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id       CHAR(18) UNIQUE,

    name        TEXT NOT NULL,

    timezone    TEXT NOT NULL,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE service_territory_group (

    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id           CHAR(18) UNIQUE,

    name            TEXT NOT NULL,

    time_zone       TEXT,

    wpa_cap_enabled BOOLEAN NOT NULL DEFAULT FALSE,

    is_active       BOOLEAN NOT NULL DEFAULT TRUE,

    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE appointment_scheduling_policy (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                  CHAR(18) UNIQUE,

    name                   TEXT NOT NULL,

    enforce_skills         BOOLEAN NOT NULL DEFAULT FALSE,

    enforce_daily_limit    BOOLEAN NOT NULL DEFAULT FALSE,

    allow_overlap_override BOOLEAN NOT NULL DEFAULT FALSE,

    is_active              BOOLEAN NOT NULL DEFAULT TRUE,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE engagement_channel_type (

    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id       CHAR(18) UNIQUE,

    name        TEXT NOT NULL,

    is_active   BOOLEAN NOT NULL DEFAULT TRUE,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE skill (

    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id          CHAR(18) UNIQUE,

    name           TEXT NOT NULL,

    skill_category TEXT,

    is_active      BOOLEAN NOT NULL DEFAULT TRUE,

    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE customer (

    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id         CHAR(18) UNIQUE,

    customer_id   VARCHAR(50) NOT NULL,

    customer_type TEXT,

    first_name    TEXT,

    last_name     TEXT,

    email         TEXT,

    phone         TEXT,

    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_customer_customer_id UNIQUE (customer_id)

);



CREATE TABLE app_user (

    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id       CHAR(18) UNIQUE,

    corp_id     VARCHAR(50) NOT NULL,

    first_name  TEXT,

    last_name   TEXT,

    email       TEXT,

    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_app_user_corp_id UNIQUE (corp_id)

);



-- ===== Config depending on the roots above =====



CREATE TABLE service_territory (

    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id              CHAR(18) UNIQUE,

    territory_group_id UUID NOT NULL REFERENCES service_territory_group(id),

    branch_number      TEXT,

    name               TEXT NOT NULL,

    operating_hours_id UUID REFERENCES operating_hours(id),

    is_active          BOOLEAN NOT NULL DEFAULT TRUE,

    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE work_type_group (

    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                CHAR(18) UNIQUE,

    name                 TEXT NOT NULL,

    time_zone            TEXT,

    allow_override       BOOLEAN NOT NULL DEFAULT FALSE,

    scheduling_policy_id UUID REFERENCES appointment_scheduling_policy(id),

    is_active            BOOLEAN NOT NULL DEFAULT TRUE,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE service_resource (

    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                 CHAR(18) UNIQUE,

    user_id               UUID NOT NULL REFERENCES app_user(id),

    advisor_code          TEXT,

    primary_territory_id  UUID NOT NULL REFERENCES service_territory(id),

    secondary_territory_id UUID REFERENCES service_territory(id),

    is_active             BOOLEAN NOT NULL DEFAULT TRUE,

    created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE work_type (

    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id             CHAR(18) UNIQUE,

    name              TEXT NOT NULL,

    duration_minutes  INTEGER NOT NULL,

    buffer_minutes    INTEGER NOT NULL DEFAULT 0,

    work_type_group_id UUID NOT NULL REFERENCES work_type_group(id),

    is_active         BOOLEAN NOT NULL DEFAULT TRUE,

    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_work_type_duration_positive CHECK (duration_minutes > 0),

    CONSTRAINT ck_work_type_buffer_allowed    CHECK (buffer_minutes IN (0, 15, 30, 45, 60))

);



CREATE TABLE time_slot (

    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id        CHAR(18) UNIQUE,

    territory_id UUID NOT NULL REFERENCES service_territory(id),

    day_of_week  SMALLINT NOT NULL,

    start_time   TIME NOT NULL,

    end_time     TIME NOT NULL,

    slot_minutes INTEGER NOT NULL,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_time_slot_day CHECK (day_of_week BETWEEN 0 AND 6),

    CONSTRAINT ck_time_slot_window CHECK (end_time > start_time),

    CONSTRAINT ck_time_slot_minutes CHECK (slot_minutes > 0)

);



CREATE TABLE max_appointment_per_day_constraint (

    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                    CHAR(18) UNIQUE,

    name                     TEXT NOT NULL,

    service_territory_id     UUID NOT NULL REFERENCES service_territory(id),

    max_appointments_per_day INTEGER NOT NULL,

    work_type_group_id       UUID REFERENCES work_type_group(id),

    effective_start_date     DATE,

    effective_end_date       DATE,

    is_active                BOOLEAN NOT NULL DEFAULT TRUE,

    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_max_appt_positive CHECK (max_appointments_per_day > 0)

);



CREATE TABLE service_resource_skill (

    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                CHAR(18) UNIQUE,

    service_resource_id  UUID NOT NULL REFERENCES service_resource(id),

    skill_id             UUID NOT NULL REFERENCES skill(id),

    effective_start_date DATE NOT NULL,

    effective_end_date   DATE,

    skill_level          INTEGER,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_srs UNIQUE (service_resource_id, skill_id, effective_start_date),

    CONSTRAINT ck_srs_window CHECK (effective_end_date IS NULL OR effective_end_date >= effective_start_date)

);



CREATE TABLE work_type_required_skill (

    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id        CHAR(18) UNIQUE,

    work_type_id UUID NOT NULL REFERENCES work_type(id),

    skill_id     UUID NOT NULL REFERENCES skill(id),

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_wtrs UNIQUE (work_type_id, skill_id)

);



CREATE TABLE shift (

    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id               CHAR(18) UNIQUE,

    service_resource_id UUID NOT NULL REFERENCES service_resource(id),

    start_time          TIMESTAMPTZ NOT NULL,

    end_time            TIMESTAMPTZ NOT NULL,

    status              TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_shift_window CHECK (end_time > start_time)

);

-- ===== Transaction tables =====



CREATE TABLE service_appointment (

    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                    CHAR(18) UNIQUE,

    customer_ref_id          UUID NOT NULL REFERENCES customer(id),

    work_type_id             UUID NOT NULL REFERENCES work_type(id),

    engagement_channel_type_id UUID REFERENCES engagement_channel_type(id),

    service_territory_id     UUID NOT NULL REFERENCES service_territory(id),

    status                   TEXT NOT NULL,

    sched_start_time         TIMESTAMPTZ NOT NULL,

    sched_end_time           TIMESTAMPTZ NOT NULL,

    created_in_dr            BOOLEAN NOT NULL DEFAULT TRUE,

    created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_sa_window CHECK (sched_end_time > sched_start_time)

);



-- Timing/status/allow_overlap denormalized here because the no-double-book EXCLUDE (003)

-- can only reference columns on this table. block_end_time = sched_end_time + buffer (set by trigger in 004).

CREATE TABLE assigned_resource (

    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                CHAR(18) UNIQUE,

    service_appointment_id UUID NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,

    service_resource_id  UUID NOT NULL REFERENCES service_resource(id),

    is_primary           BOOLEAN NOT NULL DEFAULT FALSE,

    sched_start_time     TIMESTAMPTZ NOT NULL,

    sched_end_time       TIMESTAMPTZ NOT NULL,

    block_end_time       TIMESTAMPTZ NOT NULL,

    allow_overlap        BOOLEAN NOT NULL DEFAULT FALSE,

    status               TEXT NOT NULL,

    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT ck_ar_window CHECK (sched_end_time > sched_start_time),

    CONSTRAINT ck_ar_block  CHECK (block_end_time >= sched_end_time)

);



CREATE TABLE service_appointment_attendee (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                  CHAR(18) UNIQUE,

    service_appointment_id UUID NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,

    attendee_email         TEXT,

    attendee_name          TEXT,

    relationship           TEXT,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE appointment_note (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    sf_id                  CHAR(18) UNIQUE,

    service_appointment_id UUID NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,

    note_type              TEXT,

    note_text              TEXT,

    submitted_by_corp_id   VARCHAR(50),

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



-- ===== Integration / operations =====



CREATE TABLE service_appointment_event_outbox (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    service_appointment_id UUID NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,

    event_type             TEXT NOT NULL,

    published              BOOLEAN NOT NULL DEFAULT FALSE,

    published_at           TIMESTAMPTZ,

    failback_status        TEXT NOT NULL DEFAULT 'Pending',

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE notification_record (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    service_appointment_id UUID NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,

    notification_type      TEXT,

    channel                TEXT,

    status                 TEXT,

    sent_at                TIMESTAMPTZ,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE scheduler_log (

    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    level        TEXT,

    source       TEXT,

    message      TEXT,

    context_json JSONB,

    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()

);



CREATE TABLE appointment_action_failure (

    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),

    service_appointment_id UUID REFERENCES service_appointment(id) ON DELETE SET NULL,

    action_type            TEXT,

    reason                 TEXT,

    retry_count            INTEGER NOT NULL DEFAULT 0,

    last_retry_at          TIMESTAMPTZ,

    status                 TEXT,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT now(),

    updated_at             TIMESTAMPTZ NOT NULL DEFAULT now()

);



--rollback DROP TABLE IF EXISTS appointment_action_failure CASCADE;

--rollback DROP TABLE IF EXISTS scheduler_log CASCADE;

--rollback DROP TABLE IF EXISTS notification_record CASCADE;

--rollback DROP TABLE IF EXISTS service_appointment_event_outbox CASCADE;

--rollback DROP TABLE IF EXISTS appointment_note CASCADE;

--rollback DROP TABLE IF EXISTS service_appointment_attendee CASCADE;

--rollback DROP TABLE IF EXISTS assigned_resource CASCADE;

--rollback DROP TABLE IF EXISTS service_appointment CASCADE;

--rollback DROP TABLE IF EXISTS shift CASCADE;

--rollback DROP TABLE IF EXISTS work_type_required_skill CASCADE;

--rollback DROP TABLE IF EXISTS service_resource_skill CASCADE;

--rollback DROP TABLE IF EXISTS max_appointment_per_day_constraint CASCADE;

--rollback DROP TABLE IF EXISTS time_slot CASCADE;

--rollback DROP TABLE IF EXISTS work_type CASCADE;

--rollback DROP TABLE IF EXISTS service_resource CASCADE;

--rollback DROP TABLE IF EXISTS work_type_group CASCADE;

--rollback DROP TABLE IF EXISTS service_territory CASCADE;

--rollback DROP TABLE IF EXISTS app_user CASCADE;

--rollback DROP TABLE IF EXISTS customer CASCADE;

--rollback DROP TABLE IF EXISTS skill CASCADE;

--rollback DROP TABLE IF EXISTS engagement_channel_type CASCADE;

--rollback DROP TABLE IF EXISTS appointment_scheduling_policy CASCADE;

--rollback DROP TABLE IF EXISTS service_territory_group CASCADE;

--rollback DROP TABLE IF EXISTS operating_hours CASCADE;

