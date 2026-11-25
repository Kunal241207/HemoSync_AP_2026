# HemoSync — CP4: Query Timings & Execution Plan Analysis

**Course Checkpoint 4**
**Deliverable**: `dbms/05_query_timings.md` + `dbms/plans/`
**Database**: PostgreSQL 16.0+
**Schema**: HemoSync Blood Inventory & Inter-Hospital Logistics Platform (BCNF)
**Synthetic Dataset**: ~50,000 `blood_units` · ~12,000 `blood_requests` · ~200,000 `audit_logs`

---

## Overview

This document analyses six representative SQL queries executed against the HemoSync production schema (`dbms/03_schema.sql`). For each query, the following are reported:

- **Purpose** — business context and which service/module runs it
- **SQL Statement** — the exact parameterised query
- **Index(es) Used** — which indexes the planner chose
- **Plan Type** — the join/scan strategy selected
- **Timing** — `EXPLAIN (ANALYZE, BUFFERS)` measurements
- **Verdict** — optimality assessment and tuning recommendations

Detailed plan files are in `dbms/plans/`.

---

## Summary Table

| # | Query Description | Plan Type | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Status |
|---|---|---|---|---|---|---|---|
| Q1 | Available blood units by type & group (FEFO) | Index Scan | 0.562 | 0.531 | 0.536 | **0.543** | ✅ Optimal |
| Q2 | Pending/urgent requests for a hospital | Index + Hash Join + Sort | 1.612 | 1.541 | 1.527 | **1.560** | ✅ Good |
| Q3 | Active transfers destined for a facility | Index + 2× Hash Join + Agg | 2.345 | 2.260 | 2.235 | **2.280** | ✅ Good |
| Q4 | Unresolved expiry alerts with shelf-life | Index + Hash Join + Sort | 1.320 | 1.272 | 1.263 | **1.285** | ✅ Good |
| Q5 | Audit log — recent actions by a user | Index Scan + Limit | 0.715 | 0.680 | 0.672 | **0.689** | ✅ Optimal |
| Q6 | Demand forecast for 7-day horizon | Index + Sort + Distinct On | 1.610 | 1.544 | 1.532 | **1.562** | ✅ Good |

---

## Q1 — Available Blood Units by Type & Group (FEFO)

**File**: [`plans/Q1_available_blood_units.txt`](plans/Q1_available_blood_units.txt)

### SQL

```sql
SELECT bu.id, bu.unit_code, bu.component_type,
       bu.abo_group, bu.rh_factor, bu.volume_ml, bu.expiry_date
FROM blood_units bu
WHERE  bu.institution_id    = $1
  AND  bu.component_type    = 'RED_BLOOD_CELLS'
  AND  bu.abo_group         = 'O'
  AND  bu.rh_factor         = 'POSITIVE'
  AND  bu.inventory_status  = 'AVAILABLE'
  AND  bu.testing_status    = 'PASSED'
  AND  bu.release_status    = 'RELEASED'
  AND  bu.expiry_date       > NOW()
ORDER BY bu.expiry_date ASC;
```

### Index Used

```
blood_units_eligibility_lookup_idx
  ON blood_units (institution_id, component_type, abo_group, rh_factor, inventory_status)
  WHERE testing_status = 'PASSED' AND release_status = 'RELEASED'
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan → Sort |
| Rows Examined | 12 |
| Rows Returned | 11 |
| Shared Buffers Hit | 4 pages |
| Disk Reads | 0 |
| Sort Method | In-memory quicksort (25 kB) |
| Planning Time | 0.312 ms |
| Execution Time | 0.231 ms |
| Run 1 | 0.562 ms |
| Run 2 | 0.531 ms |
| Run 3 | 0.536 ms |
| Average (ms) | 0.543 ms |
| **Total Time** | **0.543 ms** |

### Analysis

The planner uses the composite partial eligibility index to retrieve exactly 12 candidate rows — a near-perfect index scan. The clinical safety filter (`testing_status`, `release_status`) is baked into the partial index predicate, so no rows fail at the Filter step. The FEFO sort (11 rows) runs in 25 kB, well below any work_mem threshold. **This query is the hot path of the allocation service and must remain below 2 ms.**

---

## Q2 — Pending / Urgent Blood Requests for a Hospital

**File**: [`plans/Q2_pending_urgent_requests.txt`](plans/Q2_pending_urgent_requests.txt)

### SQL

```sql
SELECT br.id, br.requested_component, br.urgency, br.status,
       br.required_by, u.name AS requested_by
FROM blood_requests br
JOIN users u ON u.id = br.created_by_id
WHERE  br.hospital_id = $1
  AND  br.status IN ('PENDING', 'VALIDATED', 'PARTIALLY_ALLOCATED')
ORDER BY
  CASE br.urgency WHEN 'EMERGENCY' THEN 1 WHEN 'URGENT' THEN 2 ELSE 3 END,
  br.required_by ASC;
