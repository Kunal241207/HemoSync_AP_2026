-- =============================================================================
-- 🩸 HemoSync — Blood Inventory & Inter-Hospital Logistics Platform
-- 03. Audited & Finalized PostgreSQL 16+ Production Relational Schema
-- =============================================================================
-- Architecture   : Layered Modular Monolith / Relational OLTP Core
-- Normalization  : Boyce-Codd Normal Form (BCNF)
-- Clinical Rules : ISBT-128 Compliance • Deterministic Orthogonal Safety Gates
-- Engine Target  : PostgreSQL 16.0+
-- Deliverable    : dbms/03_schema.sql
-- =============================================================================

-- Enable standard UUID generation extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 1. ENUMERATION TYPES (DOMAIN CONTROL)
-- =============================================================================

DO $$ BEGIN
    CREATE TYPE "InstitutionType" AS ENUM ('HOSPITAL', 'BLOOD_BANK');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "VerificationStatus" AS ENUM ('PENDING', 'VERIFIED', 'REJECTED', 'SUSPENDED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "UserRole" AS ENUM ('PLATFORM_ADMIN', 'HOSPITAL_STAFF', 'BLOOD_BANK_STAFF');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "BloodComponentType" AS ENUM ('RED_BLOOD_CELLS', 'PLATELETS', 'PLASMA');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "AboGroup" AS ENUM ('A', 'B', 'AB', 'O');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "RhFactor" AS ENUM ('POSITIVE', 'NEGATIVE');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "TestingStatus" AS ENUM ('PENDING', 'PASSED', 'FAILED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "ReleaseStatus" AS ENUM ('QUARANTINED', 'RELEASED', 'REJECTED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "InventoryStatus" AS ENUM (
        'AVAILABLE', 'RESERVED', 'IN_TRANSFER', 'TRANSFERRED', 
        'USED', 'EXPIRED', 'DISCARDED', 'QUARANTINED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "RequestUrgency" AS ENUM ('ROUTINE', 'URGENT', 'EMERGENCY');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "RequestStatus" AS ENUM (
        'PENDING', 'VALIDATED', 'PARTIALLY_ALLOCATED', 'ALLOCATED', 
        'TRANSFER_PENDING', 'FULFILLED', 'CANCELLED', 'UNFULFILLED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "AllocationStatus" AS ENUM ('RESERVED', 'FULFILLED', 'CANCELLED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "TransferStatus" AS ENUM (
        'REQUESTED', 'APPROVED', 'REJECTED', 'RESERVED', 
        'DISPATCHED', 'RECEIVED', 'CANCELLED', 'FAILED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "AlertSeverity" AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "EventType" AS ENUM (
        'REGISTRATION', 'STATUS_CHANGE', 'DISPATCH', 'RECEIPT', 
        'DISPOSAL', 'QUARANTINE_APPLIED', 'TEST_COMPLETED', 
        'ALLOCATION_RESERVED', 'ALLOCATION_RELEASED'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "AuditAction" AS ENUM (
        'CREATE', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT', 
        'ALLOCATE', 'TRANSFER_REQUEST', 'TRANSFER_APPROVE', 
        'TRANSFER_DISPATCH', 'TRANSFER_RECEIVE', 'STATUS_CHANGE'
    );
EXCEPTION WHEN duplicate_object THEN null; END $$;

DO $$ BEGIN
    CREATE TYPE "AnomalyStatus" AS ENUM ('OPEN', 'ACKNOWLEDGED', 'DISMISSED', 'RESOLVED');
EXCEPTION WHEN duplicate_object THEN null; END $$;

-- =============================================================================
-- 2. FACILITY & IDENTITY MODULE
-- =============================================================================

-- Table: institutions
-- Stores registered and accredited hospitals and centralized blood banks.
CREATE TABLE IF NOT EXISTS "institutions" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "name" VARCHAR(255) NOT NULL,
    "type" "InstitutionType" NOT NULL,
    "address" TEXT NOT NULL,
    "latitude" DOUBLE PRECISION NOT NULL,
    "longitude" DOUBLE PRECISION NOT NULL,
    "license_number" VARCHAR(100) NOT NULL,
    "phone" VARCHAR(50),
    "email" VARCHAR(255),
    "verification_status" "VerificationStatus" NOT NULL DEFAULT 'PENDING',
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "institutions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "institutions_license_number_key" UNIQUE ("license_number"),
    CONSTRAINT "chk_institution_lat" CHECK ("latitude" BETWEEN -90.0 AND 90.0),
    CONSTRAINT "chk_institution_lng" CHECK ("longitude" BETWEEN -180.0 AND 180.0)
);

-- Table: users
-- Authorized medical staff, blood bank technicians, and platform administrators.
CREATE TABLE IF NOT EXISTS "users" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "institution_id" UUID,
    "name" VARCHAR(255) NOT NULL,
    "email" VARCHAR(255) NOT NULL,
    "password_hash" VARCHAR(255) NOT NULL,
    "role" "UserRole" NOT NULL,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "users_email_key" UNIQUE ("email")
);

-- Table: system_settings
-- System-wide platform configurations and algorithm parameters.
CREATE TABLE IF NOT EXISTS "system_settings" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "key" VARCHAR(100) NOT NULL,
    "value" TEXT NOT NULL,
    "description" TEXT,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "system_settings_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "system_settings_key_key" UNIQUE ("key")
);

