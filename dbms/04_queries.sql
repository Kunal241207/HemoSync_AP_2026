-- HemoSync queries. PostgreSQL 16+.

-- Q01: Available inventory (FEFO)
SELECT
    bu."unit_code",
    i."name" AS "institution_name",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor",
    bu."volume_ml",
    bu."expiry_date",
    bu."expiry_date" - CURRENT_TIMESTAMP AS "time_until_expiry"
FROM "blood_units" AS bu
JOIN "institutions" AS i
    ON i."id" = bu."institution_id"
WHERE bu."inventory_status" = 'AVAILABLE'
  AND bu."testing_status" = 'PASSED'
  AND bu."release_status" = 'RELEASED'
  AND bu."expiry_date" > CURRENT_TIMESTAMP
ORDER BY bu."expiry_date" ASC, bu."created_at" ASC;

-- Q02: Inventory summary by institution and blood type
SELECT
    i."id" AS "institution_id",
    i."name" AS "institution_name",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor",
    COUNT(*) AS "unit_count",
    COALESCE(SUM(bu."volume_ml"), 0) AS "total_volume_ml",
    COUNT(*) FILTER (
        WHERE bu."inventory_status" = 'AVAILABLE'
          AND bu."testing_status" = 'PASSED'
          AND bu."release_status" = 'RELEASED'
          AND bu."expiry_date" > CURRENT_TIMESTAMP
    ) AS "eligible_unit_count"
FROM "institutions" AS i
JOIN "blood_units" AS bu
    ON bu."institution_id" = i."id"
GROUP BY
    i."id",
    i."name",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor"
ORDER BY i."name", bu."component_type", bu."abo_group", bu."rh_factor";

-- Q03: Open requests by clinical priority
SELECT
    br."id" AS "request_id",
    hospital."name" AS "hospital_name",
    creator."name" AS "created_by",
    br."requested_component",
    br."requested_abo",
    br."requested_rh",
    br."requested_quantity",
    br."urgency",
    br."status",
    br."required_by",
    br."required_by" - CURRENT_TIMESTAMP AS "time_remaining"
FROM "blood_requests" AS br
JOIN "institutions" AS hospital
    ON hospital."id" = br."hospital_id"
JOIN "users" AS creator
    ON creator."id" = br."created_by_id"
WHERE br."status" IN ('PENDING', 'VALIDATED', 'PARTIALLY_ALLOCATED', 'TRANSFER_PENDING')
ORDER BY
    CASE br."urgency"
        WHEN 'EMERGENCY' THEN 1
        WHEN 'URGENT' THEN 2
        WHEN 'ROUTINE' THEN 3
    END,
    br."required_by" ASC;

-- Q04: Request fulfilment and remaining quantity
SELECT
    br."id" AS "request_id",
    hospital."name" AS "hospital_name",
    br."requested_quantity",
    COUNT(a."id") FILTER (WHERE a."status" <> 'CANCELLED') AS "allocated_quantity",
    GREATEST(
        br."requested_quantity"
        - COUNT(a."id") FILTER (WHERE a."status" <> 'CANCELLED'),
        0
    ) AS "remaining_quantity",
    br."status"
FROM "blood_requests" AS br
JOIN "institutions" AS hospital
    ON hospital."id" = br."hospital_id"
LEFT JOIN "allocations" AS a
    ON a."request_id" = br."id"
GROUP BY
    br."id",
    hospital."name",
    br."requested_quantity",
    br."status"
ORDER BY "remaining_quantity" DESC, br."id";

-- Q05: Allocation audit trail
SELECT
    a."id" AS "allocation_id",
    a."status" AS "allocation_status",
    a."created_at" AS "allocated_at",
    br."id" AS "request_id",
    hospital."name" AS "destination_hospital",
    bu."unit_code",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor",
    bu."inventory_status" AS "unit_inventory_status",
    allocator."name" AS "allocated_by"
FROM "allocations" AS a
JOIN "blood_requests" AS br
    ON br."id" = a."request_id"
JOIN "institutions" AS hospital
    ON hospital."id" = br."hospital_id"
JOIN "blood_units" AS bu
    ON bu."id" = a."blood_unit_id"
JOIN "users" AS allocator
    ON allocator."id" = a."allocated_by_id"
ORDER BY a."created_at" DESC;

-- Q06: Transfer manifest and logistics status
SELECT
    t."id" AS "transfer_id",
    source_i."name" AS "source_institution",
    destination_i."name" AS "destination_institution",
    t."status",
    t."dispatched_at",
    t."received_at",
    COUNT(tu."id") AS "unit_count",
    COALESCE(
        ARRAY_AGG(bu."unit_code" ORDER BY bu."expiry_date")
            FILTER (WHERE bu."unit_code" IS NOT NULL),
        ARRAY[]::VARCHAR[]
    ) AS "unit_codes"
FROM "transfers" AS t
JOIN "institutions" AS source_i
    ON source_i."id" = t."source_institution_id"
