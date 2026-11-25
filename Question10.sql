-- (a) Tables and seed data
CREATE TABLE students (
    student_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on DATE NOT NULL DEFAULT CURRENT_DATE,
    status VARCHAR(15) NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status VARCHAR(15) NOT NULL,
    new_status VARCHAR(15) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('SCH001', 'Kondwani Banda'),
    ('SCH002', 'Thandiwe Mwale'),
    ('SCH003', 'Chisomo Phiri');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 82.00, CURRENT_DATE - 5, 'PENDING'), -- qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'), -- lower boundary qualifies
    (2, 25, 3000.00, 70.00, CURRENT_DATE - 3, 'PENDING'), -- upper boundary qualifies
    (2, 26, 2500.00, 85.00, CURRENT_DATE - 2, 'PENDING'), -- age too high
    (3, 21, 3500.00, 80.00, CURRENT_DATE - 1, 'PENDING'), -- income too high
    (3, 19, 1500.00, 68.50, CURRENT_DATE,     'PENDING'); -- mark too low

-- (b) Function
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INT,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income, and mark must not be NULL';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Monthly income must be non-negative, got %', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Average mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000)
       AND (p_mark >= 70);
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_age INT;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(15);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % is already %', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_applications_status_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_applications_after_update_status
AFTER UPDATE OF status ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_fn_applications_status_audit();

-- (e) View
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_applications_status_submitted_on ON applications (status, submitted_on);

SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

EXPLAIN
SELECT application_id, student_id, average_mark, submitted_on
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

-- (g) Batch procedure & scheduled job (Monday 08:00)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

SELECT cron.schedule(
    'weekly_scholarship_assessment',
    '0 8 * * 1',
    $$CALL pr_assess_pending();$$
);
