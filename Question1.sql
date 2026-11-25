-- (a) Tables and seed data
CREATE TABLE medicines (
    medicine_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL,
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity INT NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty INT NOT NULL,
    new_qty INT NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date DATE PRIMARY KEY,
    total_qty INT NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 25.00, 100),
    ('Paracetamol 500mg', 5.00, 8),
    ('Ibuprofen 400mg', 10.00, 40);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity INT,
    p_sold_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price, stock_qty
    INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: available %, requested %',
            p_medicine_id, v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_medicines_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
        INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
        VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_medicines_after_update_stock
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
EXECUTE FUNCTION trg_fn_medicines_stock_audit();

-- Load 6 valid sales through the procedure
CALL pr_record_sale(1, 5, CURRENT_DATE - 1);
CALL pr_record_sale(1, 3, CURRENT_DATE - 1);
CALL pr_record_sale(2, 2, CURRENT_DATE - 1);
CALL pr_record_sale(3, 4, CURRENT_DATE);
CALL pr_record_sale(3, 6, CURRENT_DATE);
CALL pr_record_sale(1, 2, CURRENT_DATE);

-- (e) View & query
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f) Index & EXPLAIN
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);

EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Refresh procedure & scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT
        p_day,
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0.00)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- pg_cron daily at 00:15 for previous day
SELECT cron.schedule(
    'refresh_daily_sales',
    '15 0 * * *',
    $$CALL pr_refresh_sales((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
