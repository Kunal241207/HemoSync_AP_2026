# 🩸 HemoSync — Relationship Architecture & Cardinality Specification

> **Document Version**: 2.0.0 (Audited & Finalized)  
> **Course / Academic Module**: Advanced Programming (AP 2026) — Database Architecture Audit  
> **Project**: HemoSync — Intelligent Blood Inventory & Inter-Hospital Logistics Platform  
> **Authors**: Rahil Paliwal (`rahil-bit`) & Kunal (`Kunal241207`)

---

## 1. Architectural Overview

In a safety-critical clinical database, referential integrity and cardinality definitions directly dictate patient safety, prevent double-allocation of blood units, enforce cold-chain chain of custody, and ensure auditability.

The **HemoSync** relational model adheres to **Boyce-Codd Normal Form (BCNF)** across 14 core entities. Many-to-Many (M:N) business relationships are systematically decomposed into first-class associative junction entities (`allocations` and `transfer_units`) equipped with composite uniqueness constraints and transactional locking gates.

---

## 2. Comprehensive Relationship Matrix (21 Audited Relationships)

The table below provides the authoritative architectural specification for all 21 relationships identified across the HemoSync database.

| # | Relationship Name | Parent Entity | Child Entity | Foreign Key Column | Cardinality | Parent Optionality | Child Optionality | Crow's Foot Notation | Referential Action (ON DELETE / UPDATE) | Business Rule & Clinical Invariant |
|:---|:---|:---|:---|:---|:---:|:---:|:---:|:---:|:---|:---|
| **1** | Facility Staff Roster | `institutions` | `users` | `users.institution_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `||──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | A hospital or blood bank employs 0 to N users. Platform administrators have `institution_id = NULL` for cross-facility oversight. |
| **2** | Inventory Custody | `institutions` | `blood_units` | `blood_units.institution_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Every physical blood unit is in the custodial possession of exactly 1 facility. A facility can hold 0 to thousands of units. |
| **3** | Requisition Submission | `institutions` | `blood_requests` | `blood_requests.hospital_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Only accredited hospitals can issue clinical requisitions. Each request belongs to exactly one hospital. |
| **4** | Request Authorship | `users` | `blood_requests` | `blood_requests.created_by_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE RESTRICT ON UPDATE CASCADE` | A hospital staff member submits 0 to N requisitions. A requisition cannot be orphaned if a user is deleted (`RESTRICT`). |
| **5** | Requisition Fulfillment | `blood_requests` | `allocations` | `allocations.request_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | A request is fulfilled by allocating 0 to N discrete blood units (up to `requested_quantity`). |
| **6** | Physical Reservation | `blood_units` | `allocations` | `allocations.blood_unit_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | A blood unit has historical allocations, but a partial unique index enforces **at most ONE active `RESERVED` allocation** at any instant. |
| **7** | Allocation Authorization | `users` | `allocations` | `allocations.allocated_by_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE RESTRICT ON UPDATE CASCADE` | Every allocation record captures the clinician or technician who authorized the matching decision. |
| **8** | Outgoing Logistics | `institutions` | `transfers` | `transfers.source_institution_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | The dispatching facility from whose physical inventory blood units are drawn. Cannot equal destination. |
| **9** | Incoming Logistics | `institutions` | `transfers` | `transfers.destination_institution_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | The receiving facility that takes ownership upon intake delivery verification (`RECEIVED`). |
| **10** | Requisition-Linked Transfer | `blood_requests` | `transfers` | `transfers.request_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `|o──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | An inter-facility transfer can be triggered by an open hospital shortage or conducted proactively for inventory redistribution. |
| **11** | Transfer Dispatch Approval | `users` | `transfers` | `transfers.approved_by_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `|o──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | Set when an authorized blood bank staff member approves the shipment for departure (`NULL` while `REQUESTED`). |
| **12** | Shipment Manifest Items | `transfers` | `transfer_units` | `transfer_units.transfer_id` | **1 : N** | Mandatory (1..1) | Mandatory (1..N) | `||──────|<` | `ON DELETE CASCADE ON UPDATE CASCADE` | A transfer shipment must contain at least 1 physical unit manifest item. Deleting a shipment drops its manifest entries. |
| **13** | Manifest Unit Inclusion | `blood_units` | `transfer_units` | `transfer_units.blood_unit_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Connects physical units into transfer shipments. `UNIQUE(transfer_id, blood_unit_id)` prevents duplicate listings. |
| **14** | Chain of Custody History | `blood_units` | `inventory_events` | `inventory_events.blood_unit_id` | **1 : N** | Mandatory (1..1) | Mandatory (1..N) | `||──────|<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Every unit possesses a strictly non-empty immutable event log beginning with `REGISTRATION` through `DISPOSAL` or `USED`. |
| **15** | State Mutation Actor | `users` | `inventory_events` | `inventory_events.actor_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `|o──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | Staff member responsible for physical status mutation. `NULL` when transition is triggered by cron jobs (e.g., expiry). |
| **16** | Shelf-Life Alerting | `blood_units` | `expiry_alerts` | `expiry_alerts.blood_unit_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Units approaching expiration generate alerts. Partial unique index prevents duplicate unresolved alerts per unit. |
| **17** | Regional Alert Routing | `institutions` | `expiry_alerts` | `expiry_alerts.institution_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Denormalized facility scoping allows instant facility dashboard queries without multi-table join bottlenecks. |
| **18** | User Notifications | `users` | `notifications` | `notifications.recipient_user_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | Operational notices dispatched to individual users with read timestamp tracking (`read_at`). |
| **19** | Facility Demand Projections | `institutions` | `demand_forecasts` | `demand_forecasts.institution_id` | **1 : N** | Mandatory (1..1) | Optional (0..N) | `||──────o<` | `ON DELETE CASCADE ON UPDATE CASCADE` | AI statistical forecasts generated for a facility across component dimensions and lead-time horizons. |
| **20** | User Action Auditing | `users` | `audit_logs` | `audit_logs.actor_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `|o──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | Records user who performed administrative or clinical actions. `NULL` for background scheduler tasks. |
| **21** | Facility Audit Scope | `institutions` | `audit_logs` | `audit_logs.institution_id` | **1 : N** | Optional (0..1) | Optional (0..N) | `|o──────o<` | `ON DELETE SET NULL ON UPDATE CASCADE` | Scopes audit records to a facility for tenant filtering. `NULL` for platform-wide administrative events. |

---

## 3. Detailed Entity Relationship Breakdown

### 3.1 Facility & Identity Module
```text
[institutions] (1) ───||────────o< (0..N) [users]
```
- **Parent**: `institutions` (PK: `id`)
- **Child**: `users` (FK: `institution_id`)
- **Cardinality**: 1 to 0..N
- **Business Logic**: An institution may exist prior to staff account creation (e.g. initial onboarding). A platform administrator is not bounded to a single institution (`institution_id = NULL`), allowing cross-facility supervision.

---

### 3.2 Inventory & Unit Management
```text
[institutions] (1) ───||────────o< (0..N) [blood_units]
[blood_units]  (1) ───||────────|< (1..N) [inventory_events]
```
- **Parent**: `institutions` (PK: `id`)
- **Child**: `blood_units` (FK: `institution_id`)
- **Cardinality**: 1 to 0..N
- **Business Logic**: Physical blood units are strictly registered to an accredited blood bank or hospital. Blood units transition custodian ownership only when an inter-hospital transfer completes (`TransferStatus = 'RECEIVED'`).
- **Chain of Custody**: Every physical blood container has at least 1 record in `inventory_events` created at intake (`event_type = 'REGISTRATION'`). Every subsequent state mutation appends a new event.

---

### 3.3 Request Requisitions & Allocations
```text
[institutions]    (1) ───||────────o< (0..N) [blood_requests]
[users]           (1) ───||────────o< (0..N) [blood_requests]
[blood_requests]  (1) ───||────────o< (0..N) [allocations]
[blood_units]     (1) ───||────────o< (0..N) [allocations]
[users]           (1) ───||────────o< (0..N) [allocations]
```
- **M:N Decomposition**: `allocations` serves as the associative relation connecting `blood_requests` and `blood_units`.
- **Concurrency & Anti-Collision Gate**:
  ```sql
  CREATE UNIQUE INDEX "allocations_active_reservation_unique_idx" 
  ON "allocations"("blood_unit_id") 
  WHERE "status" = 'RESERVED';
  ```
  This index makes it mathematically impossible for two concurrent requests to reserve the same physical blood unit.

---

### 3.4 Logistics & Inter-Hospital Transfers
```text
[institutions]   (1) ───||────────o< (0..N) [transfers (source)]
[institutions]   (1) ───||────────o< (0..N) [transfers (dest)]
[transfers]      (1) ───||────────|< (1..N) [transfer_units]
[blood_units]    (1) ───||────────o< (0..N) [transfer_units]
```
- **Distinct Dual Relations**: `transfers` maintains two separate foreign keys to `institutions`:
  1. `source_institution_id` (Dispatch facility)
  2. `destination_institution_id` (Receiving facility)
- **Constraint**: `CHECK (source_institution_id <> destination_institution_id)` structurally prohibits self-transfers.
- **Shipment Manifest**: A transfer cannot be dispatched without units (`1..N` cardinality enforced through transactional creation).

---

### 3.5 Monitoring, Analytics & Polymorphic Audit Trail
```text
[blood_units]   (1) ───||────────o< (0..N) [expiry_alerts]
[institutions]  (1) ───||────────o< (0..N) [demand_forecasts]
[users]         (1) ───||────────o< (0..N) [notifications]
[users]         (0..1) ─|o───────o< (0..N) [audit_logs]
```
- **Expiry Deduplication**: Enforced via partial index `WHERE resolved = false`.
- **Polymorphic Auditing**: `audit_logs` records `entity_type` (e.g. `'BLOOD_UNIT'`, `'TRANSFER'`, `'REQUEST'`) and `entity_id` (the target entity UUID). This intentional polymorphic pattern decouples audit logging from foreign key cascades so historical audit records remain intact even if the audited entity is purged.
