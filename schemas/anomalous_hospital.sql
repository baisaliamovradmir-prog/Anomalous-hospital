BEGIN;

CREATE TABLE public.patient (
    patient_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    birth_date date NOT NULL,
    sex text NOT NULL,
    phone bigint CHECK (phone BETWEEN 10000000000 AND 99999999999),
    residence_address text,
    registration_address text,
    oms_policy varchar(16) UNIQUE CHECK (oms_policy ~ '^[0-9]{16}$'),
    insurer text,
    passport varchar(10) UNIQUE CHECK (passport ~ '^[0-9]{10}$'),
    birth_certificate text UNIQUE,
    snils varchar(11) UNIQUE CHECK (snils ~ '^[0-9]{11}$'),
    inn varchar(12) UNIQUE CHECK (inn ~ '^[0-9]{12}$')
);

CREATE TABLE public.medical_card (
    card_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id bigint NOT NULL UNIQUE REFERENCES public.patient (patient_id),
    card_number text NOT NULL UNIQUE,
    created_on date NOT NULL
);

CREATE TABLE public.office (
    office_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number text NOT NULL,
    building text NOT NULL,
    floor smallint NOT NULL,
    CONSTRAINT uq_office_location UNIQUE (building, floor, room_number)
);

CREATE TABLE public.doctor (
    doctor_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name text NOT NULL,
    sex text NOT NULL,
    phone bigint CHECK (phone BETWEEN 10000000000 AND 99999999999),
    email text,
    address text,
    passport varchar(10) UNIQUE CHECK (passport ~ '^[0-9]{10}$'),
    snils varchar(11) UNIQUE CHECK (snils ~ '^[0-9]{11}$'),
    inn varchar(12) UNIQUE CHECK (inn ~ '^[0-9]{12}$'),
    health_book_number bigint UNIQUE,
    academic_degree text
);

CREATE TABLE public.specialty (
    specialty_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL UNIQUE,
    description text
);

CREATE TABLE public.doctor_specialty (
    doctor_id bigint NOT NULL REFERENCES public.doctor (doctor_id),
    specialty_id bigint NOT NULL REFERENCES public.specialty (specialty_id),
    assigned_on date NOT NULL,
    PRIMARY KEY (doctor_id, specialty_id)
);

CREATE TABLE public.doctor_office (
    doctor_id bigint NOT NULL REFERENCES public.doctor (doctor_id),
    office_id bigint NOT NULL REFERENCES public.office (office_id),
    PRIMARY KEY (doctor_id, office_id)
);

CREATE TABLE public.appointment (
    appointment_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id bigint NOT NULL REFERENCES public.patient (patient_id),
    doctor_id bigint NOT NULL,
    office_id bigint NOT NULL,
    scheduled_on date NOT NULL,
    scheduled_at time without time zone NOT NULL,
    status text NOT NULL,
    author_name text NOT NULL,
    author_position text NOT NULL,
    CONSTRAINT fk_appointment_doctor_office FOREIGN KEY (doctor_id, office_id)
        REFERENCES public.doctor_office (doctor_id, office_id)
);

CREATE TABLE public.diagnosis (
    diagnosis_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    icd_code text NOT NULL UNIQUE,
    description text
);

CREATE TABLE public.visit (
    visit_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    appointment_id bigint NOT NULL UNIQUE REFERENCES public.appointment (appointment_id),
    card_id bigint NOT NULL REFERENCES public.medical_card (card_id),
    diagnosis_id bigint NOT NULL REFERENCES public.diagnosis (diagnosis_id),
    consultation_notes text NOT NULL
);

CREATE TABLE public.drug (
    drug_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name text NOT NULL,
    composition text NOT NULL,
    description text,
    dosage_form text NOT NULL,
    indications text,
    contraindications text,
    side_effects text,
    overdose text,
    age_guidance text,
    storage_conditions text,
    shelf_life_months smallint NOT NULL CHECK (shelf_life_months > 0),
    prescription_required boolean NOT NULL
);

CREATE TABLE public.prescription (
    prescription_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visit_id bigint NOT NULL REFERENCES public.visit (visit_id),
    drug_id bigint NOT NULL REFERENCES public.drug (drug_id),
    dosage text NOT NULL,
    frequency text NOT NULL,
    duration text NOT NULL
);

CREATE TABLE public.lab_order (
    lab_order_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visit_id bigint NOT NULL REFERENCES public.visit (visit_id),
    test_name text NOT NULL,
    ordered_on date NOT NULL,
    performed_on date,
    result text,
    status text NOT NULL,
    CONSTRAINT ck_lab_order_dates CHECK (performed_on IS NULL OR performed_on >= ordered_on)
);

CREATE TABLE public.sick_leave (
    sick_leave_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visit_id bigint NOT NULL UNIQUE REFERENCES public.visit (visit_id),
    leave_number varchar(12) NOT NULL UNIQUE CHECK (leave_number ~ '^[0-9]{12}$'),
    employer text,
    reason text NOT NULL,
    opened_on date NOT NULL,
    closed_on date,
    status text NOT NULL,
    CONSTRAINT ck_sick_leave_dates CHECK (closed_on IS NULL OR closed_on >= opened_on)
);

