-- Central SIGINT Tool-kit database schema.
-- Runs automatically the first time the Postgres volume is created, and is
-- safe to re-run (./toolkit.sh migrate) because every statement is idempotent.

-- Every program ("module") that has ever connected to the bus.
CREATE TABLE IF NOT EXISTS modules (
    name        text PRIMARY KEY,
    kind        text,
    status      text        NOT NULL DEFAULT 'unknown',
    meta        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    first_seen  timestamptz NOT NULL DEFAULT now(),
    last_seen   timestamptz NOT NULL DEFAULT now()
);

-- Every data message published on sigint/<module>/data/<kind>.
CREATE TABLE IF NOT EXISTS events (
    id      bigserial   PRIMARY KEY,
    ts      timestamptz NOT NULL DEFAULT now(),
    module  text        NOT NULL,
    kind    text        NOT NULL,
    topic   text        NOT NULL,
    data    jsonb       NOT NULL
);
CREATE INDEX IF NOT EXISTS events_ts_idx          ON events (ts DESC);
CREATE INDEX IF NOT EXISTS events_module_ts_idx   ON events (module, ts DESC);
CREATE INDEX IF NOT EXISTS events_kind_ts_idx     ON events (kind, ts DESC);
CREATE INDEX IF NOT EXISTS events_data_idx        ON events USING gin (data jsonb_path_ops);

-- Shared key/value store so modules can keep config and state in one place.
CREATE TABLE IF NOT EXISTS kv (
    namespace   text        NOT NULL,
    key         text        NOT NULL,
    value       jsonb       NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (namespace, key)
);

-- Push every new event to LISTEN-ers on the 'sigint_events' channel.
-- NOTIFY payloads are capped at 8000 bytes, so large events are sent without
-- their data and listeners fetch the row by id.
CREATE OR REPLACE FUNCTION notify_event() RETURNS trigger AS $$
DECLARE
    payload text;
BEGIN
    payload := json_build_object(
        'id', NEW.id, 'ts', NEW.ts, 'module', NEW.module,
        'kind', NEW.kind, 'topic', NEW.topic, 'data', NEW.data)::text;
    IF octet_length(payload) > 7900 THEN
        payload := json_build_object(
            'id', NEW.id, 'ts', NEW.ts, 'module', NEW.module,
            'kind', NEW.kind, 'topic', NEW.topic, 'truncated', true)::text;
    END IF;
    PERFORM pg_notify('sigint_events', payload);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS events_notify ON events;
CREATE TRIGGER events_notify AFTER INSERT ON events
    FOR EACH ROW EXECUTE FUNCTION notify_event();
