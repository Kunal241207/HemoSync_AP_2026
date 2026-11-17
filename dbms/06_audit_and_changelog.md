# 🩸 HemoSync — Database Architecture Audit & Changelog

> **Document Version**: 2.0.0 (Audited & Finalized)  
> **Course / Academic Module**: Advanced Programming (AP 2026) — Database Architecture Audit  
> **Target Database Engine**: PostgreSQL 16+  
> **Deliverable**: `dbms/06_audit_and_changelog.md`  
> **Authors**: Rahil Paliwal (`rahil-bit`) & Kunal (`Kunal241207`)

---

## 1. Executive Summary & Audit Context

A comprehensive database architecture audit was conducted on the **HemoSync** platform across all 14 relational tables, ORM models, business logic services, and backend endpoints.

While the existing system maintained a normalized relational foundation, several critical vulnerabilities were identified in the areas of:
1. Concurrency isolation under high-load request allocations.
2. Reliance on application-level checks for clinical safety invariants.
3. Lack of database-level structural guards against self-transfers.
4. Duplicate alert and forecast generation during automated batch jobs.
5. Incomplete Crow's Foot relationship definitions in visual architecture documentation.

---

## 2. Identified Discrepancies & Audit Findings

| Category | Table / Feature | Identified Discrepancy | Risk Level | Architectural Correction Applied |
|:---|:---|:---|:---:|:---|
| **Clinical Safety** | `blood_units` | Relied solely on Node.js application validation to ensure unreleased/untested blood is not marked `AVAILABLE`. A direct database write or bug could mark contaminated units as available. | **CRITICAL** | Added PostgreSQL CHECK constraint `chk_blood_unit_availability_safety`: enforces `("inventory_status" <> 'AVAILABLE') OR ("testing_status" = 'PASSED' AND "release_status" = 'RELEASED')`. |
| **Concurrency / Allocation** | `allocations` | Multiple concurrent transactions could attempt to allocate the same blood unit if row locking was delayed, risking physical double-booking. | **CRITICAL** | Added PostgreSQL Partial Unique Index `allocations_active_reservation_unique_idx` on `(blood_unit_id) WHERE status = 'RESERVED'`. |
| **Logistics** | `transfers` | Source institution could theoretically equal destination institution, producing self-transfers and corrupted inventory counts. | **HIGH** | Added CHECK constraint `chk_transfer_distinct_facilities` (`source_institution_id <> destination_institution_id`). |
| **Logistics** | `transfers` | Receipt timestamp could be set prior to dispatch timestamp due to clock skew or input error. | **MEDIUM** | Added CHECK constraint `chk_transfer_chronological_times` (`received_at IS NULL OR dispatched_at IS NULL OR received_at >= dispatched_at`). |
| **Monitoring** | `expiry_alerts` | Automated expiry cron jobs could insert redundant unresolved alerts for the same container. | **MEDIUM** | Added Partial Unique Index `expiry_alerts_active_unit_unique_idx` on `(blood_unit_id) WHERE resolved = false`. |
| **Forecasting** | `demand_forecasts` | Re-running daily forecast generation could create duplicate forecast tuples for the same day and horizon. | **MEDIUM** | Added composite unique index `demand_forecasts_series_unique_idx` on `(institution_id, component_type, forecast_date, horizon_days, model_version)`. |
| **Audit Non-Repudiation** | `blood_requests` & `allocations` | Deleting a user account could cascade or nullify clinical requisition orders and allocation approvals. | **HIGH** | Configured `ON DELETE RESTRICT` for `created_by_id` in `blood_requests` and `allocated_by_id` in `allocations`. Accounts with active medical requisitions cannot be dropped. |
| **Audit Trails** | `audit_logs` | Ambiguity regarding whether `entity_id` had standard foreign keys or was polymorphic. | **LOW** | Explicitly documented polymorphic reference pattern (`entity_type` + `entity_id`) and indexed `(entity_type, entity_id)` to decouple audit logs from table purges. |
| **ER Diagram** | Visual Architecture | Earlier diagrams used approximate lines instead of standardized Crow's Foot cardinality symbols (`||`, `|o`, `|<`, `o<`). | **MEDIUM** | Redesigned ER diagram with full Crow's Foot notation, color-coded functional modules, and clean orthogonal routing. |

---

## 3. Detailed Changelog of Applied Enhancements

### 3.1 DDL & PostgreSQL Schema Updates (`dbms/03_schema.sql`)
1. **PostgreSQL 16 Compatibility**:
   - Standardized UUID v4 generation across all 14 entities using `uuid_generate_v4()`.
   - Replaced plain `TIMESTAMP` with timezone-aware `TIMESTAMPTZ` for all event and audit timestamps.
2. **Safety CHECK Constraints**:
   - `institutions`: Added latitude `[-90, 90]` and longitude `[-180, 180]` valid geographic range checks.
   - `blood_units`: Added `volume_ml > 0`, `expiry_date > collection_date`, and orthogonal state availability constraint.
   - `blood_requests`: Added `requested_quantity > 0`.
   - `transfers`: Added source $\neq$ destination check and chronological dispatch/receipt time checks.
   - `demand_forecasts`: Added `horizon_days > 0`, `predicted_demand >= 0`, and `lower_bound <= upper_bound`.
3. **Partial Unique Indexes**:
   - `allocations_active_reservation_unique_idx` on `allocations(blood_unit_id) WHERE status = 'RESERVED'`.
   - `expiry_alerts_active_unit_unique_idx` on `expiry_alerts(blood_unit_id) WHERE resolved = false`.
   - `notifications_recipient_unread_idx` on `notifications(recipient_user_id, read_at) WHERE read_at IS NULL`.
4. **Performance & FEFO Query Indexes**:
   - Added `blood_units_expiry_fefo_idx` (`expiry_date ASC`) for sub-millisecond FEFO sort execution.
   - Added `blood_units_component_blood_group_idx` for instant ABO/Rh compatibility filtering.
   - Added compound status indexes across logistics and request tracking tables.

---

### 3.2 Visual ER Model Updates (`dbms/02_er_diagram.png` & `dbms/02_er_diagram.svg`)
1. **Module Color Coding**:
   - **Facility Management**: Deep Cobalt Blue (`#1e3a8a`, border `#3b82f6`)
   - **Inventory Management**: Clinical Crimson (`#881337`, border `#e11d48`)
   - **Request Management**: Emerald Green (`#064e3b`, border `#10b981`)
   - **Logistics Management**: Safety Amber / Orange (`#7c2d12`, border `#f97316`)
   - **Monitoring & Audit**: Royal Violet (`#4c1d95`, border `#8b5cf6`)
2. **Crow's Foot Notation**:
   - Replaced arrows with formal Crow's Foot cardinality symbols:
     - `||` Mandatory One (1..1)
     - `|o` Optional One (0..1)
     - `|<` Mandatory Many (1..N)
     - `o<` Optional Many (0..N)
3. **Legibility & Layout**:
   - Arranged entities into a clean 4-column topology eliminating line intersections.
   - High-contrast badges for `[PK]`, `[FK]`, and `[UK]`.
   - Dark Navy enterprise background (`#0b0f19`) optimized for presentation display and high-resolution PDF embedding.
