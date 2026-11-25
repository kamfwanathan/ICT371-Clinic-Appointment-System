-- ICT371 Q4: Clinic Appointment Scheduling  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables
CREATE TABLE patients (
  patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                  CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL,
  attended_count  INT NOT NULL,
  cancelled_count INT NOT NULL
);

-- Concurrency backstop for the trigger below
CREATE UNIQUE INDEX uq_active_slot
  ON appointments (doctor_id, appointment_day, slot_time)
  WHERE status <> 'CANCELLED';

-- (d) Trigger: reject a clash with another non-cancelled appointment
CREATE OR REPLACE FUNCTION trg_check_slot_clash() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' AND EXISTS (
       SELECT 1 FROM appointments a
       WHERE a.doctor_id = NEW.doctor_id
         AND a.appointment_day = NEW.appointment_day
         AND a.slot_time = NEW.slot_time
         AND a.status <> 'CANCELLED'
         AND a.appointment_id IS DISTINCT FROM NEW.appointment_id  -- exclude row being changed
     ) THEN
    RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
      NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_check_slot_clash();

INSERT INTO patients (full_name) VALUES ('Mary Tembo'), ('John Phiri'), ('Grace Lungu');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Mwale'), ('Dr. Zulu');

-- Six appointments (direct insert so past dates are allowed; the cancelled one shares a slot legally)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
  (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
  (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
  (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
  (1, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
  (2, 3, CURRENT_DATE + 1, '11:00', 'BOOKED'),
  (3, 1, CURRENT_DATE,     '09:00', 'CANCELLED');

-- (b) Function
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
  END IF;
  RETURN (SELECT COUNT(*) FROM appointments
          WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED');
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
  END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
  END IF;
  INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- clash checked by trigger
END;
$$;

CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '12:00');
-- Tests:
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');   -- clash error
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00'); -- past date error
-- CALL pr_book_appointment(1, 1, CURRENT_DATE, '13:00');   -- bad slot error
-- SELECT fn_daily_load(1, CURRENT_DATE);                   -- 2

-- (e) View: only what is needed (no patient IDs, contact details etc.)
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED'
ORDER BY a.slot_time;

SELECT * FROM v_today_appointments;

-- (f) Non-unique composite index
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
-- Justification: the day-view for a doctor filters on both columns; the index goes
-- straight to that day's rows and then the doctor, avoiding a full table scan.
ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Summary procedure
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
  $cron$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- replaces, never duplicates
SELECT * FROM clinic_summary;
