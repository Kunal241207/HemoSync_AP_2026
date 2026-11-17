# 🩸 HemoSync — Database Constraints & Indexing Strategy Specification

> **Document Version**: 2.0.0 (Audited & Finalized)  
> **Course / Academic Module**: Advanced Programming (AP 2026) — Database Architecture Audit  
> **Target Engine**: PostgreSQL 16+  
> **Deliverable**: `dbms/05_constraints_and_indexing.md`  
> **Authors**: Rahil Paliwal (`rahil-bit`) & Kunal (`Kunal241207`)

---

## 1. Executive Summary

In healthcare database design, relational constraints and optimized indexing structures form the primary defense against clinical errors (such as transfusing incompatible or unreleased blood) and database concurrency anomalies (such as double-booking physical blood units).

This document details the complete constraint architecture and PostgreSQL indexing strategy implemented for **HemoSync**.

---

## 2. Table-by-Table Constraint Matrix

### 2.1 Primary & Alternate Unique Keys
Every entity in HemoSync utilizes **UUID v4** as its immutable surrogate primary key. This eliminates sequential ID enumeration vulnerabilities and facilitates zero-collision multi-regional database replication.

| Table Name | Primary Key | Unique Constraints / Candidate Keys | Rationale |
|:---|:---|:---|:---|
| `institutions` | `id` (UUID) | `UNIQUE (license_number)` | State medical license numbers are globally unique across hospitals and blood banks. |
| `users` | `id` (UUID) | `UNIQUE (email)` | User email addresses serve as unique authentication usernames. |
| `system_settings` | `id` (UUID) | `UNIQUE (key)` | System config entries are strictly unique key-value identifiers. |
| `blood_units` | `id` (UUID) | `UNIQUE (unit_code)` | ISBT-128 Donation Identification Numbers (DIN) are globally unique. |
| `blood_requests` | `id` (UUID) | — | Hospital requisition order identifier. |
| `allocations` | `id` (UUID) | `UNIQUE (request_id, blood_unit_id)` | Prevents duplicate allocation records for the same unit on one request. |
| `transfers` | `id` (UUID) | — | Transfer logistics manifest identifier. |
| `transfer_units` | `id` (UUID) | `UNIQUE (transfer_id, blood_unit_id)` | Prevents adding the same blood unit multiple times to a shipment manifest. |
| `expiry_alerts` | `id` (UUID) | — | Alert record identifier. |
| `notifications` | `id` (UUID) | — | User operational message identifier. |
| `demand_forecasts` | `id` (UUID) | `UNIQUE (institution_id, component_type, forecast_date, horizon_days, model_version)` | Prevents duplicate projection runs for identical dimensional parameters. |
| `audit_logs` | `id` (UUID) | — | Immutable historical event record. |
| `inventory_events` | `id` (UUID) | — | Physical container chain-of-custody log. |
| `anomaly_events` | `id` (UUID) | — | Clinical outlier record. |

---

### 2.2 PostgreSQL CHECK Constraints (Clinical Safety & Domain Rules)

```sql
-- 1. Facility Geolocation Coordinates
ALTER TABLE "institutions"
    ADD CONSTRAINT "chk_institution_lat" CHECK ("latitude" BETWEEN -90.0 AND 90.0),
    ADD CONSTRAINT "chk_institution_lng" CHECK ("longitude" BETWEEN -180.0 AND 180.0);

-- 2. Physical Unit Volume Integrity
ALTER TABLE "blood_units"
    ADD CONSTRAINT "chk_blood_unit_volume_positive" CHECK ("volume_ml" > 0);

-- 3. Chronological Phlebotomy and Expiration Dates
ALTER TABLE "blood_units"
    ADD CONSTRAINT "chk_blood_unit_chronological_dates" CHECK ("expiry_date" > "collection_date");

-- 4. Critical Clinical Safety Invariant: Orthogonal State Machine Isolation
-- Enforces that a blood unit can NEVER be marked AVAILABLE unless it has PASSED testing and is RELEASED from quarantine.
ALTER TABLE "blood_units"
    ADD CONSTRAINT "chk_blood_unit_availability_safety" CHECK (
        ("inventory_status" <> 'AVAILABLE') OR 
        ("testing_status" = 'PASSED' AND "release_status" = 'RELEASED')
    );

-- 5. Request Quantity Positive Rule
ALTER TABLE "blood_requests"
    ADD CONSTRAINT "chk_blood_requests_quantity_positive" CHECK ("requested_quantity" > 0);

-- 6. Inter-Hospital Transfer Facility Distinction Rule
-- Prevents self-transfers where source facility equals destination facility
ALTER TABLE "transfers"
    ADD CONSTRAINT "chk_transfer_distinct_facilities" CHECK ("source_institution_id" <> "destination_institution_id");

-- 7. Logistics Dispatch and Receipt Chronology
ALTER TABLE "transfers"
    ADD CONSTRAINT "chk_transfer_chronological_times" CHECK (
        "received_at" IS NULL OR "dispatched_at" IS NULL OR "received_at" >= "dispatched_at"
    );

-- 8. Forecasting Parameter Integrity
ALTER TABLE "demand_forecasts"
    ADD CONSTRAINT "chk_forecast_horizon_positive" CHECK ("horizon_days" > 0),
    ADD CONSTRAINT "chk_forecast_demand_non_negative" CHECK ("predicted_demand" >= 0.0),
    ADD CONSTRAINT "chk_forecast_bounds" CHECK ("lower_bound" <= "upper_bound");
```