-- =============================================================================
-- 3. INVENTORY MANAGEMENT MODULE
-- =============================================================================

-- Table: blood_units
-- Individual physical blood component containers (ISBT-128 compliance).
-- Enforces segregated orthogonal safety states (testing, release, and inventory).
CREATE TABLE IF NOT EXISTS "blood_units" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "institution_id" UUID NOT NULL,
    "unit_code" VARCHAR(50) NOT NULL,
    "component_type" "BloodComponentType" NOT NULL,
    "abo_group" "AboGroup" NOT NULL,
    "rh_factor" "RhFactor" NOT NULL,
    "collection_date" TIMESTAMPTZ NOT NULL,
    "expiry_date" TIMESTAMPTZ NOT NULL,
    "volume_ml" INTEGER NOT NULL,
    "testing_status" "TestingStatus" NOT NULL DEFAULT 'PENDING',
    "release_status" "ReleaseStatus" NOT NULL DEFAULT 'QUARANTINED',
    "inventory_status" "InventoryStatus" NOT NULL DEFAULT 'AVAILABLE',
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "blood_units_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "blood_units_unit_code_key" UNIQUE ("unit_code"),
    CONSTRAINT "chk_blood_unit_volume_positive" CHECK ("volume_ml" > 0),
    CONSTRAINT "chk_blood_unit_chronological_dates" CHECK ("expiry_date" > "collection_date"),
    
    -- Clinical Safety Invariant: Contaminated or unreleased blood can NEVER be AVAILABLE
    CONSTRAINT "chk_blood_unit_availability_safety" CHECK (
        ("inventory_status" <> 'AVAILABLE') OR 
        ("testing_status" = 'PASSED' AND "release_status" = 'RELEASED')
    )
);

-- Table: inventory_events
-- Immutable chain-of-custody audit log tracking every physical status transition.
CREATE TABLE IF NOT EXISTS "inventory_events" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "blood_unit_id" UUID NOT NULL,
    "event_type" "EventType" NOT NULL,
    "previous_status" "InventoryStatus",
    "new_status" "InventoryStatus" NOT NULL,
    "actor_id" UUID,
    "notes" TEXT,
    "timestamp" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "inventory_events_pkey" PRIMARY KEY ("id")
);

-- =============================================================================
-- 4. CLINICAL REQUESTS & ALLOCATIONS MODULE
-- =============================================================================

-- Table: blood_requests
-- Hospital clinical requisitions for emergency or routine transfusion units.
CREATE TABLE IF NOT EXISTS "blood_requests" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "hospital_id" UUID NOT NULL,
    "created_by_id" UUID NOT NULL,
    "requested_component" "BloodComponentType" NOT NULL,
    "requested_abo" "AboGroup" NOT NULL,
    "requested_rh" "RhFactor" NOT NULL,
    "requested_quantity" INTEGER NOT NULL,
    "urgency" "RequestUrgency" NOT NULL DEFAULT 'ROUTINE',
    "status" "RequestStatus" NOT NULL DEFAULT 'PENDING',
    "required_by" TIMESTAMPTZ NOT NULL,
    "reason" TEXT,
    "is_synthetic" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "blood_requests_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "chk_blood_requests_quantity_positive" CHECK ("requested_quantity" > 0)
);

