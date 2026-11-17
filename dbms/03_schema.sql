-- =============================================================================
-- 🩸 HemoSync — Blood Inventory & Inter-Hospital Logistics Platform
-- 03. Comprehensive PostgreSQL Production Relational Schema
-- =============================================================================
-- Target Database : PostgreSQL 16+
-- Schema Level    : Boyce-Codd Normal Form (BCNF)
-- Compliance      : ISBT-128 Barcode Standard / Deterministic Compatibility
-- Deliverable     : dbms/03_schema.sql (AP 2026 Academic Project)
-- Contributors    : Rahil Paliwal (@rahil-bit) & Kunal (@Kunal241207)
-- =============================================================================

-- Enable UUID extension if available
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- =============================================================================
-- 1. ENUM TYPE DEFINITIONS
-- =============================================================================

DO $$ BEGIN
    CREATE TYPE "InstitutionType" AS ENUM ('HOSPITAL', 'BLOOD_BANK');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "VerificationStatus" AS ENUM ('PENDING', 'VERIFIED', 'REJECTED', 'SUSPENDED');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "UserRole" AS ENUM ('PLATFORM_ADMIN', 'HOSPITAL_STAFF', 'BLOOD_BANK_STAFF');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "BloodComponentType" AS ENUM ('RED_BLOOD_CELLS', 'PLATELETS', 'PLASMA');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "AboGroup" AS ENUM ('A', 'B', 'AB', 'O');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "RhFactor" AS ENUM ('POSITIVE', 'NEGATIVE');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "TestingStatus" AS ENUM ('PENDING', 'PASSED', 'FAILED');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "ReleaseStatus" AS ENUM ('QUARANTINED', 'RELEASED', 'REJECTED');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "InventoryStatus" AS ENUM (
        'AVAILABLE', 'RESERVED', 'IN_TRANSFER', 'TRANSFERRED', 
        'USED', 'EXPIRED', 'DISCARDED', 'QUARANTINED'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "RequestUrgency" AS ENUM ('ROUTINE', 'URGENT', 'EMERGENCY');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "RequestStatus" AS ENUM (
        'PENDING', 'VALIDATED', 'PARTIALLY_ALLOCATED', 'ALLOCATED', 
        'TRANSFER_PENDING', 'FULFILLED', 'CANCELLED', 'UNFULFILLED'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "AllocationStatus" AS ENUM ('RESERVED', 'FULFILLED', 'CANCELLED');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "TransferStatus" AS ENUM (
        'REQUESTED', 'APPROVED', 'REJECTED', 'RESERVED', 
        'DISPATCHED', 'RECEIVED', 'CANCELLED', 'FAILED'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "AlertSeverity" AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "EventType" AS ENUM (
        'REGISTRATION', 'STATUS_CHANGE', 'DISPATCH', 'RECEIPT', 
        'DISPOSAL', 'QUARANTINE_APPLIED', 'TEST_COMPLETED', 
        'ALLOCATION_RESERVED', 'ALLOCATION_RELEASED'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE "AuditAction" AS ENUM (
        'CREATE', 'UPDATE', 'DELETE', 'LOGIN', 'LOGOUT', 
        'ALLOCATE', 'TRANSFER_REQUEST', 'TRANSFER_APPROVE', 
        'TRANSFER_DISPATCH', 'TRANSFER_RECEIVE', 'STATUS_CHANGE'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- =============================================================================
-- 2. CORE FACILITY & USER TABLES
-- =============================================================================

-- Table: institutions
CREATE TABLE IF NOT EXISTS "institutions" (
    "id" TEXT NOT NULL,
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
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "institutions_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "institutions_license_number_key" UNIQUE ("license_number")
);

-- Table: users
CREATE TABLE IF NOT EXISTS "users" (
    "id" TEXT NOT NULL,
    "institution_id" TEXT,
    "name" VARCHAR(255) NOT NULL,
    "email" VARCHAR(255) NOT NULL,
    "password_hash" VARCHAR(255) NOT NULL,
    "role" "UserRole" NOT NULL,
    "is_active" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "users_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "users_email_key" UNIQUE ("email")
);

-- Table: system_settings
CREATE TABLE IF NOT EXISTS "system_settings" (
    "id" TEXT NOT NULL,
    "key" VARCHAR(100) NOT NULL,
    "value" TEXT NOT NULL,
    "description" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "system_settings_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "system_settings_key_key" UNIQUE ("key")
);

-- =============================================================================
-- 3. INVENTORY & CLINICAL REQUEST TABLES
-- =============================================================================

-- Table: blood_units (ISBT-128 Compliant with segregated 3-axis state machine)
CREATE TABLE IF NOT EXISTS "blood_units" (
    "id" TEXT NOT NULL,
    "institution_id" TEXT NOT NULL,
    "unit_code" VARCHAR(50) NOT NULL,
    "component_type" "BloodComponentType" NOT NULL,
    "abo_group" "AboGroup" NOT NULL,
    "rh_factor" "RhFactor" NOT NULL,
    "collection_date" TIMESTAMP(3) NOT NULL,
    "expiry_date" TIMESTAMP(3) NOT NULL,
    "volume_ml" INTEGER NOT NULL,
    "testing_status" "TestingStatus" NOT NULL DEFAULT 'PENDING',
    "release_status" "ReleaseStatus" NOT NULL DEFAULT 'QUARANTINED',
    "inventory_status" "InventoryStatus" NOT NULL DEFAULT 'AVAILABLE',
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "blood_units_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "blood_units_unit_code_key" UNIQUE ("unit_code"),
    CONSTRAINT "chk_volume_positive" CHECK ("volume_ml" > 0),
    CONSTRAINT "chk_chronological_dates" CHECK ("expiry_date" > "collection_date")
);

-- Table: blood_requests
CREATE TABLE IF NOT EXISTS "blood_requests" (
    "id" TEXT NOT NULL,
    "hospital_id" TEXT NOT NULL,
    "created_by_id" TEXT NOT NULL,
    "requested_component" "BloodComponentType" NOT NULL,
    "requested_abo" "AboGroup" NOT NULL,
    "requested_rh" "RhFactor" NOT NULL,
    "requested_quantity" INTEGER NOT NULL,
    "urgency" "RequestUrgency" NOT NULL DEFAULT 'ROUTINE',
    "status" "RequestStatus" NOT NULL DEFAULT 'PENDING',
    "required_by" TIMESTAMP(3) NOT NULL,
    "reason" TEXT,
    "is_synthetic" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "blood_requests_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "chk_requested_quantity_positive" CHECK ("requested_quantity" > 0)
);

-- Table: allocations (M:N junction connecting Requests and BloodUnits)
CREATE TABLE IF NOT EXISTS "allocations" (
    "id" TEXT NOT NULL,
    "request_id" TEXT NOT NULL,
    "blood_unit_id" TEXT NOT NULL,
    "allocated_by_id" TEXT NOT NULL,
    "status" "AllocationStatus" NOT NULL DEFAULT 'RESERVED',
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "allocations_pkey" PRIMARY KEY ("id")
);

-- =============================================================================
-- 4. INTER-HOSPITAL LOGISTICS & SHIPMENTS
-- =============================================================================

-- Table: transfers
CREATE TABLE IF NOT EXISTS "transfers" (
    "id" TEXT NOT NULL,
    "source_institution_id" TEXT NOT NULL,
    "destination_institution_id" TEXT NOT NULL,
    "request_id" TEXT,
    "status" "TransferStatus" NOT NULL DEFAULT 'REQUESTED',
    "approved_by_id" TEXT,
    "dispatched_at" TIMESTAMP(3),
    "received_at" TIMESTAMP(3),
    "notes" TEXT,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "transfers_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "chk_distinct_transfer_institutions" CHECK ("source_institution_id" <> "destination_institution_id")
);

-- Table: transfer_units (Associative manifest for transfer shipments)
CREATE TABLE IF NOT EXISTS "transfer_units" (
    "id" TEXT NOT NULL,
    "transfer_id" TEXT NOT NULL,
    "blood_unit_id" TEXT NOT NULL,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "transfer_units_pkey" PRIMARY KEY ("id"),
    CONSTRAINT "transfer_units_transfer_id_blood_unit_id_key" UNIQUE ("transfer_id", "blood_unit_id")
);

-- =============================================================================
-- 5. MONITORING, AUDIT & DEMAND FORECASTING
-- =============================================================================

-- Table: expiry_alerts
CREATE TABLE IF NOT EXISTS "expiry_alerts" (
    "id" TEXT NOT NULL,
    "blood_unit_id" TEXT NOT NULL,
    "institution_id" TEXT NOT NULL,
    "severity" "AlertSeverity" NOT NULL DEFAULT 'MEDIUM',
    "resolved" BOOLEAN NOT NULL DEFAULT false,
    "resolved_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "expiry_alerts_pkey" PRIMARY KEY ("id")
);

-- Table: notifications
CREATE TABLE IF NOT EXISTS "notifications" (
    "id" TEXT NOT NULL,
    "recipient_user_id" TEXT NOT NULL,
    "institution_id" TEXT,
    "type" VARCHAR(50) NOT NULL DEFAULT 'SYSTEM',
    "title" VARCHAR(255) NOT NULL,
    "message" TEXT NOT NULL,
    "metadata" JSONB,
    "read_at" TIMESTAMP(3),
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "notifications_pkey" PRIMARY KEY ("id")
);

-- Table: demand_forecasts
CREATE TABLE IF NOT EXISTS "demand_forecasts" (
    "id" TEXT NOT NULL,
    "institution_id" TEXT NOT NULL,
    "component_type" "BloodComponentType" NOT NULL,
    "abo_group" "AboGroup",
    "rh_factor" "RhFactor",
    "forecast_date" TIMESTAMP(3) NOT NULL,
    "horizon_days" INTEGER NOT NULL DEFAULT 7,
    "predicted_demand" DOUBLE PRECISION NOT NULL,
    "lower_bound" DOUBLE PRECISION NOT NULL,
    "upper_bound" DOUBLE PRECISION NOT NULL,
    "model_version" VARCHAR(50) NOT NULL DEFAULT 'v1.0-ewma',
    "metrics" JSONB,
    "generated_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "demand_forecasts_pkey" PRIMARY KEY ("id")
);

-- Table: audit_logs (Immutable clinical ledger)
CREATE TABLE IF NOT EXISTS "audit_logs" (
    "id" TEXT NOT NULL,
    "actor_id" TEXT,
    "institution_id" TEXT,
    "entity_type" VARCHAR(100) NOT NULL,
    "entity_id" VARCHAR(100) NOT NULL,
    "action" "AuditAction" NOT NULL,
    "metadata" JSONB,
    "created_at" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id")
);

-- Table: inventory_events (Physical unit state transition history)
CREATE TABLE IF NOT EXISTS "inventory_events" (
    "id" TEXT NOT NULL,
    "blood_unit_id" TEXT NOT NULL,
    "event_type" "EventType" NOT NULL,
    "previous_status" "InventoryStatus",
    "new_status" "InventoryStatus" NOT NULL,
    "actor_id" TEXT,
    "notes" TEXT,
    "timestamp" TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT "inventory_events_pkey" PRIMARY KEY ("id")
);

-- =============================================================================
-- 6. PERFORMANCE & QUERY INDEXES
-- =============================================================================

CREATE INDEX IF NOT EXISTS "institutions_type_verification_status_is_active_idx" 
    ON "institutions"("type", "verification_status", "is_active");

CREATE INDEX IF NOT EXISTS "users_institution_id_role_idx" 
    ON "users"("institution_id", "role");

CREATE INDEX IF NOT EXISTS "blood_units_institution_id_inventory_status_idx" 
    ON "blood_units"("institution_id", "inventory_status");

CREATE INDEX IF NOT EXISTS "blood_units_component_type_abo_group_rh_factor_idx" 
    ON "blood_units"("component_type", "abo_group", "rh_factor");

CREATE INDEX IF NOT EXISTS "blood_units_expiry_date_idx" 
    ON "blood_units"("expiry_date");

CREATE INDEX IF NOT EXISTS "blood_units_inventory_status_release_status_testing_status_idx" 
    ON "blood_units"("inventory_status", "release_status", "testing_status");

CREATE INDEX IF NOT EXISTS "blood_requests_hospital_id_status_idx" 
    ON "blood_requests"("hospital_id", "status");

CREATE INDEX IF NOT EXISTS "blood_requests_required_by_idx" 
    ON "blood_requests"("required_by");

CREATE INDEX IF NOT EXISTS "blood_requests_urgency_idx" 
    ON "blood_requests"("urgency");

CREATE INDEX IF NOT EXISTS "allocations_request_id_idx" 
    ON "allocations"("request_id");

CREATE INDEX IF NOT EXISTS "allocations_blood_unit_id_status_idx" 
    ON "allocations"("blood_unit_id", "status");

CREATE INDEX IF NOT EXISTS "transfers_source_institution_id_status_idx" 
    ON "transfers"("source_institution_id", "status");

CREATE INDEX IF NOT EXISTS "transfers_destination_institution_id_status_idx" 
    ON "transfers"("destination_institution_id", "status");

CREATE INDEX IF NOT EXISTS "transfers_request_id_idx" 
    ON "transfers"("request_id");

CREATE INDEX IF NOT EXISTS "transfer_units_blood_unit_id_idx" 
    ON "transfer_units"("blood_unit_id");

CREATE INDEX IF NOT EXISTS "expiry_alerts_institution_id_resolved_idx" 
    ON "expiry_alerts"("institution_id", "resolved");

CREATE INDEX IF NOT EXISTS "expiry_alerts_blood_unit_id_idx" 
    ON "expiry_alerts"("blood_unit_id");

CREATE INDEX IF NOT EXISTS "notifications_recipient_user_id_read_at_idx" 
    ON "notifications"("recipient_user_id", "read_at");

CREATE INDEX IF NOT EXISTS "demand_forecasts_institution_id_component_type_forecast_dat_idx" 
    ON "demand_forecasts"("institution_id", "component_type", "forecast_date");

CREATE INDEX IF NOT EXISTS "audit_logs_institution_id_created_at_idx" 
    ON "audit_logs"("institution_id", "created_at");

CREATE INDEX IF NOT EXISTS "audit_logs_entity_type_entity_id_idx" 
    ON "audit_logs"("entity_type", "entity_id");

CREATE INDEX IF NOT EXISTS "audit_logs_actor_id_idx" 
    ON "audit_logs"("actor_id");

CREATE INDEX IF NOT EXISTS "inventory_events_blood_unit_id_timestamp_idx" 
    ON "inventory_events"("blood_unit_id", "timestamp");

-- =============================================================================
-- 7. FOREIGN KEY REFERENTIAL INTEGRITY CONSTRAINTS
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
    ON DELETE CASCADE ON UPDATE CASCADE;

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
    ON DELETE CASCADE ON UPDATE CASCADE;

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
