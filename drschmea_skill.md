-- =============================================================================
-- Aurora PostgreSQL DR Schema — Salesforce Scheduler Mirror
-- Generated from: ap110733-pi-crm-salesforce codebase audit
-- Engine:  Aurora PostgreSQL 15+  (compatible with RDS PostgreSQL 15+)
-- Extensions required: pgcrypto (gen_random_uuid), PostGIS (geolocation)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- EXTENSIONS
-- ─────────────────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";      -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "postgis";       -- GEOGRAPHY for geolocation

-- ─────────────────────────────────────────────────────────────────────────────
-- ENUMS  (mirrors SF picklists for type safety)
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TYPE appointment_status AS ENUM (
    'Scheduled', 'Rescheduled', 'Canceled', 'Edited', 'Published', 'Closed'
);

CREATE TYPE appointment_mode AS ENUM ('GROUP', 'INDIVIDUAL');

CREATE TYPE appointment_type AS ENUM ('Joint', 'Standard');

CREATE TYPE event_type AS ENUM ('1:1', '1:Many');

CREATE TYPE meeting_method AS ENUM ('PHONE', 'VIRTUAL', 'BRANCH');

CREATE TYPE customer_status AS ENUM ('Enrolled', 'Attended', 'No Show');

CREATE TYPE language_type AS ENUM ('English', 'Spanish');

CREATE TYPE named_resource_type AS ENUM ('Named Resource', 'Scheduled Resource');

CREATE TYPE registration_system AS ENUM ('Connect', 'Saba', 'None', 'Fidelity');

CREATE TYPE territory_member_type AS ENUM ('P', 'S');   -- Primary, Secondary

CREATE TYPE notification_channel AS ENUM (
    'Customer Email', 'Customer SMS', 'Associate Email', 'Participant Email'
);

CREATE TYPE notification_status AS ENUM ('Success', 'Failure', 'Pending', 'In Progress');

CREATE TYPE notification_type AS ENUM (
    'Confirmation', 'Reschedule', 'Cancellation', 'Reminder',
    'SecondReminder', 'Edit', 'EditConfirmation', 'Updated', 'Attended'
);

CREATE TYPE participant_status AS ENUM (
    'Registered', 'Attended', 'No Show', 'Cancelled',
    'Waitlisted', 'Offered', 'Removed', 'Class Cancelled'
);

CREATE TYPE additional_attendee_status AS ENUM (
    'Registered', 'Attended', 'No Show', 'Cancelled'
);

CREATE TYPE service_appointment_attendee_status AS ENUM ('Enrolled', 'Unenrolled');

CREATE TYPE attendance_status AS ENUM ('Attended', 'No Show');

CREATE TYPE publishing_state AS ENUM ('InProgress', 'Failure', 'Success');

CREATE TYPE publishing_type AS ENUM ('Publish', 'Republish', 'Cancel');

CREATE TYPE external_event_type AS ENUM (
    'Scheduled', 'Rescheduled', 'Canceled', 'Edited', 'Closed'
);

CREATE TYPE participant_bin_status AS ENUM (
    'Queued', 'Processing', 'Completed', 'Failed'
);

CREATE TYPE note_status AS ENUM ('Pre', 'Post');

CREATE TYPE note_type AS ENUM ('Customer', 'Associate');

CREATE TYPE scheduling_role AS ENUM (
    'WFC 1', 'WFC 2', 'WFC 3', 'EC 1', 'EC 2', 'PEC'
);

CREATE TYPE experience_type AS ENUM ('ASSOCIATE', 'CLIENT');

CREATE TYPE client_segment AS ENUM (
    'Strategic', 'Select', 'Large', 'Advisor', 'Emerging', 'Mid', 'TEM',
    'Select-Concierge', 'Large-Concierge', 'Emerging-Concierge',
    'Mid-Concierge', 'Advisor-Concierge', 'Universal', 'Retail'
);

CREATE TYPE tem_vs_corp AS ENUM ('TEM', 'Corp');

CREATE TYPE closure_meeting_method AS ENUM ('PHONE', 'VIRTUAL', 'BRANCH');

CREATE TYPE territory_member_action AS ENUM ('Added', 'Removed', 'Updated');