-- Table: allocations
-- Resolves M:N relationship between Blood Requests and physical Blood Units.
CREATE TABLE IF NOT EXISTS "allocations" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "request_id" UUID NOT NULL,
    "blood_unit_id" UUID NOT NULL,
    "allocated_by_id" UUID NOT NULL,
    "status" "AllocationStatus" NOT NULL DEFAULT 'RESERVED',
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "allocations_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "allocations_request_unit_unique" UNIQUE ("request_id", "blood_unit_id")
);

-- Partial Unique Index: Guarantees a physical unit can only have ONE active RESERVED allocation
CREATE UNIQUE INDEX IF NOT EXISTS "allocations_active_reservation_unique_idx" 
ON "allocations"("blood_unit_id") 
WHERE "status" = 'RESERVED';

-- =============================================================================
-- 5. INTER-HOSPITAL LOGISTICS & TRANSFERS MODULE
-- =============================================================================

-- Table: transfers
-- Logistics shipment records tracking inter-facility transport workflows.
CREATE TABLE IF NOT EXISTS "transfers" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "source_institution_id" UUID NOT NULL,
    "destination_institution_id" UUID NOT NULL,
    "request_id" UUID,
    "status" "TransferStatus" NOT NULL DEFAULT 'REQUESTED',
    "approved_by_id" UUID,
    "dispatched_at" TIMESTAMPTZ,
    "received_at" TIMESTAMPTZ,
    "notes" TEXT,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "transfers_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "chk_transfer_distinct_facilities" CHECK ("source_institution_id" <> "destination_institution_id"),
    CONSTRAINT "chk_transfer_chronological_times" CHECK (
        "received_at" IS NULL OR "dispatched_at" IS NULL OR "received_at" >= "dispatched_at"
    )
);

-- Table: transfer_units
-- Associative shipment manifest linking physical blood units to transfer shipments.
CREATE TABLE IF NOT EXISTS "transfer_units" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "transfer_id" UUID NOT NULL,
    "blood_unit_id" UUID NOT NULL,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "transfer_units_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "transfer_units_transfer_unit_unique" UNIQUE ("transfer_id", "blood_unit_id")
);

-- =============================================================================
-- 6. MONITORING, FORECASTING & AUDIT MODULE
-- =============================================================================

-- Table: expiry_alerts
-- Automated risk warnings for blood units approaching shelf-life boundaries.
CREATE TABLE IF NOT EXISTS "expiry_alerts" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "blood_unit_id" UUID NOT NULL,
    "institution_id" UUID NOT NULL,
    "severity" "AlertSeverity" NOT NULL DEFAULT 'MEDIUM',
    "resolved" BOOLEAN NOT NULL DEFAULT false,
    "resolved_at" TIMESTAMPTZ,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "expiry_alerts_pkey" PRIMARY KEY ("id")
);

-- Partial Unique Index: Prevents duplicate active unresolved alerts for the same blood unit
CREATE UNIQUE INDEX IF NOT EXISTS "expiry_alerts_active_unit_unique_idx" 
ON "expiry_alerts"("blood_unit_id") 
WHERE "resolved" = false;

-- Table: notifications
-- User-facing alerts and operational communications.
CREATE TABLE IF NOT EXISTS "notifications" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "recipient_user_id" UUID NOT NULL,
    "institution_id" UUID,
    "type" VARCHAR(50) NOT NULL DEFAULT 'SYSTEM',
    "title" VARCHAR(255) NOT NULL,
    "message" TEXT NOT NULL,
    "metadata" JSONB,
    "read_at" TIMESTAMPTZ,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "notifications_pkey" PRIMARY KEY ("id")
);