---

## 3. Anti-Collision & Partial Unique Indexes

In high-concurrency healthcare environments, two competing emergency requests may simultaneously attempt to allocate the last compatible O-Negative blood unit. Application-level locks can fail under horizontal scaling. 

HemoSync solves this with **PostgreSQL Partial Unique Indexes**:

### 3.1 Strict Single-Active-Reservation Invariant
```sql
CREATE UNIQUE INDEX "allocations_active_reservation_unique_idx" 
ON "allocations"("blood_unit_id") 
WHERE "status" = 'RESERVED';
```
- **How it works**: PostgreSQL enforces uniqueness on `blood_unit_id` *only* for tuples where `status = 'RESERVED'`.
- **Result**: Historical allocations (e.g. `FULFILLED` or `CANCELLED`) for that unit remain preserved for audit trails, but **only ONE active reservation can exist at any given time**. A second transaction attempting to reserve the unit is rejected at the database engine level with code `23505` (unique constraint violation).

### 3.2 Expiry Alert Deduplication Invariant
```sql
CREATE UNIQUE INDEX "expiry_alerts_active_unit_unique_idx" 
ON "expiry_alerts"("blood_unit_id") 
WHERE "resolved" = false;
```
- **How it works**: Prevents automated monitoring cron jobs from creating duplicate alert records for a unit that already has an unresolved alert open.

---

## 4. Query Performance Indexing Strategy

### 4.1 First-Expired, First-Out (FEFO) Matching Index
```sql
CREATE INDEX "blood_units_expiry_fefo_idx" 
ON "blood_units"("expiry_date" ASC);
```
- **Execution**: Supports $O(\log N)$ index scan during compatibility matching to automatically retrieve the nearest-expiring compatible blood units first.

### 4.2 Tri-Factor Compatibility Composite Index
```sql
CREATE INDEX "blood_units_component_blood_group_idx" 
ON "blood_units"("component_type", "abo_group", "rh_factor");
```
- **Execution**: Accelerates exact ABO/Rh compatibility filtering across inventory collections.

### 4.3 High-Throughput Status & Foreign Key Indexes
| Index Name | Target Table | Indexed Columns | Filter / Sort | Query Accelerated |
|:---|:---|:---|:---|:---|
| `blood_units_inst_inventory_status_idx` | `blood_units` | `(institution_id, inventory_status)` | B-Tree | Facility local stock queries & dashboard metrics |
| `blood_units_eligibility_lookup_idx` | `blood_units` | `(inventory_status, release_status, testing_status)` | B-Tree | Rapid filtering of clinically usable inventory |
| `blood_requests_hospital_status_idx` | `blood_requests` | `(hospital_id, status)` | B-Tree | Hospital open requisition tracking |
| `blood_requests_required_by_urgency_idx` | `blood_requests` | `(required_by ASC, urgency)` | B-Tree | Priority queue scheduling for emergency demands |
| `transfers_source_status_idx` | `transfers` | `(source_institution_id, status)` | B-Tree | Outgoing dispatch dashboard queries |
| `transfers_dest_status_idx` | `transfers` | `(destination_institution_id, status)` | B-Tree | Incoming delivery intake verification queries |
| `notifications_recipient_unread_idx` | `notifications` | `(recipient_user_id, read_at)` | `WHERE read_at IS NULL` | Instant unread notification bell retrieval |
| `demand_forecasts_lookup_idx` | `demand_forecasts` | `(institution_id, component_type, forecast_date ASC)` | B-Tree | Time-series projection chart rendering |
| `audit_logs_institution_time_idx` | `audit_logs` | `(institution_id, created_at DESC)` | B-Tree | Compliance and forensic timeline retrieval |
| `audit_logs_polymorphic_entity_idx` | `audit_logs` | `(entity_type, entity_id)` | B-Tree | Entity-specific lifecycle audit history |
| `inventory_events_unit_time_idx` | `inventory_events` | `(blood_unit_id, timestamp DESC)` | B-Tree | Complete chain-of-custody reconstruction for blood containers |
