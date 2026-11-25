-- (a) Tables and seed data
CREATE TABLE vehicles (
    vehicle_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration VARCHAR(25) NOT NULL UNIQUE,
    current_odometer NUMERIC(12,1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,1) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_odometer_valid CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL DEFAULT CURRENT_DATE,
    start_odometer NUMERIC(12,1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer NUMERIC(12,1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,1) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on DATE NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABZ 101', 15200.0, 10000.0), -- already >= 5,000 km since service
    ('ABZ 202', 23500.0, 20000.0), -- 3,500 km since service
    ('ABZ 303', 8000.0,  8000.0);  -- freshly serviced

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
DECLARE
    v_curr NUMERIC(12,1);
    v_last NUMERIC(12,1);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_trips_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_curr_odo NUMERIC(12,1);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'start_odometer (%) must match vehicle current_odometer (%)',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trips_before_insert();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on DATE,
    p_start NUMERIC(12,1),
    p_end NUMERIC(12,1)
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- Load 6 trips via procedure after trigger installation
CALL pr_record_trip(1, CURRENT_DATE - 5, 15200.0, 15400.0);
CALL pr_record_trip(1, CURRENT_DATE - 2, 15400.0, 15650.0);
CALL pr_record_trip(2, CURRENT_DATE - 4, 23500.0, 24200.0);
CALL pr_record_trip(2, CURRENT_DATE - 1, 24200.0, 25100.0); -- crosses 5,000 km threshold
CALL pr_record_trip(3, CURRENT_DATE - 3, 8000.0,  8600.0);
CALL pr_record_trip(3, CURRENT_DATE,     8600.0,  9100.0);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 14 AND CURRENT_DATE;

-- (g) Refresh procedure & scheduled job (Monday 06:00)
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE sa.vehicle_id = v.vehicle_id
      AND (v.current_odometer - v.last_service_odometer) < 5000;

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;
END;
$$;

SELECT cron.schedule(
    'weekly_service_alerts',
    '0 6 * * 1',
    $$CALL pr_refresh_service_alerts();$$
);