-- Table: demand_forecasts
-- Statistical time-series demand projections per facility, component, and horizon.
CREATE TABLE IF NOT EXISTS "demand_forecasts" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "institution_id" UUID NOT NULL,
    "component_type" "BloodComponentType" NOT NULL,
    "abo_group" "AboGroup",
    "rh_factor" "RhFactor",
    "forecast_date" TIMESTAMPTZ NOT NULL,
    "horizon_days" INTEGER NOT NULL DEFAULT 7,
    "predicted_demand" DOUBLE PRECISION NOT NULL,
    "lower_bound" DOUBLE PRECISION NOT NULL,
    "upper_bound" DOUBLE PRECISION NOT NULL,
    "model_version" VARCHAR(50) NOT NULL DEFAULT 'v1.0-ewma',
    "metrics" JSONB,
    "generated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "demand_forecasts_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "chk_forecast_horizon_positive" CHECK ("horizon_days" > 0),
    CONSTRAINT "chk_forecast_demand_non_negative" CHECK ("predicted_demand" >= 0.0),
    CONSTRAINT "chk_forecast_bounds" CHECK ("lower_bound" <= "upper_bound")
);

-- Composite Unique Index: Prevents duplicate forecast series on identical dimensions
CREATE UNIQUE INDEX IF NOT EXISTS "demand_forecasts_series_unique_idx"
ON "demand_forecasts"("institution_id", "component_type", "forecast_date", "horizon_days", "model_version");

-- Table: audit_logs
-- Immutable compliance trail recording all operational actions.
-- Note: entity_id and entity_type form a documented polymorphic reference.
CREATE TABLE IF NOT EXISTS "audit_logs" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "actor_id" UUID,
    "institution_id" UUID,
    "entity_type" VARCHAR(100) NOT NULL,
    "entity_id" VARCHAR(100) NOT NULL,
    "action" "AuditAction" NOT NULL,
    "metadata" JSONB,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id")
);

-- Table: anomaly_events
-- Clinical demand and supply outlier events detected across the network.
CREATE TABLE IF NOT EXISTS "anomaly_events" (
    "id" UUID NOT NULL DEFAULT uuid_generate_v4(),
    "institution_id" UUID NOT NULL,
    "component_type" "BloodComponentType" NOT NULL,
    "date" TIMESTAMPTZ NOT NULL,
    "observed_value" DOUBLE PRECISION NOT NULL,
    "expected_min" DOUBLE PRECISION NOT NULL,
    "expected_max" DOUBLE PRECISION NOT NULL,
    "anomaly_type" VARCHAR(50) NOT NULL,
    "status" "AnomalyStatus" NOT NULL DEFAULT 'OPEN',
    "reason" TEXT NOT NULL,
    "model_version" VARCHAR(50) NOT NULL,
    "reviewed_by_id" UUID,
    "review_notes" TEXT,
    "reviewed_at" TIMESTAMPTZ,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "anomaly_events_pkey" PRIMARY KEY ("id")
);

-- =============================================================================
-- 7. PERFORMANCE & SPECIALIZED INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS "institutions_type_verification_idx" 
    ON "institutions"("type", "verification_status", "is_active");

CREATE INDEX IF NOT EXISTS "users_institution_id_role_idx" 
    ON "users"("institution_id", "role");

CREATE INDEX IF NOT EXISTS "blood_units_inst_inventory_status_idx" 
    ON "blood_units"("institution_id", "inventory_status");

CREATE INDEX IF NOT EXISTS "blood_units_component_blood_group_idx" 
    ON "blood_units"("component_type", "abo_group", "rh_factor");

CREATE INDEX IF NOT EXISTS "blood_units_expiry_fefo_idx" 
    ON "blood_units"("expiry_date" ASC);

CREATE INDEX IF NOT EXISTS "blood_units_eligibility_lookup_idx" 
    ON "blood_units"("inventory_status", "release_status", "testing_status");

CREATE INDEX IF NOT EXISTS "blood_requests_hospital_status_idx" 
    ON "blood_requests"("hospital_id", "status");

CREATE INDEX IF NOT EXISTS "blood_requests_required_by_urgency_idx" 
    ON "blood_requests"("required_by" ASC, "urgency");

CREATE INDEX IF NOT EXISTS "allocations_request_id_idx" 
    ON "allocations"("request_id");

