-- 書名の変更も履歴に残す。kind の CHECK を変えるため表を作り直す
CREATE TABLE events_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id    TEXT    NOT NULL,
  book_id     INTEGER NOT NULL REFERENCES books (id),
  kind        TEXT    NOT NULL CHECK (kind IN ('create', 'page', 'status', 'total', 'title')),
  from_page   INTEGER,
  to_page     INTEGER,
  from_status TEXT,
  to_status   TEXT,
  from_total  INTEGER,
  to_total    INTEGER,
  at          TEXT    NOT NULL,
  source      TEXT    NOT NULL,
  snapshot    TEXT,
  undone      INTEGER NOT NULL DEFAULT 0,
  pages       INTEGER NOT NULL DEFAULT 0,
  from_title  TEXT,
  to_title    TEXT
);

INSERT INTO events_new (id, batch_id, book_id, kind, from_page, to_page, from_status, to_status, from_total, to_total,
                        at, source, snapshot, undone, pages)
SELECT id, batch_id, book_id, kind, from_page, to_page, from_status, to_status, from_total, to_total,
       at, source, snapshot, undone, pages
FROM events;

DROP TABLE events;
ALTER TABLE events_new RENAME TO events;
CREATE INDEX events_book ON events (book_id, id);
CREATE INDEX events_kind_at ON events (kind, at);
CREATE INDEX events_batch ON events (batch_id);
