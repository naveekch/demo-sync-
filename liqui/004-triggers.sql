--changeset team:004-fn-updated-at runOnChange:true splitStatements:false stripComments:false

--comment: generic updated_at maintenance

CREATE OR REPLACE FUNCTION fn_set_updated_at() RETURNS trigger AS $$

BEGIN

    NEW.updated_at := now();

    RETURN NEW;

END;

$$ LANGUAGE plpgsql;

--rollback DROP FUNCTION IF EXISTS fn_set_updated_at() CASCADE;



--changeset team:004-attach-updated-at splitStatements:false stripComments:false

--comment: attach the updated_at trigger to every table that has the column (scheduler_log excluded, append-only)

DO $$

DECLARE t text;

BEGIN

    FOREACH t IN ARRAY ARRAY[

        'customer','app_user','service_resource','work_type_group','appointment_scheduling_policy',

        'work_type','skill','service_resource_skill','work_type_required_skill','max_appointment_per_day_constraint',

        'service_territory_group','service_territory','operating_hours','time_slot','engagement_channel_type',

        'shift','service_appointment','assigned_resource','service_appointment_attendee','appointment_note',

        'service_appointment_event_outbox','notification_record','appointment_action_failure'

    ] LOOP

        EXECUTE format(

            'CREATE TRIGGER trg_%1$s_updated_at BEFORE UPDATE ON %1$s FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();',

            t);

    END LOOP;

END $$;

--rollback DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['customer','app_user','service_resource','work_type_group','appointment_scheduling_policy','work_type','skill','service_resource_skill','work_type_required_skill','max_appointment_per_day_constraint','service_territory_group','service_territory','operating_hours','time_slot','engagement_channel_type','shift','service_appointment','assigned_resource','service_appointment_attendee','appointment_note','service_appointment_event_outbox','notification_record','appointment_action_failure'] LOOP EXECUTE format('DROP TRIGGER IF EXISTS trg_%1$s_updated_at ON %1$s;', t); END LOOP; END $$;



--changeset team:004-fn-block-end runOnChange:true splitStatements:false stripComments:false

--comment: block_end_time = sched_end_time + work_type.buffer_minutes (BEFORE trigger, not a generated column because timestamptz+interval is only STABLE)

CREATE OR REPLACE FUNCTION fn_ar_set_block_end() RETURNS trigger AS $$

DECLARE

    v_buffer integer;

BEGIN

    SELECT wt.buffer_minutes

      INTO v_buffer

      FROM service_appointment sa

      JOIN work_type wt ON wt.id = sa.work_type_id

     WHERE sa.id = NEW.service_appointment_id;



    NEW.block_end_time := NEW.sched_end_time + make_interval(mins => COALESCE(v_buffer, 0));

    RETURN NEW;

END;

$$ LANGUAGE plpgsql;

--rollback DROP FUNCTION IF EXISTS fn_ar_set_block_end() CASCADE;



--changeset team:004-trg-block-end splitStatements:false stripComments:false

--comment: fire block_end computation on insert or when timing / appointment link changes

CREATE TRIGGER trg_ar_block_end

    BEFORE INSERT OR UPDATE OF sched_end_time, service_appointment_id

    ON assigned_resource

    FOR EACH ROW

    EXECUTE FUNCTION fn_ar_set_block_end();

--rollback DROP TRIGGER IF EXISTS trg_ar_block_end ON assigned_resource;



--changeset team:004-fn-sync-assigned runOnChange:true splitStatements:false stripComments:false

--comment: propagate reschedule / cancel / work-type change from service_appointment to its assigned_resource children in the same transaction

CREATE OR REPLACE FUNCTION fn_sa_sync_assigned() RETURNS trigger AS $$

DECLARE

    v_buffer integer;

BEGIN

    IF (NEW.sched_start_time IS DISTINCT FROM OLD.sched_start_time)

       OR (NEW.sched_end_time IS DISTINCT FROM OLD.sched_end_time)

       OR (NEW.status         IS DISTINCT FROM OLD.status)

       OR (NEW.work_type_id   IS DISTINCT FROM OLD.work_type_id) THEN



        SELECT buffer_minutes INTO v_buffer FROM work_type WHERE id = NEW.work_type_id;



        UPDATE assigned_resource ar

           SET sched_start_time = NEW.sched_start_time,

               sched_end_time   = NEW.sched_end_time,

               block_end_time   = NEW.sched_end_time + make_interval(mins => COALESCE(v_buffer, 0)),

               status           = NEW.status

         WHERE ar.service_appointment_id = NEW.id;

    END IF;

    RETURN NEW;

END;

$$ LANGUAGE plpgsql;

--rollback DROP FUNCTION IF EXISTS fn_sa_sync_assigned() CASCADE;



--changeset team:004-trg-sync-assigned splitStatements:false stripComments:false

--comment: AFTER UPDATE sync so the EXCLUDE constraint always sees the current block range and status

CREATE TRIGGER trg_sa_sync_assigned

    AFTER UPDATE ON service_appointment

    FOR EACH ROW

    EXECUTE FUNCTION fn_sa_sync_assigned();

--rollback DROP TRIGGER IF EXISTS trg_sa_sync_assigned ON service_appointment;