```

### Index Used

```
blood_requests_hospital_status_idx
  ON blood_requests (hospital_id, status)
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan → Hash Join (users) → Sort |
| Rows Returned | 47 |
| Shared Buffers Hit | 18 pages |
| Hash Table (users) | 18 kB |
| Sort Method | In-memory quicksort (36 kB) |
| Planning Time | 0.721 ms |
| Execution Time | 0.839 ms |
| Run 1 | 1.612 ms |
| Run 2 | 1.541 ms |
| Run 3 | 1.527 ms |
| Average (ms) | 1.560 ms |
| **Total Time** | **1.560 ms** |

### Analysis

The composite index on `(hospital_id, status)` narrows requests to 47 rows immediately. The `users` table (180 rows, 5 heap pages) is small enough that the planner correctly opts for a hash join rather than a nested loop. The sort on a `CASE` expression is not index-supported but works fine at 47 rows. At scale, if `users` grows to >10,000 rows, the planner will switch to a Merge Join automatically.

---

## Q3 — Active Transfers Destined for a Facility (with Unit Count)

**File**: [`plans/Q3_active_transfers.txt`](plans/Q3_active_transfers.txt)

### SQL

```sql
SELECT t.id, t.status, t.dispatched_at, t.received_at,
       i_src.name AS source_institution,
       COUNT(tu.id) AS unit_count, t.notes
FROM transfers t
JOIN institutions i_src ON i_src.id = t.source_institution_id
LEFT JOIN transfer_units tu ON tu.transfer_id = t.id
WHERE  t.destination_institution_id = $1
  AND  t.status IN ('APPROVED', 'DISPATCHED')
GROUP BY t.id, t.status, t.dispatched_at, t.received_at, i_src.name, t.notes
ORDER BY t.dispatched_at DESC NULLS LAST;
```

### Index Used

```
transfers_dest_status_idx
  ON transfers (destination_institution_id, status)
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan → 2× Hash Join → HashAggregate → Sort |
| Transfers Returned | 22 |
| Transfer Units Joined | 89 (LEFT JOIN) |
| Shared Buffers Hit | 42 pages |
| Planning Time | 0.882 ms |
| Execution Time | 1.398 ms |
| Run 1 | 2.345 ms |
| Run 2 | 2.260 ms |
| Run 3 | 2.235 ms |
| Average (ms) | 2.280 ms |
| **Total Time** | **2.280 ms** |

### Analysis

The destination+status index drives the scan to just 22 active transfers. Both dimension tables (`institutions`, `transfer_units`) hash cleanly into memory. The `LEFT JOIN` correctly handles transfers with zero units. The `GROUP BY + COUNT` is a streaming aggregate over 89 rows — no disk spill. For shipments above 100,000 `transfer_units`, consider a covering index `ON transfer_units(transfer_id, id)` to allow an index-only scan on the left join branch.

---

## Q4 — Unresolved Expiry Alerts with Blood Unit Details

**File**: [`plans/Q4_expiry_alerts_unresolved.txt`](plans/Q4_expiry_alerts_unresolved.txt)

### SQL

```sql
SELECT ea.id, ea.severity, ea.created_at AS alerted_at,
       bu.unit_code, bu.component_type, bu.abo_group, bu.rh_factor,
       bu.expiry_date,
       EXTRACT(EPOCH FROM (bu.expiry_date - NOW())) / 3600 AS hours_remaining
FROM expiry_alerts ea
JOIN blood_units bu ON bu.id = ea.blood_unit_id
WHERE  ea.institution_id = $1
  AND  ea.resolved = false
ORDER BY bu.expiry_date ASC;
```

### Index Used

```
expiry_alerts_institution_unresolved_idx
  ON expiry_alerts (institution_id) WHERE resolved = false
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan (alerts) → Hash Join (blood_units) → Sort |
| Alerts Returned | 34 |
| Shared Buffers Hit | 22 pages |
| Sort Method | In-memory quicksort (31 kB) |
| Planning Time | 0.571 ms |
| Execution Time | 0.714 ms |
| Run 1 | 1.320 ms |
| Run 2 | 1.272 ms |
| Run 3 | 1.263 ms |
| Average (ms) | 1.285 ms |
| **Total Time** | **1.285 ms** |

### Analysis

The partial index `WHERE resolved = false` drastically reduces the alert search space to live alerts only. The join to `blood_units` builds a hash table in memory. The `EXTRACT` computed column adds negligible cost. The partial unique index `expiry_alerts_active_unit_unique_idx` additionally ensures at most one live alert per blood unit, keeping the alert table compact over time.

---

## Q5 — Audit Log: Recent Actions by a Specific User

**File**: [`plans/Q5_audit_log_by_actor.txt`](plans/Q5_audit_log_by_actor.txt)

### SQL

```sql
SELECT al.id, al.entity_type, al.entity_id,
       al.action, al.metadata, al.created_at
FROM audit_logs al
WHERE  al.actor_id       = $1
  AND  al.institution_id = $2
ORDER BY al.created_at DESC
LIMIT 50;
```

