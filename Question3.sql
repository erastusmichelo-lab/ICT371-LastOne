-- (a) Tables and seed data
CREATE TABLE books (
    book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on DATE NOT NULL,
    due_on DATE NOT NULL,
    returned_on DATE NULL,
    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
    CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database Systems'),
    ('Operating Systems'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Alice Lungu', CURRENT_DATE - 15, CURRENT_DATE - 5, NULL, 0.00),               -- open overdue
    (2, 'Brian Zulu', CURRENT_DATE - 10, CURRENT_DATE - 2, CURRENT_DATE - 2, 0.00),   -- returned on time
    (1, 'Clara Daka', CURRENT_DATE - 12, CURRENT_DATE - 4, CURRENT_DATE - 1, 6.00),   -- returned late (3 days * K2)
    (3, 'David Nkandu', CURRENT_DATE - 5, CURRENT_DATE + 5, NULL, 0.00),              -- active, not due
    (2, 'Esther Mulenga', CURRENT_DATE - 20, CURRENT_DATE - 10, NULL, 0.00),          -- open overdue
    (3, 'Frank Tembo', CURRENT_DATE - 8, CURRENT_DATE - 1, CURRENT_DATE - 1, 0.00);   -- returned on due date

-- (b) Function
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INT;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_effective_date := CASE
        WHEN v_returned_on IS NOT NULL THEN LEAST(p_as_of, v_returned_on)
        ELSE p_as_of
    END;

    v_overdue_days := GREATEST(0, (v_effective_date - v_due_on));
    RETURN (v_overdue_days * 2)::NUMERIC(10,2);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed_on DATE;
    v_due_on DATE;
    v_returned_on DATE;
    v_fine NUMERIC(10,2);
BEGIN
    SELECT borrowed_on, due_on, returned_on
    INTO v_borrowed_on, v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % is already returned on %', p_loan_id, v_returned_on;
    END IF;

    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date % cannot be before borrowed date %', p_returned_on, v_borrowed_on;
    END IF;

    v_fine := GREATEST(0, (p_returned_on - v_due_on)) * 2;

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_loans_returned_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loans_after_update_returned
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_fn_loans_returned_audit();

-- (e) View
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_loans_book_unreturned ON loans (book_id)
WHERE returned_on IS NULL;

SELECT loan_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

EXPLAIN
SELECT loan_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Refresh procedure & scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT
        p_as_of,
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0.00)
    FROM loans
    WHERE returned_on IS NULL
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;
END;
$$;

SELECT cron.schedule(
    'refresh_overdue_summary',
    '10 0 * * *',
    $$CALL pr_refresh_overdue(CURRENT_DATE);$$
);
