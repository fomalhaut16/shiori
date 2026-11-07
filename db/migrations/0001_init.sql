-- 本ごとの現在の状態
CREATE TABLE books (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  title          TEXT    NOT NULL,
  author         TEXT,
  total_pages    INTEGER CHECK (total_pages IS NULL OR total_pages > 0),
  current_page   INTEGER NOT NULL DEFAULT 0 CHECK (current_page >= 0),
  status         TEXT    NOT NULL DEFAULT 'tsundoku'
                 CHECK (status IN ('tsundoku', 'reading', 'paused', 'finished')),
  isbn           TEXT,
  created_at     TEXT    NOT NULL,
  started_at     TEXT,
  finished_at    TEXT,
  updated_at     TEXT    NOT NULL,
  last_nudged_at TEXT
);
CREATE INDEX books_status ON books (status, updated_at);
CREATE UNIQUE INDEX books_isbn ON books (isbn) WHERE isbn IS NOT NULL;

-- 変更の履歴。1 回の操作で複数行になるときは batch_id が同じになる。
-- snapshot は変更前の books の行（JSON）で、取り消しに使う。
CREATE TABLE events (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id    TEXT    NOT NULL,
  book_id     INTEGER NOT NULL REFERENCES books (id),
  kind        TEXT    NOT NULL CHECK (kind IN ('create', 'page', 'status', 'total')),
  from_page   INTEGER,
  to_page     INTEGER,
  from_status TEXT,
  to_status   TEXT,
  from_total  INTEGER,
  to_total    INTEGER,
  at          TEXT    NOT NULL,
  source      TEXT    NOT NULL,
  snapshot    TEXT,
  undone      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX events_book ON events (book_id, id);
CREATE INDEX events_kind_at ON events (kind, at);
CREATE INDEX events_batch ON events (batch_id);

-- Slack の再送で同じイベントを二重に処理しないための記録
CREATE TABLE processed_slack_events (
  event_id    TEXT PRIMARY KEY,
  received_at TEXT NOT NULL
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
