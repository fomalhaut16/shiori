# frozen_string_literal: true

require "sqlite3"

module Shiori
  # SQLite への読み書きをまとめる。本の状態は books に、変更の履歴は events に残す。
  class Store
    Change = Data.define(:before, :after, :batch_id)
    SNAPSHOT_KEYS = %i[title current_page read_ranges status total_pages started_at finished_at updated_at].freeze

    def self.open(path, migrations_dir: File.join(ROOT, "db", "migrations"), clock: -> { Time.now })
      db = SQLite3::Database.new(path, results_as_hash: true)
      db.busy_timeout = 5000
      db.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
      migrate(db, migrations_dir)
      new(db, clock: clock)
    end

    # db/migrations の .sql を名前順に、まだ適用していないものだけ流す。
    # 表を作り直せるよう、流している間は外部キーの確認を切り、最後にまとめて確かめる。
    def self.migrate(db, dir)
      db.execute("CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)")
      applied = db.execute("SELECT name FROM schema_migrations").map { |r| r["name"] }
      pending = Dir.glob(File.join(dir, "*.sql")).sort.reject { |f| applied.include?(File.basename(f)) }
      return if pending.empty?

      fk = db.get_first_value("PRAGMA foreign_keys")
      db.execute("PRAGMA foreign_keys = OFF")
      pending.each do |file|
        db.transaction do
          db.execute_batch(File.read(file, encoding: "UTF-8"))
          raise "#{File.basename(file)}: 外部キーの整合が崩れました" if db.execute("PRAGMA foreign_key_check").any?

          db.execute("INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)", [File.basename(file), Time.now.getutc.iso8601(3)])
        end
      end
    ensure
      db.execute("PRAGMA foreign_keys = #{fk.to_i}") if fk
    end

    attr_reader :db

    def initialize(db, clock: -> { Time.now })
      @db = db
      @clock = clock
    end

    def now = @clock.call

    def get_book(id) = to_book(@db.get_first_row("SELECT * FROM books WHERE id = ?", [id]))

    def find_by_isbn(isbn) = to_book(@db.get_first_row("SELECT * FROM books WHERE isbn = ?", [isbn]))

    def list_books(statuses)
      marks = (["?"] * statuses.size).join(", ")
      to_books(@db.execute("SELECT * FROM books WHERE status IN (#{marks}) ORDER BY updated_at DESC, id DESC", statuses))
    end

    def oldest_tsundoku(limit)
      to_books(@db.execute("SELECT * FROM books WHERE status = 'tsundoku' ORDER BY created_at, id LIMIT ?", [limit]))
    end

    # 書名の一部で探す。完全一致が 1 冊あればそれだけを返す。
    def find_books(text)
      found = to_books(@db.execute(<<~SQL, [text]))
        SELECT * FROM books WHERE instr(lower(title), lower(?)) > 0 AND status != 'deleted'
        ORDER BY status = 'finished', updated_at DESC LIMIT 10
      SQL
      exact = found.select { |b| b.title.casecmp?(text) }
      exact.size == 1 ? exact : found
    end

    def count_by_status(status) = @db.get_first_value("SELECT COUNT(*) FROM books WHERE status = ?", [status])

    def finished_since(iso) = finished_between(iso, "9999")

    def finished_between(from_iso, to_iso)
      to_books(@db.execute(<<~SQL, [from_iso, to_iso]))
        SELECT * FROM books WHERE status = 'finished' AND finished_at >= ? AND finished_at < ? ORDER BY finished_at
      SQL
    end

    # ひとこと感想は履歴に残さず、書き直したら上書きする
    def set_note(id, text) = @db.execute("UPDATE books SET note = ? WHERE id = ?", [text, id])

    def page_events_since(iso)
      @db.execute("SELECT * FROM events WHERE kind = 'page' AND undone = 0 AND at >= ? ORDER BY id", [iso])
    end

    def last_page_times
      @db.execute("SELECT book_id, MAX(at) AS last_at FROM events WHERE kind = 'page' AND undone = 0 GROUP BY book_id")
         .to_h { |r| [r["book_id"], r["last_at"]] }
    end

    def create_book(title:, author:, total_pages:, isbn:, status:, source:)
      at = stamp
      batch_id = SecureRandom.uuid
      book = nil
      @db.transaction do
        book = to_book(@db.get_first_row(<<~SQL, [title, author, total_pages, isbn, status, at, status == "reading" ? at : nil, at]))
          INSERT INTO books (title, author, total_pages, isbn, status, current_page, created_at, started_at, updated_at)
          VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?) RETURNING *
        SQL
        insert_event(batch_id: batch_id, book_id: book.id, kind: "create", at: at, source: source,
                     to_status: status, to_total: total_pages)
      end
      [book, batch_id]
    end

    # 本の状態を変え、変わった項目ごとに履歴を残す。何も変わらなければ nil。
    def apply_change(before, patch, source)
      at = stamp
      batch_id = SecureRandom.uuid
      base = { batch_id: batch_id, book_id: before.id, at: at, source: source, snapshot: JSON.generate(before.to_h.slice(*SNAPSHOT_KEYS)) }
      attrs = {}
      events = []

      if patch.key?(:title) && patch[:title] != before.title
        attrs[:title] = patch[:title]
        events << base.merge(kind: "title", from_title: before.title, to_title: patch[:title])
      end
      if patch.key?(:total_pages) && patch[:total_pages] != before.total_pages
        attrs[:total_pages] = patch[:total_pages]
        events << base.merge(kind: "total", from_total: before.total_pages, to_total: patch[:total_pages])
      end
      # 栞の位置と読んだ範囲は、まとめて 1 つのページ記録にする
      page_moved = patch.key?(:current_page) && patch[:current_page] != before.current_page
      ranges_grew = patch.key?(:ranges) && patch[:ranges] != before.ranges
      if page_moved || ranges_grew
        attrs[:current_page] = patch[:current_page] if page_moved
        attrs[:read_ranges] = JSON.generate(patch[:ranges]) if ranges_grew
        added = ranges_grew ? Ranges.count(patch[:ranges]) - before.read_count : 0
        events << base.merge(kind: "page", from_page: before.current_page, to_page: attrs.fetch(:current_page, before.current_page),
                             pages: [0, added].max)
      end
      if patch.key?(:status) && patch[:status] != before.status
        attrs[:status] = patch[:status]
        attrs[:started_at] = at if patch[:status] == "reading" && before.started_at.nil?
        attrs[:finished_at] = patch[:status] == "finished" ? at : nil
        events << base.merge(kind: "status", from_status: before.status, to_status: patch[:status])
      end
      return nil if events.empty?

      after = before.with(**attrs, updated_at: at)
      @db.transaction do
        write_state(after)
        events.each { |e| insert_event(**e) }
      end
      Change.new(before: before, after: after, batch_id: batch_id)
    end

    # batch_id を省くと最新の変更を取り消す。同じ本にそれより新しい変更があれば取り消さない。
    # 戻り値: { ok: true, kind: "deleted", book: } / { ok: true, kind: "reverted", before:, after: } / { ok: false, reason: }
    def undo(batch_id = nil)
      target = if batch_id
                 @db.get_first_row("SELECT * FROM events WHERE batch_id = ? ORDER BY id LIMIT 1", [batch_id])
               else
                 @db.get_first_row("SELECT * FROM events WHERE undone = 0 ORDER BY id DESC LIMIT 1")
               end
      return { ok: false, reason: "取り消せる記録がありません" } unless target
      return { ok: false, reason: "この記録はもう取り消してあります" } if target["undone"] == 1

      newer = @db.get_first_value(
        "SELECT id FROM events WHERE book_id = ? AND undone = 0 AND batch_id != ? AND id > ? LIMIT 1",
        [target["book_id"], target["batch_id"], target["id"]],
      )
      return { ok: false, reason: "このあとに同じ本の記録があるため取り消せません。新しいものから順に取り消してください" } if newer

      book = get_book(target["book_id"]) or return { ok: false, reason: "本が見つかりません" }

      if target["kind"] == "create"
        @db.transaction do
          @db.execute("DELETE FROM events WHERE book_id = ?", [book.id])
          @db.execute("DELETE FROM books WHERE id = ?", [book.id])
        end
        return { ok: true, kind: "deleted", book: book }
      end

      after = book.with(**JSON.parse(target["snapshot"], symbolize_names: true))
      @db.transaction do
        write_state(after)
        @db.execute("UPDATE events SET undone = 1 WHERE batch_id = ?", [target["batch_id"]])
      end
      { ok: true, kind: "reverted", before: book, after: after }
    end

    def mark_nudged(ids, at)
      return if ids.empty?

      @db.execute("UPDATE books SET last_nudged_at = ? WHERE id IN (#{(["?"] * ids.size).join(", ")})", [at, *ids])
    end

    def get_meta(key) = @db.get_first_value("SELECT value FROM meta WHERE key = ?", [key])

    def set_meta(key, value)
      @db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value", [key, value])
    end

    # 初めて見るイベントなら true。Slack の再送や、起動時の取りこぼし処理との二重実行を防ぐ。
    def claim_event(event_id)
      @db.execute("INSERT OR IGNORE INTO processed_slack_events (event_id, received_at) VALUES (?, ?)", [event_id, stamp])
      @db.changes == 1
    end

    def prune_events(before_iso)
      @db.execute("DELETE FROM processed_slack_events WHERE received_at < ?", [before_iso])
    end

    def backup(path) = @db.execute("VACUUM INTO ?", [path])

    def close = @db.close

    private

    def stamp = Stats.iso(now)

    def to_book(row) = row && Book.from_row(row)

    def to_books(rows) = rows.map { |r| Book.from_row(r) }

    def write_state(b)
      @db.execute(
        "UPDATE books SET title = ?, current_page = ?, read_ranges = ?, status = ?, total_pages = ?, started_at = ?, " \
        "finished_at = ?, updated_at = ? WHERE id = ?",
        [b.title, b.current_page, b.read_ranges, b.status, b.total_pages, b.started_at, b.finished_at, b.updated_at, b.id],
      )
    end

    def insert_event(batch_id:, book_id:, kind:, at:, source:, snapshot: nil, from_page: nil, to_page: nil, pages: 0,
                     from_status: nil, to_status: nil, from_total: nil, to_total: nil, from_title: nil, to_title: nil)
      values = [batch_id, book_id, kind, from_page, to_page, pages, from_status, to_status, from_total, to_total,
                from_title, to_title, at, source, snapshot]
      @db.execute(<<~SQL, values)
        INSERT INTO events (batch_id, book_id, kind, from_page, to_page, pages, from_status, to_status, from_total, to_total,
                            from_title, to_title, at, source, snapshot)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
  end
end