CREATE INDEX IF NOT EXISTS "allocations_blood_unit_id_idx" 
    ON "allocations"("blood_unit_id");

CREATE INDEX IF NOT EXISTS "transfers_source_status_idx" 
    ON "transfers"("source_institution_id", "status");

CREATE INDEX IF NOT EXISTS "transfers_dest_status_idx" 
    ON "transfers"("destination_institution_id", "status");

CREATE INDEX IF NOT EXISTS "transfers_request_id_idx" 
    ON "transfers"("request_id");

CREATE INDEX IF NOT EXISTS "transfer_units_blood_unit_id_idx" 
    ON "transfer_units"("blood_unit_id");

CREATE INDEX IF NOT EXISTS "expiry_alerts_institution_unresolved_idx" 
    ON "expiry_alerts"("institution_id", "resolved") 
    WHERE "resolved" = false;

CREATE INDEX IF NOT EXISTS "notifications_recipient_unread_idx" 
    ON "notifications"("recipient_user_id", "read_at") 
    WHERE "read_at" IS NULL;

CREATE INDEX IF NOT EXISTS "demand_forecasts_lookup_idx" 
    ON "demand_forecasts"("institution_id", "component_type", "forecast_date" ASC);

CREATE INDEX IF NOT EXISTS "audit_logs_institution_time_idx" 
    ON "audit_logs"("institution_id", "created_at" DESC);

CREATE INDEX IF NOT EXISTS "audit_logs_polymorphic_entity_idx" 
    ON "audit_logs"("entity_type", "entity_id");

CREATE INDEX IF NOT EXISTS "audit_logs_actor_time_idx" 
    ON "audit_logs"("actor_id", "created_at" DESC);

CREATE INDEX IF NOT EXISTS "inventory_events_unit_time_idx" 
    ON "inventory_events"("blood_unit_id", "timestamp" DESC);

CREATE INDEX IF NOT EXISTS "anomaly_events_institution_status_idx" 
    ON "anomaly_events"("institution_id", "status");

-- =============================================================================
-- 8. REFERENTIAL INTEGRITY & FOREIGN KEY CONSTRAINTS
-- =============================================================================

