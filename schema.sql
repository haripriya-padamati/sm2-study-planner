CREATE TABLE subjects (
    subject_id   SERIAL PRIMARY KEY,
    name         VARCHAR(100) NOT NULL,
    description  TEXT,
    created_at   TIMESTAMP DEFAULT NOW()
);

CREATE TABLE topics (
    topic_id           SERIAL PRIMARY KEY,
    subject_id         INTEGER NOT NULL REFERENCES subjects(subject_id),
    name               VARCHAR(150) NOT NULL,
    description        TEXT,
    ease_factor        NUMERIC(4,2) NOT NULL DEFAULT 2.5,
    repetition_count   INTEGER NOT NULL DEFAULT 0,
    interval_days      INTEGER NOT NULL DEFAULT 0,
    last_reviewed_at   TIMESTAMP NULL,
    next_review_date   DATE NOT NULL DEFAULT CURRENT_DATE,
    created_at         TIMESTAMP DEFAULT NOW()
);

CREATE TABLE study_sessions (
    session_id       SERIAL PRIMARY KEY,
    topic_id         INTEGER NOT NULL REFERENCES topics(topic_id),
    session_date     TIMESTAMP NOT NULL DEFAULT NOW(),
    quality_rating   SMALLINT NOT NULL CHECK (quality_rating BETWEEN 0 AND 5),
    notes            TEXT
);

CREATE TABLE performance_logs (
    log_id                       SERIAL PRIMARY KEY,
    session_id                   INTEGER NOT NULL REFERENCES study_sessions(session_id),
    topic_id                     INTEGER NOT NULL REFERENCES topics(topic_id),
    previous_ease_factor         NUMERIC(4,2),
    new_ease_factor              NUMERIC(4,2),
    previous_interval_days       INTEGER,
    new_interval_days            INTEGER,
    previous_repetition_count    INTEGER,
    new_repetition_count         INTEGER,
    previous_next_review_date    DATE,
    new_next_review_date         DATE,
    logged_at                    TIMESTAMP DEFAULT NOW()
);

CREATE INDEX idx_topics_subject_id ON topics(subject_id);
CREATE INDEX idx_topics_next_review_date ON topics(next_review_date);
CREATE INDEX idx_study_sessions_topic_id ON study_sessions(topic_id);
CREATE INDEX idx_performance_logs_topic_id ON performance_logs(topic_id);
CREATE INDEX idx_performance_logs_session_id ON performance_logs(session_id);

CREATE VIEW due_today AS
SELECT
    t.topic_id,
    t.name AS topic_name,
    s.subject_id,
    s.name AS subject_name,
    t.ease_factor,
    t.repetition_count,
    t.interval_days,
    t.last_reviewed_at,
    t.next_review_date
FROM topics t
JOIN subjects s ON s.subject_id = t.subject_id
WHERE t.next_review_date <= CURRENT_DATE
ORDER BY t.next_review_date ASC;

CREATE OR REPLACE FUNCTION apply_sm2_scheduling()
RETURNS TRIGGER AS $$
DECLARE
    v_old_ease_factor       NUMERIC(4,2);
    v_old_repetition_count  INTEGER;
    v_old_interval_days     INTEGER;
    v_old_next_review_date  DATE;

    v_new_ease_factor       NUMERIC(4,2);
    v_new_repetition_count  INTEGER;
    v_new_interval_days     INTEGER;
    v_new_next_review_date  DATE;

    v_quality               SMALLINT;
BEGIN
    v_quality := NEW.quality_rating;

    SELECT ease_factor, repetition_count, interval_days, next_review_date
    INTO v_old_ease_factor, v_old_repetition_count, v_old_interval_days, v_old_next_review_date
    FROM topics
    WHERE topic_id = NEW.topic_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Topic % does not exist', NEW.topic_id;
    END IF;

    v_new_ease_factor := v_old_ease_factor
        + (0.1 - (5 - v_quality) * (0.08 + (5 - v_quality) * 0.02));

    IF v_new_ease_factor < 1.3 THEN
        v_new_ease_factor := 1.3;
    END IF;

    IF v_quality < 3 THEN
        v_new_repetition_count := 0;
        v_new_interval_days := 1;
    ELSE
        v_new_repetition_count := v_old_repetition_count + 1;

        IF v_old_repetition_count = 0 THEN
            v_new_interval_days := 1;
        ELSIF v_old_repetition_count = 1 THEN
            v_new_interval_days := 6;
        ELSE
            v_new_interval_days := ROUND(v_old_interval_days * v_new_ease_factor);
        END IF;
    END IF;

    v_new_next_review_date := CURRENT_DATE + v_new_interval_days;

    UPDATE topics
    SET ease_factor = v_new_ease_factor,
        repetition_count = v_new_repetition_count,
        interval_days = v_new_interval_days,
        last_reviewed_at = NEW.session_date,
        next_review_date = v_new_next_review_date
    WHERE topic_id = NEW.topic_id;

    INSERT INTO performance_logs (
        session_id,
        topic_id,
        previous_ease_factor,
        new_ease_factor,
        previous_interval_days,
        new_interval_days,
        previous_repetition_count,
        new_repetition_count,
        previous_next_review_date,
        new_next_review_date
    )
    VALUES (
        NEW.session_id,
        NEW.topic_id,
        v_old_ease_factor,
        v_new_ease_factor,
        v_old_interval_days,
        v_new_interval_days,
        v_old_repetition_count,
        v_new_repetition_count,
        v_old_next_review_date,
        v_new_next_review_date
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sm2_scheduling
AFTER INSERT ON study_sessions
FOR EACH ROW
EXECUTE FUNCTION apply_sm2_scheduling();