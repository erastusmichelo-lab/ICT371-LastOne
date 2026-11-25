-- (a) Tables and seed data
CREATE TABLE employees (
    employee_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL DEFAULT 0.00 CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month DATE NOT NULL CHECK (pay_month = DATE_TRUNC('month', pay_month)::date),
    gross_pay NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Dr. Chileshe', 15000.00, 3000.00, 2000.00, TRUE),
    ('Prof. Kapwepwe', 22000.00, 4500.00, 3500.00, TRUE),
    ('Mr. Musonda', 9000.00, 1000.00, 1200.00, FALSE); -- inactive

-- (b) Function
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_ded
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) computed for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
    v_gross NUMERIC(12,2);
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month (%) must be the first day of a month', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance, deduction
        FROM employees
        WHERE active = TRUE
    LOOP
        v_gross := rec.basic_salary + rec.allowance;
        v_net := fn_net_pay(rec.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- Seed two payroll months
CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 months')::date);
CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::date);

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_employees_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_employees_after_update_salary
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_fn_employees_salary_audit();

-- (e) View
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month DESC, e.full_name;

-- (f) Index & EXPLAIN
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

EXPLAIN
SELECT p.employee_id, e.full_name, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
WHERE p.pay_month = DATE '2026-10-01';

-- (g) Scheduled job & inspection queries
SELECT cron.schedule(
    'monthly_payroll_processing',
    '0 2 1 * *',
    $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date);$$
);

-- Inspect scheduled job and run history
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll_processing';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_processing')
ORDER BY start_time DESC;