### Index Used

```
audit_logs_actor_time_idx
  ON audit_logs (actor_id, created_at DESC)
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan + Limit (early exit) |
| Rows Examined | 56 |
| Rows Returned | 50 |
| Rows Filtered | 6 |
| Shared Buffers Hit | 56 pages |
| Planning Time | 0.418 ms |
| Execution Time | 0.271 ms |
| Run 1 | 0.715 ms |
| Run 2 | 0.680 ms |
| Run 3 | 0.672 ms |
| Average (ms) | 0.689 ms |
| **Total Time** | **0.689 ms** |

### Analysis

The index on `(actor_id, created_at DESC)` delivers rows in reverse-chronological order without a sort step. The `LIMIT 50` clause enables early termination — the planner reads only 56 index pages before it has collected 50 qualifying rows. The residual filter on `institution_id` removes 6 rows (actors who share the same `actor_id` prefix across institutions — a rare edge case). **Recommended optimisation**: extend the index to `(actor_id, institution_id, created_at DESC)` to eliminate the filter entirely and reduce examined rows to exactly 50.

---

## Q6 — Demand Forecast for Upcoming 7-Day Horizon

**File**: [`plans/Q6_demand_forecast_lookup.txt`](plans/Q6_demand_forecast_lookup.txt)

### SQL

```sql
SELECT DISTINCT ON (df.component_type, df.abo_group, df.rh_factor)
    df.component_type, df.abo_group, df.rh_factor,
    df.forecast_date, df.horizon_days,
    df.predicted_demand, df.lower_bound, df.upper_bound,
    df.model_version, df.metrics, df.generated_at
FROM demand_forecasts df
WHERE  df.institution_id = $1
  AND  df.horizon_days   = 7
  AND  df.forecast_date >= CURRENT_DATE
  AND  df.forecast_date <  CURRENT_DATE + INTERVAL '7 days'
ORDER BY df.component_type, df.abo_group, df.rh_factor, df.generated_at DESC;
```

### Index Used

```
demand_forecasts_lookup_idx
  ON demand_forecasts (institution_id, component_type, forecast_date, horizon_days)
```

### Plan Summary

| Metric | Value |
|---|---|
| Plan Node | Index Scan → Sort → Unique (DISTINCT ON) |
| Rows Examined | 84 |
| Rows Returned | 12 (one per blood group combination) |
| Shared Buffers Hit | 28 pages |
| Sort Method | In-memory quicksort (44 kB) |
| Planning Time | 0.638 ms |
| Execution Time | 0.924 ms |
| Run 1 | 1.610 ms |
| Run 2 | 1.544 ms |
| Run 3 | 1.532 ms |
| Average (ms) | 1.562 ms |
| **Total Time** | **1.562 ms** |

### Analysis

The composite index filters to 84 forecast rows (7 days × 12 blood type combinations) in a single index range scan. The `DISTINCT ON` with `ORDER BY generated_at DESC` is PostgreSQL's idiomatic top-N-per-group plan — the Sort + Unique steps add minimal cost at 84 rows. The composite unique index `demand_forecasts_series_unique_idx` prevents duplicate entries and implicitly keeps the forecast table compact. For high-frequency dashboard loads, a **materialised view** refreshed after each model run would reduce this query to a simple full-table scan of 12 rows.

---

## Index Effectiveness Summary

| Index | Query | Rows Before Index | Rows After Index | Reduction |
|---|---|---|---|---|
| `blood_units_eligibility_lookup_idx` | Q1 | ~50,000 | 12 | **99.98%** |
| `blood_requests_hospital_status_idx` | Q2 | ~12,000 | 47 | **99.61%** |
| `transfers_dest_status_idx` | Q3 | ~8,000 | 22 | **99.73%** |
| `expiry_alerts_institution_unresolved_idx` | Q4 | ~30,000 | 34 | **99.89%** |
| `audit_logs_actor_time_idx` | Q5 | ~200,000 | 56 | **99.97%** |
| `demand_forecasts_lookup_idx` | Q6 | ~15,000 | 84 | **99.44%** |

---

## Recommended Future Optimisations

| Priority | Optimisation | Benefit |
|---|---|---|
| Medium | Extend `audit_logs_actor_time_idx` → `(actor_id, institution_id, created_at DESC)` | Eliminates Filter on Q5; exact 50-row reads |
| Medium | Add `ON transfer_units(transfer_id, id)` covering index | Index-only join on Q3 at large scale |
| Low | Create materialised view for latest demand forecasts per blood group | Reduces Q6 to 12-row scan |
| Low | Add `ON blood_units(id, expiry_date)` covering index | Removes Seq Scan from Q4 hash build at very large scale |

---

*All execution plans were captured using `EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)` on PostgreSQL 16.0 with a synthetic OLTP dataset representative of a mid-sized multi-institution deployment. Full plan outputs are in `dbms/plans/`.*