-- ─────────────────────────────────────────────────────────────────────────────
-- HELPER: audit columns macro (applied per table below)
-- Every table has: created_at, updated_at, sf_id (Salesforce 18-char ID for sync)
-- ─────────────────────────────────────────────────────────────────────────────

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 1 — REFERENCE / CONFIGURATION TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- operating_hours  (SF: OperatingHours)
-- ---------------------------------------------------------------------------
CREATE TABLE operating_hours (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,             -- Salesforce record ID for sync
    name            VARCHAR(255) NOT NULL,
    time_zone       VARCHAR(100) NOT NULL,           -- IANA tz, e.g. 'America/New_York'
    oh_external_id  VARCHAR(255),                   -- OH_External_ID__c
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_territory  (SF: ServiceTerritory)
-- ---------------------------------------------------------------------------
CREATE TABLE service_territory (
    id                              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                           CHAR(18)    UNIQUE,
    name                            VARCHAR(255) NOT NULL,
    is_active                       BOOLEAN     NOT NULL DEFAULT TRUE,
    street                          VARCHAR(255),
    city                            VARCHAR(100),
    state                           VARCHAR(100),
    postal_code                     VARCHAR(20),
    operating_hours_id              UUID        REFERENCES operating_hours(id),
    branch_number                   VARCHAR(50),            -- Branch_Number__c
    check_availability_via_o365     BOOLEAN     NOT NULL DEFAULT FALSE,
    effective_start_date            DATE,                   -- temporary branch start
    effective_end_date              DATE,                   -- temporary branch end
    phone                           VARCHAR(30),
    shift_start_time                VARCHAR(20),
    shift_end_time                  VARCHAR(20),
    temporary_service_territory_id  UUID        REFERENCES service_territory(id),  -- self-ref
    st_external_id                  VARCHAR(255),
    created_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- time_slot  (SF: TimeSlot)
-- ---------------------------------------------------------------------------
CREATE TABLE time_slot (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    operating_hours_id  UUID        NOT NULL REFERENCES operating_hours(id) ON DELETE CASCADE,
    day_of_week         VARCHAR(15) NOT NULL,   -- 'Monday','Tuesday',…'Sunday'
    start_time          TIME        NOT NULL,
    end_time            TIME        NOT NULL,
    duration_minutes    INTEGER,                -- Duration__c
    ts_external_id      VARCHAR(255),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- engagement_channel_type  (SF: EngagementChannelType)
-- ---------------------------------------------------------------------------
CREATE TABLE engagement_channel_type (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    name                VARCHAR(255) NOT NULL,
    contact_point_type  VARCHAR(100),
    ect_external_id     VARCHAR(255),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- work_type  (SF: WorkType)
-- ---------------------------------------------------------------------------
CREATE TABLE work_type (
    id                              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                           CHAR(18)    UNIQUE,
    name                            VARCHAR(255) NOT NULL,
    duration_in_minutes             INTEGER,
    estimated_duration              NUMERIC(10,2),
    block_time_before_appointment   INTEGER DEFAULT 0,
    block_time_after_appointment    INTEGER DEFAULT 0,
    record_type_developer_name      VARCHAR(100),
    wt_external_id                  VARCHAR(255),
    created_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- work_type_group  (SF: WorkTypeGroup)
-- ---------------------------------------------------------------------------
CREATE TABLE work_type_group (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    name                VARCHAR(255) NOT NULL,
    duration_minutes    INTEGER,                -- DurationInMinutes__c
    experience_type     experience_type NOT NULL,
    wtg_external_id     VARCHAR(255),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- delivery_platform  (SF: DAP_Delivery_Platform__c)
-- ---------------------------------------------------------------------------
CREATE TABLE delivery_platform (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id       CHAR(18)    UNIQUE,
    name        VARCHAR(255) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- registration_platform  (SF: DAP_Registration_Platform__c)
-- ---------------------------------------------------------------------------
CREATE TABLE registration_platform (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,
    name            VARCHAR(255) NOT NULL,
    display_order   INTEGER DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- registration_delivery_mapping  (SF: DAP_Registration_Delivery_Mapping__c)
-- ---------------------------------------------------------------------------
CREATE TABLE registration_delivery_mapping (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                       CHAR(18)    UNIQUE,
    delivery_platform_id        UUID        REFERENCES delivery_platform(id),
    registration_platform_id    UUID        REFERENCES registration_platform(id),
    engagement_channel_type_id  UUID        REFERENCES engagement_channel_type(id),
    is_active                   BOOLEAN     NOT NULL DEFAULT TRUE,
    max_registration_limit      INTEGER,
    registration_limit_default  INTEGER,
    waitlist_limit_default      INTEGER,
    created_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- master_data_catalog  (SF: DAP_Master_Data_Catalog__c)
-- ---------------------------------------------------------------------------
CREATE TABLE master_data_catalog (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,
    name            VARCHAR(255) NOT NULL,
    mcc_id          VARCHAR(100),
    version         VARCHAR(50),
    event_category  VARCHAR(100),
    title           VARCHAR(255),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- scheduler_config  (SF: DAP_Scheduler_Config__mdt — custom metadata)
-- Seeded at deploy; treated as a static lookup table.
-- ---------------------------------------------------------------------------
CREATE TABLE scheduler_config (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    master_label            VARCHAR(255) NOT NULL,
    developer_name          VARCHAR(255) NOT NULL UNIQUE,
    assigned_business_roles TEXT,   -- comma-delimited
    service_territory_name  VARCHAR(255),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- scheduler_global  (SF: Dap_Scheduler_Global__c — hierarchy custom setting)
-- Single-row application config table.
-- ---------------------------------------------------------------------------
CREATE TABLE scheduler_global (
    id                                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    allow_appt_limitation_territory_level       BOOLEAN     DEFAULT FALSE,
    allow_same_day_multiple_appointments        BOOLEAN     DEFAULT FALSE,
    assign_permission_sets_batch_size           INTEGER,
    base_sf_url                                 TEXT,
    base_url                                    TEXT,
    csv_upload_limit                            INTEGER,
    customer_check_in_url                       TEXT,
    dap_core_email                              VARCHAR(255) NOT NULL,
    dap_dev_email                               VARCHAR(255) NOT NULL,
    dep_event_failure_max_retry                 INTEGER     NOT NULL DEFAULT 3,
    environment                                 VARCHAR(20),    -- prod/qa/dev
    notification_callouts_per_future            INTEGER     NOT NULL DEFAULT 10,
    notification_failure_max_retry              INTEGER     NOT NULL DEFAULT 3,
    notification_throttle_limit                 INTEGER     NOT NULL DEFAULT 50,
    notifications_per_queueable                 INTEGER     NOT NULL DEFAULT 10,
    publish_events_failure_max_retry            INTEGER     NOT NULL DEFAULT 3,
    publish_events_per_queueable                INTEGER     NOT NULL DEFAULT 10,
    publish_platform_events                     BOOLEAN     DEFAULT TRUE,
    qualtrics_survey_basepath                   TEXT,
    shift_ic_auto_batch_size                    INTEGER,
    shift_rc_auto_batch_size                    INTEGER,
    skill_endpoint_path                         TEXT,
    sra_create_batch_size                       INTEGER     NOT NULL DEFAULT 200,
    ups_callout_failure_max_retry               INTEGER     NOT NULL DEFAULT 3,
    ups_event_publish_callout_per_future        INTEGER     NOT NULL DEFAULT 5,
    ups_evt_pub_records_per_queueable           INTEGER     NOT NULL DEFAULT 10,
    wepa_number_of_days_for_availability        INTEGER,
    wepa_proximity_limit                        NUMERIC(10,2),  -- miles radius
    wepa_scheduling_policy                      VARCHAR(255),
    wepa_workshop_edl_batch_size                INTEGER,
    wepa_workshop_task_batch_size               INTEGER,
    microsoft_graph_api_get_eac_ad_group_uri    TEXT,
    microsoft_graph_api_get_schedule_uri        TEXT,
    created_at                                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    CONSTRAINT single_row CHECK (id = id)       -- enforced by app layer (only one row)
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 2 — PEOPLE / RESOURCE TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- sf_user  (SF: User — denormalized fields used by scheduler)
-- ---------------------------------------------------------------------------
CREATE TABLE sf_user (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    corp_id                 VARCHAR(50)  UNIQUE,    -- A_Badge_Number__c
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    email                   VARCHAR(255),
    time_zone_sid_key       VARCHAR(100),           -- IANA timezone
    branch_number           VARCHAR(50),
    business_role           VARCHAR(100),
    site                    VARCHAR(100),
    acr_work_location_code  VARCHAR(50),
    title                   VARCHAR(100),
    is_active               BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- account  (SF: Account — customer / plan sponsor)
-- ---------------------------------------------------------------------------
CREATE TABLE account (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    first_name              VARCHAR(100),
    last_name               VARCHAR(100),
    mid                     VARCHAR(50),            -- Mid__c
    party_id                VARCHAR(50),            -- PartyId__c
    member_mid              VARCHAR(50),            -- Member_Mid__c
    prospect_id             VARCHAR(50),            -- Prospect_Id__c
    legacy_company_id       VARCHAR(50),            -- Legacy_Company_ID__c
    person_mailing_postal_code VARCHAR(20),
    campaign_eligible       BOOLEAN,
    preferred_vle           VARCHAR(100),
    target_client_segment   client_segment,
    tem_vs_corp             tem_vs_corp,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- lead  (SF: Lead — prospect customer)
-- ---------------------------------------------------------------------------
CREATE TABLE lead (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    email               VARCHAR(255),
    phone               VARCHAR(30),
    communication_zip   VARCHAR(20),    -- Communication_Zip__c
    is_converted        BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_resource  (SF: ServiceResource — financial advisor)
-- ---------------------------------------------------------------------------
CREATE TABLE service_resource (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,
    name            VARCHAR(255) NOT NULL,
    related_user_id UUID        REFERENCES sf_user(id),     -- RelatedRecordId → User
    is_active       BOOLEAN     NOT NULL DEFAULT TRUE,
    home_location   GEOGRAPHY(POINT, 4326),                 -- Home_Address__c (PostGIS)
    preferred_name  VARCHAR(100),
    scheduling_role scheduling_role,
    sr_external_id  VARCHAR(255),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- skill  (SF: Skill — standard object referenced by ServiceResourceSkill)
-- ---------------------------------------------------------------------------
CREATE TABLE skill (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id       CHAR(18)    UNIQUE,
    name        VARCHAR(255) NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_resource_skill  (SF: ServiceResourceSkill — junction)
-- ---------------------------------------------------------------------------
CREATE TABLE service_resource_skill (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    service_resource_id UUID        NOT NULL REFERENCES service_resource(id) ON DELETE CASCADE,
    skill_id            UUID        NOT NULL REFERENCES skill(id),
    skill_level         NUMERIC(5,2),
    effective_start_date DATE,
    effective_end_date   DATE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (service_resource_id, skill_id)
);

-- ---------------------------------------------------------------------------
-- service_territory_member  (SF: ServiceTerritoryMember — junction)
-- ---------------------------------------------------------------------------
CREATE TABLE service_territory_member (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_resource_id     UUID        NOT NULL REFERENCES service_resource(id) ON DELETE CASCADE,
    service_territory_id    UUID        NOT NULL REFERENCES service_territory(id) ON DELETE CASCADE,
    territory_type          territory_member_type NOT NULL DEFAULT 'P',
    effective_start_date    DATE,
    effective_end_date      DATE,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    UNIQUE (service_resource_id, service_territory_id)
);

-- ---------------------------------------------------------------------------
-- shift  (SF: Shift — advisor shift schedule)
-- ---------------------------------------------------------------------------
CREATE TABLE shift (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    service_resource_id UUID        NOT NULL REFERENCES service_resource(id),
    start_time          TIMESTAMPTZ  NOT NULL,
    end_time            TIMESTAMPTZ  NOT NULL,
    status              VARCHAR(50),
    s_external_id       VARCHAR(255),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- resource_alignment  (SF: DAP_Resource_Alignment__c)
-- Links advisor (ServiceResource) to plan sponsor (Account)
-- ---------------------------------------------------------------------------
CREATE TABLE resource_alignment (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    plan_sponsor_id     UUID        REFERENCES account(id),
    service_resource_id UUID        REFERENCES service_resource(id),
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 3 — APPOINTMENT CORE TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- event_request  (SF: DAP_Event_Request__c)
-- Pre-appointment scheduling request — must exist before ServiceAppointment
-- ---------------------------------------------------------------------------
CREATE TABLE event_request (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    name                VARCHAR(255),
    event_date          DATE,
    service_resource_id UUID        REFERENCES service_resource(id),
    start_date          DATE,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_appointment  (SF: ServiceAppointment — THE core scheduling object)
-- ---------------------------------------------------------------------------
CREATE TABLE service_appointment (
    id                              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                           CHAR(18)        UNIQUE,

    -- Core scheduling fields
    work_type_id                    UUID            REFERENCES work_type(id),
    service_territory_id            UUID            REFERENCES service_territory(id),
    engagement_channel_type_id      UUID            REFERENCES engagement_channel_type(id),
    owner_user_id                   UUID            REFERENCES sf_user(id),
    event_owner_user_id             UUID            REFERENCES sf_user(id),
    record_type_developer_name      VARCHAR(100),   -- e.g. 'WEPA_Scheduling'

    -- Customer linkage (polymorphic ParentRecord → Account or Lead)
    parent_account_id               UUID            REFERENCES account(id),
    parent_lead_id                  UUID            REFERENCES lead(id),
    parent_record_type              VARCHAR(20),    -- 'Account' or 'Lead'

    -- Foreign platform references
    delivery_platform_id            UUID            REFERENCES delivery_platform(id),
    registration_platform_id        UUID            REFERENCES registration_platform(id),
    master_data_catalog_id          UUID            REFERENCES master_data_catalog(id),
    event_request_id                UUID            REFERENCES event_request(id),

    -- Schedule timing
    sched_start_time                TIMESTAMPTZ     NOT NULL,
    sched_end_time                  TIMESTAMPTZ     NOT NULL,
    duration_in_minutes             INTEGER,
    duration                        NUMERIC(10,2),
    due_date                        TIMESTAMPTZ,

    -- Status and classification
    status                          appointment_status  NOT NULL DEFAULT 'Scheduled',
    appointment_mode                appointment_mode,
    appointment_type                appointment_type,
    event_type                      event_type,
    language                        language_type,
    named_resource                  named_resource_type,
    registration_system             registration_system,
    closure_meeting_method          closure_meeting_method,

    -- Subject / description
    subject                         VARCHAR(500),
    service_note                    TEXT,           -- rep notes
    comments                        TEXT,
    customer_notes                  TEXT,
    closure_notes                   TEXT,
    reschedule_comments             TEXT,

    -- Contact / location
    street                          VARCHAR(255),
    city                            VARCHAR(100),
    state                           VARCHAR(100),
    postal_code                     VARCHAR(20),
    country                         VARCHAR(100),
    address_line_2                  VARCHAR(255),
    email                           VARCHAR(255),
    phone                           VARCHAR(30),
    scheduled_time_zone             VARCHAR(100),
    customer_notification_timezone  VARCHAR(100),

    -- Cancellation
    cancellation_reason             TEXT,
    cancellation_time               TIMESTAMPTZ,
    cancelled_by                    TEXT,
    cancelled_by_corp_id            TEXT,
    cancelled_by_json               TEXT,           -- JSON array when multiple

    -- Closure
    closed_by                       VARCHAR(100),

    -- Registration / capacity
    registration_limit              INTEGER,
    waitlist_limit                  INTEGER,
    registration_url                TEXT,
    registration_proxy_url          TEXT,
    registration_post_login_url     TEXT,
    num_of_additional_attendees     INTEGER         DEFAULT 0,
    participant_registrations_count INTEGER         DEFAULT 0,  -- maintained via trigger

    -- Virtual meeting
    virtual_appointment_link        TEXT,
    direct_join_url                 TEXT,
    on_demand_url                   TEXT,
    on_demand_url_expiry_date       DATE,
    vle                             VARCHAR(100),

    -- Survey
    survey_link                     TEXT,

    -- Advisor / resource references (denormalized for fast reads — duplicates AssignedResource)
    assigned_resources              TEXT,           -- "PRIMARY||srId,SECONDARY||srId"
    additional_resources_eng_channels TEXT,         -- "srId||VIRTUAL,…"

    -- Creator tracking
    appointment_creator_corp_id     VARCHAR(50),
    appointment_source              VARCHAR(100),

    -- Meeting reasons
    meeting_reasons                 TEXT,           -- pipe-delimited

    -- Financial
    opportunity_amount              NUMERIC(18,2),

    -- QR / check-in
    is_qr_code_active               BOOLEAN         DEFAULT FALSE,

    -- Rescheduling chain
    original_appointment_id         VARCHAR(50),    -- SF ID of prior appointment

    -- UPS / EDL
    ups_failure_reason              TEXT,

    -- Event / workshop dates
    event_due_date                  DATE,

    -- Customer status
    customer_status                 customer_status,

    created_at                      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_parent_record CHECK (
        (parent_account_id IS NOT NULL AND parent_lead_id IS NULL)
        OR (parent_lead_id IS NOT NULL AND parent_account_id IS NULL)
        OR (parent_account_id IS NULL AND parent_lead_id IS NULL)
    )
);

-- ---------------------------------------------------------------------------
-- assigned_resource  (SF: AssignedResource — junction SA ↔ ServiceResource)
-- ---------------------------------------------------------------------------
CREATE TABLE assigned_resource (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,
    service_resource_id     UUID        NOT NULL REFERENCES service_resource(id),
    is_primary_resource     BOOLEAN     NOT NULL DEFAULT FALSE,
    is_required_resource    BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_appointment_attendee  (SF: ServiceAppointmentAttendee)
-- Additional household members / co-attendees on a 1:1 appointment
-- ---------------------------------------------------------------------------
CREATE TABLE service_appointment_attendee (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,
    -- Polymorphic attendee: Account or Lead
    attendee_account_id     UUID        REFERENCES account(id),
    attendee_lead_id        UUID        REFERENCES lead(id),
    email                   VARCHAR(255),
    status                  service_appointment_attendee_status DEFAULT 'Enrolled',
    attendance_status       attendance_status,
    relationship            VARCHAR(100),   -- 'Spouse', 'Dependent', etc.
    send_edit_confirmation  BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- appointment_note  (SF: Dap_Service_Appointment_Note__c)
-- Pre/post meeting notes
-- ---------------------------------------------------------------------------
CREATE TABLE appointment_note (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,
    detail                  TEXT,
    status                  note_status NOT NULL,
    note_type               note_type   NOT NULL,
    submitter_corp_id       VARCHAR(50),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 4 — 1:MANY EVENT / WORKSHOP TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- event_audience  (SF: DAP_Event_Audience__c)
-- Target audience (plan sponsor / plan) for a 1:Many workshop
-- ---------------------------------------------------------------------------
CREATE TABLE event_audience (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        REFERENCES service_appointment(id),
    plan_sponsor_id         UUID        NOT NULL REFERENCES account(id),
    plan_id                 VARCHAR(50),            -- external Plan ID (no local table yet)
    product_code            VARCHAR(50),
    target_audience_unique_id VARCHAR(255),
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- event_participant  (SF: DAP_Event_Participant__c)
-- Registrant for a 1:Many workshop — MasterDetail child of ServiceAppointment
-- ---------------------------------------------------------------------------
CREATE TABLE event_participant (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                       CHAR(18)    UNIQUE,
    service_appointment_id      UUID        NOT NULL REFERENCES service_appointment(id) ON DELETE CASCADE,
    account_id                  UUID        REFERENCES account(id),
    lead_id                     UUID        REFERENCES lead(id),
    customer_id_type            VARCHAR(20),        -- MID / MEMBER / PROSPECT
    external_id                 VARCHAR(255),
    meeting_method              meeting_method  NOT NULL,
    notification_email          VARCHAR(255),
    notification_phone          VARCHAR(30),
    notification_timezone       VARCHAR(100),
    participant_notes           TEXT,
    referrer_corp_id            VARCHAR(50),
    registrant_corp_id          VARCHAR(50),
    rep_notes                   TEXT,
    status                      participant_status,
    cancelled_by                TEXT,
    cancelled_by_corp_id        TEXT,
    created_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- event_additional_attendee  (SF: DAP_Event_Additional_Attendee__c)
-- Household attendees linked to an event_participant
-- ---------------------------------------------------------------------------
CREATE TABLE event_additional_attendee (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    event_participant_id UUID       NOT NULL REFERENCES event_participant(id) ON DELETE CASCADE,
    account_id          UUID        REFERENCES account(id),
    lead_id             UUID        REFERENCES lead(id),
    first_name          VARCHAR(100),
    last_name           VARCHAR(100),
    notification_email  VARCHAR(255),
    relationship        VARCHAR(100),
    status              additional_attendee_status,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 5 — NOTIFICATION & INTEGRATION TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- notification_record  (SF: DAP_Notification_Record__c)
-- ---------------------------------------------------------------------------
CREATE TABLE notification_record (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        NOT NULL REFERENCES service_appointment(id),
    event_participant_id    UUID        REFERENCES event_participant(id),
    old_service_resource_id UUID        REFERENCES service_resource(id),
    channel                 notification_channel,
    event_type              event_type,
    is_manual               BOOLEAN     NOT NULL DEFAULT FALSE,
    notify_at               TIMESTAMPTZ,
    request_payload         JSONB,
    response_payload        JSONB,
    response_status_code    INTEGER,
    retry_count             INTEGER     NOT NULL DEFAULT 0,
    status                  notification_status NOT NULL DEFAULT 'Pending',
    tracking_id             VARCHAR(255),
    notification_type       notification_type,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- publishing_event_record  (SF: DAP_Publishing_Event_Record__c)
-- UPS (Universal Publishing Service) publishing tracking
-- ---------------------------------------------------------------------------
CREATE TABLE publishing_event_record (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_id  UUID        REFERENCES service_appointment(id),
    failure_reason          TEXT,
    failure_status_code     VARCHAR(50),
    fsreqid                 VARCHAR(255),
    request_payload         JSONB,
    response_payload        JSONB,
    response_status_code    INTEGER,
    retry_count             INTEGER     NOT NULL DEFAULT 0,
    state                   publishing_state,
    publish_type            publishing_type,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- external_event_record  (SF: DAP_External_Event_Record__c)
-- Outbound event callout tracking (UPS/EDL)
-- ---------------------------------------------------------------------------
CREATE TABLE external_event_record (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    service_appointment_sf_id VARCHAR(50) NOT NULL,   -- text ref (matches SF pattern)
    service_appointment_id  UUID        REFERENCES service_appointment(id),
    error_code              VARCHAR(100),
    error_response          TEXT,
    event_received          BOOLEAN     NOT NULL DEFAULT FALSE,
    event_type              external_event_type NOT NULL,
    external_request        JSONB,
    fsreqid                 VARCHAR(255),
    last_sent               TIMESTAMPTZ,
    platform_event_id       VARCHAR(255),
    requests_sent           INTEGER     NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- edl_event_record  (SF: DAP_Event_Appointment_EDL_Record__c)
-- ---------------------------------------------------------------------------
CREATE TABLE edl_event_record (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                       CHAR(18)    UNIQUE,
    service_appointment_sf_id   VARCHAR(50)  NOT NULL,
    service_appointment_id      UUID        REFERENCES service_appointment(id),
    event_request_payload       JSONB,
    event_type                  event_type,
    created_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_appointment_event_outbox  (SF: DAP_Service_Appointment_Event__e platform event)
-- Outbox pattern: rows published to SNS/SQS/Kinesis by a poller
-- ---------------------------------------------------------------------------
CREATE TABLE service_appointment_event_outbox (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    service_appointment_id  UUID        REFERENCES service_appointment(id),
    sf_appointment_id       VARCHAR(50),
    status                  appointment_status,
    sched_start_time        TIMESTAMPTZ,
    sched_end_time          TIMESTAMPTZ,
    published               BOOLEAN     NOT NULL DEFAULT FALSE,
    published_at            TIMESTAMPTZ,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 6 — CONSTRAINT / CAPACITY TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- max_appointment_per_day_constraint  (SF: DAP_Max_Appointment_Per_Day_Constraint__c)
-- ---------------------------------------------------------------------------
CREATE TABLE max_appointment_per_day_constraint (
    id                              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                           CHAR(18)    UNIQUE,
    max_appointment_per_day         INTEGER,
    max_external_appointment_per_day INTEGER,
    max_internal_appointment_per_day INTEGER,
    created_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- max_appointment_constraint_member  (SF: DAP_Max_Appointment_Constraint_Member__c)
-- ---------------------------------------------------------------------------
CREATE TABLE max_appointment_constraint_member (
    id                                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                                   CHAR(18)    UNIQUE,
    max_appointment_per_day_constraint_id   UUID        NOT NULL
        REFERENCES max_appointment_per_day_constraint(id) ON DELETE CASCADE,
    service_territory_id                    UUID        REFERENCES service_territory(id),
    applicable_titles                       TEXT,       -- comma-delimited job titles
    effective_start_date                    DATE,
    effective_end_date                      DATE,
    created_at                              TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 7 — OPTIMIZATION / ANALYTICS TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- resource_optimization_output  (SF: DAP_Resource_Optimization_Output__c)
-- ---------------------------------------------------------------------------
CREATE TABLE resource_optimization_output (
    id                              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                           CHAR(18)    UNIQUE,
    service_appointment_id          UUID        REFERENCES service_appointment(id),
    event_request_sf_id             VARCHAR(50),
    assigned_resource_id            UUID        REFERENCES service_resource(id),
    recommended_resource_id         UUID        REFERENCES service_resource(id),
    date_of_optimization            DATE,
    date_of_service_appointment     DATE,
    datetime_of_service_appointment TIMESTAMPTZ,
    time_of_service_appointment     VARCHAR(20),
    recommendation_reason           TEXT,
    created_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 8 — OPERATIONAL / AUDIT TABLES
-- ═════════════════════════════════════════════════════════════════════════════

-- ---------------------------------------------------------------------------
-- appointment_action_failure  (SF: DAP_Appointment_Action_Failures__c)
-- Error / retry tracking for failed appointment DML actions
-- ---------------------------------------------------------------------------
CREATE TABLE appointment_action_failure (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,
    action_handler  VARCHAR(255),
    before_state    JSONB,
    after_state     JSONB,
    error_datetime  TIMESTAMPTZ,
    is_resolved     BOOLEAN     NOT NULL DEFAULT FALSE,
    latest_error    TEXT,
    resolved_datetime TIMESTAMPTZ,
    retried_by      VARCHAR(50),
    retry_count     INTEGER     NOT NULL DEFAULT 0,
    source_action   VARCHAR(50),    -- Create, Cancel, Reschedule
    source_id       VARCHAR(50),    -- ServiceAppointment SF ID
    source          VARCHAR(100),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- service_territory_member_history  (SF: DAP_ServiceTerritoryMember_History__c)
-- Audit trail for resource↔territory assignment changes
-- ---------------------------------------------------------------------------
CREATE TABLE service_territory_member_history (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id                   CHAR(18)    UNIQUE,
    action                  territory_member_action NOT NULL,
    service_resource_sf_id  VARCHAR(50) NOT NULL,
    service_territory_sf_id VARCHAR(50) NOT NULL,
    service_resource_id     UUID        REFERENCES service_resource(id),
    service_territory_id    UUID        REFERENCES service_territory(id),
    updated_by_corp_id      VARCHAR(50) NOT NULL,
    updated_field           VARCHAR(100),
    old_value               TEXT,
    new_value               TEXT,
    created_at              TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- scheduler_log  (SF: DAP_Scheduler_Log__c)
-- Application-level logging
-- ---------------------------------------------------------------------------
CREATE TABLE scheduler_log (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id       CHAR(18)    UNIQUE,
    log_source  VARCHAR(255),
    message     TEXT,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- scheduled_job_run_tracker  (SF: Dap_Scheduled_Jobs_Run_Tracker__c)
-- Tracks last successful run per scheduled batch job
-- ---------------------------------------------------------------------------
CREATE TABLE scheduled_job_run_tracker (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id               CHAR(18)    UNIQUE,
    job_name            VARCHAR(255) NOT NULL UNIQUE,
    last_successful_run TIMESTAMPTZ,
    created_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- participant_bin  (SF: DAP_Participant_bin__c)
-- Chunked async processing bins for bulk participant registration
-- ---------------------------------------------------------------------------
CREATE TABLE participant_bin (
    id              UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sf_id           CHAR(18)    UNIQUE,
    job_id          VARCHAR(255),
    participant_bin JSONB,          -- array of participant IDs
    retry_count     INTEGER     NOT NULL DEFAULT 0,
    run_id          VARCHAR(255),
    sequence_number INTEGER,
    status          participant_bin_status NOT NULL DEFAULT 'Queued',
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- crt_settings  (SF: DAP_CRT_Settings__c — hierarchy custom setting)
-- CRT email notification configuration
-- ---------------------------------------------------------------------------
CREATE TABLE crt_settings (
    id                          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    dap_crt_email_cc            TEXT        NOT NULL,
    dap_crt_email_to            TEXT        NOT NULL,
    number_of_days_for_review   INTEGER     NOT NULL DEFAULT 30,
    review_batch_size           INTEGER     NOT NULL DEFAULT 200,
    created_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at                  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 9 — INDEXES (query patterns from Apex audit)
-- ═════════════════════════════════════════════════════════════════════════════

-- service_appointment — primary query patterns
CREATE INDEX idx_sa_sched_time
    ON service_appointment (sched_start_time, sched_end_time);

CREATE INDEX idx_sa_status
    ON service_appointment (status)
    WHERE status != 'Canceled';

CREATE INDEX idx_sa_parent_account
    ON service_appointment (parent_account_id)
    WHERE parent_account_id IS NOT NULL;

CREATE INDEX idx_sa_parent_lead
    ON service_appointment (parent_lead_id)
    WHERE parent_lead_id IS NOT NULL;

CREATE INDEX idx_sa_territory
    ON service_appointment (service_territory_id);

CREATE INDEX idx_sa_engagement_channel
    ON service_appointment (engagement_channel_type_id);

CREATE INDEX idx_sa_record_type
    ON service_appointment (record_type_developer_name);

CREATE INDEX idx_sa_created_at
    ON service_appointment (created_at DESC);

-- assigned_resource — used in conflict detection GROUP BY queries
CREATE INDEX idx_ar_service_resource
    ON assigned_resource (service_resource_id);

CREATE INDEX idx_ar_service_appointment
    ON assigned_resource (service_appointment_id);

-- service_territory_member — advisor→branch lookups
CREATE INDEX idx_stm_resource
    ON service_territory_member (service_resource_id);

CREATE INDEX idx_stm_territory
    ON service_territory_member (service_territory_id);

-- notification_record — scheduled notification poller
CREATE INDEX idx_notif_notify_at_status
    ON notification_record (notify_at, status)
    WHERE status = 'Pending';

-- event_participant — registration lookups
CREATE INDEX idx_ep_service_appointment
    ON event_participant (service_appointment_id);

CREATE INDEX idx_ep_status
    ON event_participant (status);

-- service_resource — corp_id → advisor lookups
CREATE INDEX idx_sr_corp_id
    ON sf_user (corp_id);

-- geospatial — proximity advisor search (PostGIS)
CREATE INDEX idx_sr_home_location
    ON service_resource USING GIST (home_location);

-- outbox — unpublished events poller
CREATE INDEX idx_outbox_unpublished
    ON service_appointment_event_outbox (created_at)
    WHERE published = FALSE;

-- action failures — retry queue
CREATE INDEX idx_aaf_unresolved
    ON appointment_action_failure (error_datetime)
    WHERE is_resolved = FALSE;

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 10 — TRIGGERS (maintain derived / denormalized columns)
-- ═════════════════════════════════════════════════════════════════════════════

-- updated_at auto-maintenance
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

DO $$
DECLARE
    tbl TEXT;
BEGIN
    FOREACH tbl IN ARRAY ARRAY[
        'operating_hours','service_territory','time_slot','engagement_channel_type',
        'work_type','work_type_group','delivery_platform','registration_platform',
        'registration_delivery_mapping','master_data_catalog','scheduler_config',
        'scheduler_global','sf_user','account','lead','service_resource','skill',
        'service_resource_skill','service_territory_member','shift','resource_alignment',
        'event_request','service_appointment','assigned_resource',
        'service_appointment_attendee','appointment_note','event_audience',
        'event_participant','event_additional_attendee','notification_record',
        'publishing_event_record','external_event_record','edl_event_record',
        'max_appointment_per_day_constraint','max_appointment_constraint_member',
        'resource_optimization_output','appointment_action_failure',
        'scheduler_log','scheduled_job_run_tracker','participant_bin','crt_settings'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%s_updated_at
             BEFORE UPDATE ON %s
             FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at()',
            tbl, tbl
        );
    END LOOP;
END;
$$;

-- participant_registrations_count maintenance
CREATE OR REPLACE FUNCTION fn_update_participant_count()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE service_appointment
        SET participant_registrations_count = participant_registrations_count + 1
        WHERE id = NEW.service_appointment_id;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE service_appointment
        SET participant_registrations_count = participant_registrations_count - 1
        WHERE id = OLD.service_appointment_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_event_participant_count
AFTER INSERT OR DELETE ON event_participant
FOR EACH ROW EXECUTE FUNCTION fn_update_participant_count();

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 11 — VIEWS (common read patterns)
-- ═════════════════════════════════════════════════════════════════════════════

-- Full appointment view with all joins (mirrors SF APPOINTMENT_QUERY constant)
CREATE VIEW v_appointment_full AS
SELECT
    sa.id,
    sa.sf_id,
    sa.sched_start_time,
    sa.sched_end_time,
    sa.duration_in_minutes,
    sa.status,
    sa.appointment_mode,
    sa.appointment_type,
    sa.event_type,
    sa.subject,
    sa.service_note,
    sa.comments,
    sa.customer_notes,
    sa.cancellation_reason,
    sa.meeting_reasons,
    sa.scheduled_time_zone,
    sa.language,
    sa.record_type_developer_name,
    -- Territory
    st.name                     AS territory_name,
    st.branch_number            AS branch_number,
    -- Work type
    wt.name                     AS work_type_name,
    wt.duration_in_minutes      AS work_type_duration,
    -- Channel
    ect.name                    AS engagement_channel_name,
    -- Customer (account path)
    a.sf_id                     AS account_sf_id,
    a.first_name                AS account_first_name,
    a.last_name                 AS account_last_name,
    -- Customer (lead path)
    l.sf_id                     AS lead_sf_id,
    l.first_name                AS lead_first_name,
    l.last_name                 AS lead_last_name,
    -- Owner
    u.corp_id                   AS owner_corp_id,
    u.first_name                AS owner_first_name,
    u.last_name                 AS owner_last_name,
    sa.created_at,
    sa.updated_at
FROM service_appointment sa
LEFT JOIN service_territory      st  ON st.id  = sa.service_territory_id
LEFT JOIN work_type              wt  ON wt.id  = sa.work_type_id
LEFT JOIN engagement_channel_type ect ON ect.id = sa.engagement_channel_type_id
LEFT JOIN account                a   ON a.id   = sa.parent_account_id
LEFT JOIN lead                   l   ON l.id   = sa.parent_lead_id
LEFT JOIN sf_user                u   ON u.id   = sa.owner_user_id;

-- Advisor schedule view: resource + territory + active appointments
CREATE VIEW v_advisor_schedule AS
SELECT
    sr.id                       AS service_resource_id,
    sr.sf_id                    AS service_resource_sf_id,
    sr.name                     AS advisor_name,
    u.corp_id                   AS corp_id,
    u.email                     AS advisor_email,
    st.id                       AS territory_id,
    st.name                     AS territory_name,
    st.branch_number,
    stm.territory_type,
    sa.id                       AS appointment_id,
    sa.sched_start_time,
    sa.sched_end_time,
    sa.status,
    sa.duration_in_minutes,
    ar.is_primary_resource
FROM service_resource sr
JOIN sf_user                u   ON u.id  = sr.related_user_id
JOIN service_territory_member stm ON stm.service_resource_id = sr.id
JOIN service_territory      st  ON st.id = stm.service_territory_id
LEFT JOIN assigned_resource ar  ON ar.service_resource_id = sr.id
LEFT JOIN service_appointment sa ON sa.id = ar.service_appointment_id
    AND sa.status != 'Canceled';

-- ═════════════════════════════════════════════════════════════════════════════
-- SECTION 12 — COMMENTS
-- ═════════════════════════════════════════════════════════════════════════════

COMMENT ON TABLE service_appointment IS
    'Core scheduling object. Mirrors SF ServiceAppointment. '
    'Parent customer is polymorphic: either parent_account_id (existing client) '
    'or parent_lead_id (prospect) — never both.';

COMMENT ON TABLE assigned_resource IS
    'Junction between service_appointment and service_resource. '
    'One primary advisor (is_primary_resource=true) plus optional secondary advisors.';

COMMENT ON TABLE service_appointment_event_outbox IS
    'Outbox table replacing SF platform event DAP_Service_Appointment_Event__e. '
    'A poller reads unpublished rows and pushes to SNS/SQS for downstream consumers.';

COMMENT ON TABLE scheduler_global IS
    'Single-row application config replacing SF Dap_Scheduler_Global__c hierarchy custom setting. '
    'Only one row should exist; enforce at the application layer.';

COMMENT ON COLUMN service_resource.home_location IS
    'PostGIS GEOGRAPHY(POINT) replacing SF geolocation compound field Home_Address__c. '
    'Used with ST_Distance() for WEPA proximity searches (WEPA_Proximity_Limit__c miles radius).';

COMMENT ON TABLE service_appointment_event_outbox IS
    'CDC outbox: insert a row here whenever a service_appointment status changes. '
    'A background worker polls WHERE published=false and publishes to SNS/EventBridge.';
