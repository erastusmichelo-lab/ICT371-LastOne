-- (a) Tables and seed data
CREATE TABLE patients (
    patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id INT NOT NULL REFERENCES patients(patient_id),
    doctor_id INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL CHECK (slot_time IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00')),
    status VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INT NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count INT NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INT NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Patience Chirwa'),
    ('Kelvin Sakala'),
    ('Naomi Mumba');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Mwape'),
    ('Dr. Nyirenda'),
    ('Dr. Bwalya');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql AS $$
DECLARE
    v_count INT;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_fn_appointments_no_clash()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_conflict INT;
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        SELECT COUNT(*) INTO v_conflict
        FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND (TG_OP = 'INSERT' OR appointment_id <> NEW.appointment_id);

        IF v_conflict > 0 THEN
            RAISE EXCEPTION 'Slot clash for doctor % on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_before_ins_upd
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointments_no_clash();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id INT,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book appointment in the past: %', p_day;
    END IF;

    IF p_slot NOT IN ('09:00:00', '10:00:00', '11:00:00', '12:00:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time: %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Seed 6 non-clashing appointments
CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, '10:00:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, '09:00:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '11:00:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, '12:00:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '09:00:00');

-- (e) View
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time;

-- (f) Index, query & EXPLAIN
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Refresh procedure & scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT
        p_day,
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule(
    'refresh_clinic_summary',
    '0 1 * * *',
    $$CALL pr_refresh_clinic_summary((CURRENT_DATE - INTERVAL '1 day')::date);$$
);
