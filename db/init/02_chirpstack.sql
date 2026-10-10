-- Separate database on the shared Postgres server for ChirpStack (LoRaWAN).
-- Idempotent: \gexec only runs CREATE DATABASE when it doesn't exist yet.
SELECT 'CREATE DATABASE chirpstack'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'chirpstack')\gexec

\connect chirpstack
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS hstore;
