--liquibase formatted sql



--  DR Scheduler — extensions. Converted from Flyway V1__extensions.sql.
--  The migration DB user needs rds_superuser to create extensions (Aurora master user qualifies).
--changeset team:001-btree-gist
--comment: btree_gist backs the no-double-book EXCLUDE constraint (equality on service_resource_id + range overlap). REQUIRED.
CREATE EXTENSION IF NOT EXISTS btree_gist;
--rollback DROP EXTENSION IF EXISTS btree_gist;
--changeset team:001-pgcrypto
--comment: pgcrypto provides gen_random_uuid() for UUID PK defaults (core in PG13+, kept for portability).
CREATE EXTENSION IF NOT EXISTS pgcrypto;
--rollback DROP EXTENSION IF EXISTS pgcrypto;

-- NOTE: postgis is intentionally NOT enabled in Phase 1. Add it only when branch-proximity search is needed.