JOIN "institutions" AS destination_i
    ON destination_i."id" = t."destination_institution_id"
LEFT JOIN "transfer_units" AS tu
    ON tu."transfer_id" = t."id"
LEFT JOIN "blood_units" AS bu
    ON bu."id" = tu."blood_unit_id"
GROUP BY
    t."id",
    source_i."name",
    destination_i."name",
    t."status",
    t."dispatched_at",
    t."received_at"
ORDER BY t."created_at" DESC;

-- Q07: Unresolved expiry alerts
SELECT
    ea."id" AS "alert_id",
    i."name" AS "institution_name",
    bu."unit_code",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor",
    bu."expiry_date",
    ea."severity",
    CEIL(EXTRACT(EPOCH FROM (bu."expiry_date" - CURRENT_TIMESTAMP)) / 86400)
        AS "days_until_expiry"
FROM "expiry_alerts" AS ea
JOIN "institutions" AS i
    ON i."id" = ea."institution_id"
JOIN "blood_units" AS bu
    ON bu."id" = ea."blood_unit_id"
WHERE ea."resolved" = false
ORDER BY
    CASE ea."severity"
        WHEN 'CRITICAL' THEN 1
        WHEN 'HIGH' THEN 2
        WHEN 'MEDIUM' THEN 3
        WHEN 'LOW' THEN 4
    END,
    bu."expiry_date";

-- Q08: Latest forecast by institution, component, and blood type
SELECT DISTINCT ON (
    df."institution_id",
    df."component_type",
    df."abo_group",
    df."rh_factor"
)
    df."institution_id",
    i."name" AS "institution_name",
    df."component_type",
    df."abo_group",
    df."rh_factor",
    df."forecast_date",
    df."horizon_days",
    df."predicted_demand",
    df."lower_bound",
    df."upper_bound",
    df."model_version"
FROM "demand_forecasts" AS df
JOIN "institutions" AS i
    ON i."id" = df."institution_id"
ORDER BY
    df."institution_id",
    df."component_type",
    df."abo_group",
    df."rh_factor",
    df."forecast_date" DESC,
    df."generated_at" DESC;

-- Q09: Institution workload and fulfilment rate
SELECT
    i."id" AS "hospital_id",
    i."name" AS "hospital_name",
    COUNT(br."id") AS "total_requests",
    COUNT(br."id") FILTER (WHERE br."status" = 'FULFILLED')
        AS "fulfilled_requests",
    COUNT(br."id") FILTER (WHERE br."status" IN (
        'PENDING', 'VALIDATED', 'PARTIALLY_ALLOCATED', 'TRANSFER_PENDING'
    )) AS "open_requests",
    ROUND(
        100.0 * COUNT(br."id") FILTER (WHERE br."status" = 'FULFILLED')
        / NULLIF(COUNT(br."id") FILTER (WHERE br."status" <> 'CANCELLED'), 0),
        2
    ) AS "fulfilment_rate_percent"
FROM "institutions" AS i
LEFT JOIN "blood_requests" AS br
    ON br."hospital_id" = i."id"
WHERE i."type" = 'HOSPITAL'
GROUP BY i."id", i."name"
ORDER BY "open_requests" DESC, "fulfilment_rate_percent" NULLS LAST;

-- Q10: Inventory status distribution
WITH statuses AS (
    SELECT unnest(enum_range(NULL::"InventoryStatus")) AS "inventory_status"
)
SELECT
    i."name" AS "institution_name",
    s."inventory_status",
    COUNT(bu."id") AS "unit_count"
FROM "institutions" AS i
CROSS JOIN statuses AS s
LEFT JOIN "blood_units" AS bu
    ON bu."institution_id" = i."id"
   AND bu."inventory_status" = s."inventory_status"
GROUP BY i."name", s."inventory_status"
ORDER BY i."name", s."inventory_status";

-- Q11: Forecast demand versus eligible inventory
WITH latest_forecasts AS (
    SELECT DISTINCT ON (
        "institution_id",
        "component_type",
        "abo_group",
        "rh_factor"
    )
        "institution_id",
        "component_type",
        "abo_group",
        "rh_factor",
        "predicted_demand",
        "forecast_date"
    FROM "demand_forecasts"
    ORDER BY "institution_id", "component_type", "abo_group", "rh_factor",
             "forecast_date" DESC,
             "generated_at" DESC
),
eligible_inventory AS (
    SELECT
        "institution_id",
        "component_type",
        "abo_group",
        "rh_factor",
        COUNT(*)::DOUBLE PRECISION AS "eligible_units"
    FROM "blood_units"
    WHERE "inventory_status" = 'AVAILABLE'
      AND "testing_status" = 'PASSED'
      AND "release_status" = 'RELEASED'
      AND "expiry_date" > CURRENT_TIMESTAMP
    GROUP BY "institution_id", "component_type", "abo_group", "rh_factor"
)
SELECT
    i."name" AS "institution_name",
    lf."component_type",
    lf."abo_group",
    lf."rh_factor",
    lf."forecast_date",
    lf."predicted_demand",
    COALESCE(ei."eligible_units", 0) AS "eligible_units",
    GREATEST(lf."predicted_demand" - COALESCE(ei."eligible_units", 0), 0)
        AS "projected_shortage"
