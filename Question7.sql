-- (a) Tables and seed data
CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INT NOT NULL REFERENCES customers(customer_id),
    reading_month DATE NOT NULL CHECK (reading_month = DATE_TRUNC('month', reading_month)::date),
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0),
    due_on DATE NOT NULL,
    CONSTRAINT chk_paid_not_exceed_charge CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Lombe Mbewe'),
    ('Mapalo Sichone'),
    ('Nchimunya Kaoma');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_first_tier NUMERIC;
    v_second_tier NUMERIC;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Units must be non-negative, got %', p_units;
    END IF;

    IF p_units = 0 THEN
        RETURN 0.00;
    END IF;

    v_first_tier := LEAST(p_units, 10::NUMERIC) * 5.00;
    v_second_tier := GREATEST(p_units - 10::NUMERIC, 0::NUMERIC) * 8.00;

    RETURN ROUND((v_first_tier + v_second_tier)::NUMERIC, 2);
END;
$$;

-- (d) Trigger (created before loading readings)
CREATE OR REPLACE FUNCTION trg_fn_readings_check_order()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be less than previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_readings_before_ins_upd
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_readings_check_order();

-- Seed 6 readings covering 0, 10, and >10 units across 3 customers
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100, 100), -- 0 units
    (1, DATE '2026-10-01', 100, 110), -- 10 units
    (2, DATE '2026-09-01', 50,  65),  -- 15 units
    (2, DATE '2026-10-01', 65,  65),  -- 0 units
    (3, DATE '2026-09-01', 200, 210), -- 10 units
    (3, DATE '2026-10-01', 210, 232); -- 22 units

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev NUMERIC(12,2);
    v_curr NUMERIC(12,2);
    v_charge NUMERIC(12,2);
    v_exists INT;
BEGIN
    SELECT previous_reading, current_reading
    INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    SELECT COUNT(*) INTO v_exists
    FROM bills
    WHERE reading_id = p_reading_id;

    IF v_exists > 0 THEN
        RAISE EXCEPTION 'Bill already exists for reading_id: %', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on)
WHERE amount_paid < charge;

SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;

EXPLAIN
SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;

-- (g) Refresh procedure & scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT
        CURRENT_DATE,
        COALESCE(SUM(charge - amount_paid), 0.00)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
    SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule(
    'refresh_receivables_snapshot',
    '30 0 * * *',
    $$CALL pr_refresh_receivables();$$
);