ALTER TABLE "users" 
    DROP CONSTRAINT IF EXISTS "users_institution_id_fkey",
    ADD CONSTRAINT "users_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "blood_units" 
    DROP CONSTRAINT IF EXISTS "blood_units_institution_id_fkey",
    ADD CONSTRAINT "blood_units_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "blood_requests" 
    DROP CONSTRAINT IF EXISTS "blood_requests_hospital_id_fkey",
    ADD CONSTRAINT "blood_requests_hospital_id_fkey" 
    FOREIGN KEY ("hospital_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "blood_requests" 
    DROP CONSTRAINT IF EXISTS "blood_requests_created_by_id_fkey",
    ADD CONSTRAINT "blood_requests_created_by_id_fkey" 
    FOREIGN KEY ("created_by_id") REFERENCES "users"("id") 
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE "allocations" 
    DROP CONSTRAINT IF EXISTS "allocations_request_id_fkey",
    ADD CONSTRAINT "allocations_request_id_fkey" 
    FOREIGN KEY ("request_id") REFERENCES "blood_requests"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "allocations" 
    DROP CONSTRAINT IF EXISTS "allocations_blood_unit_id_fkey",
    ADD CONSTRAINT "allocations_blood_unit_id_fkey" 
    FOREIGN KEY ("blood_unit_id") REFERENCES "blood_units"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "allocations" 
    DROP CONSTRAINT IF EXISTS "allocations_allocated_by_id_fkey",
    ADD CONSTRAINT "allocations_allocated_by_id_fkey" 
    FOREIGN KEY ("allocated_by_id") REFERENCES "users"("id") 
    ON DELETE RESTRICT ON UPDATE CASCADE;

ALTER TABLE "transfers" 
    DROP CONSTRAINT IF EXISTS "transfers_source_institution_id_fkey",
    ADD CONSTRAINT "transfers_source_institution_id_fkey" 
    FOREIGN KEY ("source_institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "transfers" 
    DROP CONSTRAINT IF EXISTS "transfers_destination_institution_id_fkey",
    ADD CONSTRAINT "transfers_destination_institution_id_fkey" 
    FOREIGN KEY ("destination_institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "transfers" 
    DROP CONSTRAINT IF EXISTS "transfers_request_id_fkey",
    ADD CONSTRAINT "transfers_request_id_fkey" 
    FOREIGN KEY ("request_id") REFERENCES "blood_requests"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "transfers" 
    DROP CONSTRAINT IF EXISTS "transfers_approved_by_id_fkey",
    ADD CONSTRAINT "transfers_approved_by_id_fkey" 
    FOREIGN KEY ("approved_by_id") REFERENCES "users"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "transfer_units" 
    DROP CONSTRAINT IF EXISTS "transfer_units_transfer_id_fkey",
    ADD CONSTRAINT "transfer_units_transfer_id_fkey" 
    FOREIGN KEY ("transfer_id") REFERENCES "transfers"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "transfer_units" 
    DROP CONSTRAINT IF EXISTS "transfer_units_blood_unit_id_fkey",
    ADD CONSTRAINT "transfer_units_blood_unit_id_fkey" 
    FOREIGN KEY ("blood_unit_id") REFERENCES "blood_units"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "expiry_alerts" 
    DROP CONSTRAINT IF EXISTS "expiry_alerts_blood_unit_id_fkey",
    ADD CONSTRAINT "expiry_alerts_blood_unit_id_fkey" 
    FOREIGN KEY ("blood_unit_id") REFERENCES "blood_units"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "expiry_alerts" 
    DROP CONSTRAINT IF EXISTS "expiry_alerts_institution_id_fkey",
    ADD CONSTRAINT "expiry_alerts_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "notifications" 
    DROP CONSTRAINT IF EXISTS "notifications_recipient_user_id_fkey",
    ADD CONSTRAINT "notifications_recipient_user_id_fkey" 
    FOREIGN KEY ("recipient_user_id") REFERENCES "users"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "notifications" 
    DROP CONSTRAINT IF EXISTS "notifications_institution_id_fkey",
    ADD CONSTRAINT "notifications_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "demand_forecasts" 
    DROP CONSTRAINT IF EXISTS "demand_forecasts_institution_id_fkey",
    ADD CONSTRAINT "demand_forecasts_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "audit_logs" 
    DROP CONSTRAINT IF EXISTS "audit_logs_actor_id_fkey",
    ADD CONSTRAINT "audit_logs_actor_id_fkey" 
    FOREIGN KEY ("actor_id") REFERENCES "users"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "audit_logs" 
    DROP CONSTRAINT IF EXISTS "audit_logs_institution_id_fkey",
    ADD CONSTRAINT "audit_logs_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "inventory_events" 
    DROP CONSTRAINT IF EXISTS "inventory_events_blood_unit_id_fkey",
    ADD CONSTRAINT "inventory_events_blood_unit_id_fkey" 
    FOREIGN KEY ("blood_unit_id") REFERENCES "blood_units"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "inventory_events" 
    DROP CONSTRAINT IF EXISTS "inventory_events_actor_id_fkey",
    ADD CONSTRAINT "inventory_events_actor_id_fkey" 
    FOREIGN KEY ("actor_id") REFERENCES "users"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

ALTER TABLE "anomaly_events" 
    DROP CONSTRAINT IF EXISTS "anomaly_events_institution_id_fkey",
    ADD CONSTRAINT "anomaly_events_institution_id_fkey" 
    FOREIGN KEY ("institution_id") REFERENCES "institutions"("id") 
    ON DELETE CASCADE ON UPDATE CASCADE;

ALTER TABLE "anomaly_events" 
    DROP CONSTRAINT IF EXISTS "anomaly_events_reviewed_by_id_fkey",
    ADD CONSTRAINT "anomaly_events_reviewed_by_id_fkey" 
    FOREIGN KEY ("reviewed_by_id") REFERENCES "users"("id") 
    ON DELETE SET NULL ON UPDATE CASCADE;

-- =============================================================================
-- END OF SCHEMA DDL
-- =============================================================================
