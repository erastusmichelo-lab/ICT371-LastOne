-- (a) Tables and seed data
CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    room_id INT NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE NULL,
    status VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL CHECK (occupied_beds >= 0),
    free_beds INT NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('S101', 'Grace Kunda'),
    ('S102', 'Henry Silwizya'),
    ('S103', 'Ivy Chama'),
    ('S104', 'Joseph Zimba');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R1', 2), -- will be full
    ('R2', 3), -- will be partly occupied
    ('R3', 2); -- empty

-- (b) Function
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INT;
    v_active_count INT;
BEGIN
    SELECT capacity INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active_count
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_active_count;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_allocations_validate()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_capacity INT;
    v_active_room_beds INT;
    v_active_student_allocs INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id;

        SELECT COUNT(*) INTO v_active_room_beds
        FROM allocations
        WHERE room_id = NEW.room_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_active_room_beds + 1 > v_capacity THEN
            RAISE EXCEPTION 'Room % has no free beds (capacity %)', NEW.room_id, v_capacity;
        END IF;

        SELECT COUNT(*) INTO v_active_student_allocs
        FROM allocations
        WHERE student_id = NEW.student_id
          AND status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR allocation_id <> NEW.allocation_id);

        IF v_active_student_allocs > 0 THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocations_before_ins_upd
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocations_validate();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INT,
    p_room_id INT,
    p_allocated_on DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_free INT;
    v_has_active INT;
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT capacity INTO v_free
    FROM rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_has_active
    FROM allocations
    WHERE student_id = p_student_id
      AND status = 'ACTIVE';

    IF v_has_active > 0 THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- Seed allocations: R1 full (2/2), R2 partly occupied (1/3), R3 empty (0/2), plus an ENDED row
CALL pr_allocate_room(1, 1, CURRENT_DATE - 10);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 9);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 8);
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 2, CURRENT_DATE - 30, CURRENT_DATE - 15, 'ENDED');

-- (e) View
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity
ORDER BY r.room_number;

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_allocations_active_room ON allocations (room_id)
WHERE status = 'ACTIVE';

SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- (g) Refresh procedure & scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
        r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;
END;
$$;

SELECT cron.schedule(
    'refresh_hostel_occupancy',
    '55 23 * * *',
    $$CALL pr_refresh_occupancy();$$
);
