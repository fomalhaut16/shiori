-- 飛ばし読みのために、読んだ範囲（JSON の [[from, to], ...]）を持つ。
-- 削除した本は status = 'deleted' にして残す（取り消せるように）。
-- CHECK を変えるには表を作り直す必要がある。外部キーの確認は Store.migrate が切っている。
CREATE TABLE books_new (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  title          TEXT    NOT NULL,
  author         TEXT,
  total_pages    INTEGER CHECK (total_pages IS NULL OR total_pages > 0),
  current_page   INTEGER NOT NULL DEFAULT 0 CHECK (current_page >= 0),
  read_ranges    TEXT    NOT NULL DEFAULT '[]',
  status         TEXT    NOT NULL DEFAULT 'tsundoku'
                 CHECK (status IN ('tsundoku', 'reading', 'paused', 'finished', 'deleted')),
  isbn           TEXT,
  created_at     TEXT    NOT NULL,
  started_at     TEXT,
  finished_at    TEXT,
  updated_at     TEXT    NOT NULL,
  last_nudged_at TEXT
);

-- これまでは先頭から読んだ前提なので、1 から current_page までを読んだことにする
INSERT INTO books_new (id, title, author, total_pages, current_page, read_ranges, status, isbn,
                       created_at, started_at, finished_at, updated_at, last_nudged_at)
SELECT id, title, author, total_pages, current_page,
       CASE WHEN current_page > 0 THEN json_array(json_array(1, current_page)) ELSE '[]' END,
       status, isbn, created_at, started_at, finished_at, updated_at, last_nudged_at
FROM books;

DROP TABLE books;
ALTER TABLE books_new RENAME TO books;
CREATE INDEX books_status ON books (status, updated_at);
CREATE UNIQUE INDEX books_isbn ON books (isbn) WHERE isbn IS NOT NULL;

-- その記録で新しく読んだページ数。週のページ数やペースはこれを足す
ALTER TABLE events ADD COLUMN pages INTEGER NOT NULL DEFAULT 0;
UPDATE events SET pages = MAX(0, to_page - from_page) WHERE kind = 'page';