CREATE FUNCTION public.serialize_doctor_link_removal() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    -- Обновляем строку врача, чтобы два удаления его связей не прошли одновременно
    IF TG_OP = 'DELETE' OR NEW.doctor_id IS DISTINCT FROM OLD.doctor_id THEN
        UPDATE public.doctor SET full_name = full_name WHERE doctor_id = OLD.doctor_id;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER doctor_office_serialize_removal
    BEFORE DELETE OR UPDATE OF doctor_id ON public.doctor_office
    FOR EACH ROW EXECUTE FUNCTION public.serialize_doctor_link_removal();

CREATE TRIGGER doctor_specialty_serialize_removal
    BEFORE DELETE OR UPDATE OF doctor_id ON public.doctor_specialty
    FOR EACH ROW EXECUTE FUNCTION public.serialize_doctor_link_removal();

CREATE FUNCTION public.check_doctor_minimum_links() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    checked_doctor_id bigint;
BEGIN
    IF TG_TABLE_NAME = 'doctor' THEN
        checked_doctor_id := NEW.doctor_id;
    ELSE
        checked_doctor_id := OLD.doctor_id;
    END IF;

    IF NOT EXISTS (SELECT FROM public.doctor WHERE doctor_id = checked_doctor_id) THEN
        RETURN NULL;
    END IF;
    IF NOT EXISTS (SELECT FROM public.doctor_office WHERE doctor_id = checked_doctor_id) THEN
        RAISE EXCEPTION 'У врача % должен быть хотя бы один кабинет', checked_doctor_id
            USING ERRCODE = '23514', CONSTRAINT = 'doctor_requires_office';
    END IF;
    IF NOT EXISTS (SELECT FROM public.doctor_specialty WHERE doctor_id = checked_doctor_id) THEN
        RAISE EXCEPTION 'У врача % должна быть хотя бы одна специальность', checked_doctor_id
            USING ERRCODE = '23514', CONSTRAINT = 'doctor_requires_specialty';
    END IF;
    RETURN NULL;
END;
$$;

-- Проверяем кабинет и специальность в конце транзакции, чтобы их можно было добавить после врача
CREATE CONSTRAINT TRIGGER doctor_check_minimum_links
    AFTER INSERT OR UPDATE OF doctor_id ON public.doctor
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_doctor_minimum_links();

CREATE CONSTRAINT TRIGGER doctor_office_check_minimum_links
    AFTER DELETE OR UPDATE OF doctor_id ON public.doctor_office
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_doctor_minimum_links();

CREATE CONSTRAINT TRIGGER doctor_specialty_check_minimum_links
    AFTER DELETE OR UPDATE OF doctor_id ON public.doctor_specialty
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.check_doctor_minimum_links();

CREATE FUNCTION public.check_doctor_links_after_truncate() RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF EXISTS (SELECT FROM public.doctor) THEN
        RAISE EXCEPTION 'Нельзя очистить таблицу связей, пока в базе есть врачи'
            USING ERRCODE = '23514';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER doctor_office_check_truncate
    AFTER TRUNCATE ON public.doctor_office
    FOR EACH STATEMENT EXECUTE FUNCTION public.check_doctor_links_after_truncate();

CREATE TRIGGER doctor_specialty_check_truncate
    AFTER TRUNCATE ON public.doctor_specialty
    FOR EACH STATEMENT EXECUTE FUNCTION public.check_doctor_links_after_truncate();

CREATE FUNCTION public.check_visit_patient() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    appointment_patient bigint;
    card_patient bigint;
BEGIN
    -- Блокируем запись и карту на время проверки, чтобы их пациент не сменился параллельно
    UPDATE public.appointment SET patient_id = patient_id
    WHERE appointment_id = NEW.appointment_id
    RETURNING patient_id INTO appointment_patient;

    UPDATE public.medical_card SET patient_id = patient_id
    WHERE card_id = NEW.card_id
    RETURNING patient_id INTO card_patient;

    IF appointment_patient <> card_patient THEN
        RAISE EXCEPTION 'Запись на приём и медкарта принадлежат разным пациентам'
            USING ERRCODE = '23514', CONSTRAINT = 'visit_same_patient';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER visit_check_patient
    BEFORE INSERT OR UPDATE OF appointment_id, card_id ON public.visit
    FOR EACH ROW EXECUTE FUNCTION public.check_visit_patient();

CREATE FUNCTION public.check_linked_visits_patient() RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    changed_appointment bigint;
    changed_card bigint;
BEGIN
    IF TG_TABLE_NAME = 'appointment' THEN
        changed_appointment := NEW.appointment_id;
    ELSE
        changed_card := NEW.card_id;
    END IF;

    IF EXISTS (
        SELECT FROM public.visit v
        JOIN public.appointment a ON a.appointment_id = v.appointment_id
        JOIN public.medical_card m ON m.card_id = v.card_id
        WHERE (v.appointment_id = changed_appointment OR v.card_id = changed_card)
          AND a.patient_id <> m.patient_id
    ) THEN
        RAISE EXCEPTION 'Запись на приём и медкарта принадлежат разным пациентам'
            USING ERRCODE = '23514', CONSTRAINT = 'visit_same_patient';
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER appointment_check_visit_patient
    AFTER UPDATE OF patient_id ON public.appointment
    FOR EACH ROW WHEN (OLD.patient_id IS DISTINCT FROM NEW.patient_id)
    EXECUTE FUNCTION public.check_linked_visits_patient();

CREATE TRIGGER medical_card_check_visit_patient
    AFTER UPDATE OF patient_id ON public.medical_card
    FOR EACH ROW WHEN (OLD.patient_id IS DISTINCT FROM NEW.patient_id)
    EXECUTE FUNCTION public.check_linked_visits_patient();

COMMIT;