FROM latest_forecasts AS lf
JOIN "institutions" AS i
    ON i."id" = lf."institution_id"
LEFT JOIN eligible_inventory AS ei
    ON ei."institution_id" = lf."institution_id"
   AND ei."component_type" = lf."component_type"
   AND ei."abo_group" = lf."abo_group"
   AND ei."rh_factor" = lf."rh_factor"
ORDER BY "projected_shortage" DESC, i."name", lf."component_type",
         lf."abo_group", lf."rh_factor";

-- Q12: FEFO rank by institution and blood type
SELECT
    bu."unit_code",
    i."name" AS "institution_name",
    bu."component_type",
    bu."abo_group",
    bu."rh_factor",
    bu."expiry_date",
    ROW_NUMBER() OVER (
        PARTITION BY
            bu."institution_id",
            bu."component_type",
            bu."abo_group",
            bu."rh_factor"
        ORDER BY bu."expiry_date", bu."created_at", bu."id"
    ) AS "fefo_rank"
FROM "blood_units" AS bu
JOIN "institutions" AS i
    ON i."id" = bu."institution_id"
WHERE bu."inventory_status" = 'AVAILABLE'
  AND bu."testing_status" = 'PASSED'
  AND bu."release_status" = 'RELEASED'
  AND bu."expiry_date" > CURRENT_TIMESTAMP;

-- Q13: Anomaly review queue
SELECT
    ae."id" AS "anomaly_id",
    i."name" AS "institution_name",
    ae."component_type",
    ae."date",
    ae."observed_value",
    ae."expected_min",
    ae."expected_max",
    ae."anomaly_type",
    ae."status",
    (
        SELECT COUNT(*)
        FROM "anomaly_events" AS related
        WHERE related."institution_id" = ae."institution_id"
          AND related."component_type" = ae."component_type"
          AND related."status" = 'OPEN'
    ) AS "open_anomalies_in_series"
FROM "anomaly_events" AS ae
JOIN "institutions" AS i
    ON i."id" = ae."institution_id"
WHERE ae."status" IN ('OPEN', 'ACKNOWLEDGED')
ORDER BY ae."date" DESC, ae."created_at" DESC;

-- Q14: Daily audit activity
SELECT
    COALESCE(i."name", 'Platform-wide') AS "institution_name",
    DATE_TRUNC('day', al."created_at") AS "activity_day",
    COUNT(*) AS "audit_event_count",
    COUNT(*) FILTER (WHERE al."action" = 'ALLOCATE') AS "allocation_events",
    COUNT(*) FILTER (WHERE al."action"::TEXT LIKE 'TRANSFER_%') AS "transfer_events",
    COUNT(DISTINCT al."actor_id") AS "active_actors"
FROM "audit_logs" AS al
LEFT JOIN "institutions" AS i
    ON i."id" = al."institution_id"
GROUP BY
    COALESCE(i."name", 'Platform-wide'),
    DATE_TRUNC('day', al."created_at")
ORDER BY "activity_day" DESC, "institution_name";

-- Q15: Data-integrity exceptions
SELECT
    'AVAILABLE_UNIT_WITHOUT_RELEASE' AS "exception_type",
    bu."id"::TEXT AS "record_id",
    'An available unit must be tested PASSED and released RELEASED.'
        AS "details"
FROM "blood_units" AS bu
WHERE bu."inventory_status" = 'AVAILABLE'
  AND (
      bu."testing_status" <> 'PASSED'
      OR bu."release_status" <> 'RELEASED'
  )

UNION ALL

SELECT
    'EXPIRED_UNIT_STILL_AVAILABLE' AS "exception_type",
    bu."id"::TEXT AS "record_id",
    'An expired unit must not remain available for allocation.' AS "details"
FROM "blood_units" AS bu
WHERE bu."inventory_status" = 'AVAILABLE'
  AND bu."expiry_date" <= CURRENT_TIMESTAMP

UNION ALL

SELECT
    'TRANSFER_TIME_ORDER_VIOLATION' AS "exception_type",
    t."id"::TEXT AS "record_id",
    'A transfer receipt cannot precede its dispatch.' AS "details"
FROM "transfers" AS t
WHERE t."received_at" IS NOT NULL
  AND t."dispatched_at" IS NOT NULL
  AND t."received_at" < t."dispatched_at"

UNION ALL

SELECT
    'ALLOCATION_UNIT_MISSING' AS "exception_type",
    a."id"::TEXT AS "record_id",
    'Every allocation must reference an existing blood unit.' AS "details"
FROM "allocations" AS a
LEFT JOIN "blood_units" AS bu
    ON bu."id" = a."blood_unit_id"
WHERE bu."id" IS NULL

ORDER BY "exception_type", "record_id";
