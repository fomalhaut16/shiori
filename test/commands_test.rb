# frozen_string_literal: true

require "test_helper"

class CommandsTest < Minitest::Test
  include StoreHelper

  def setup
    @clock = FakeClock.new("2026-11-01T03:00:00Z")
    @store = new_store(@clock)
    @lookups = []
    lookup = lambda { |isbn|
      @lookups << isbn
      isbn == "9784101006017" ? Shiori::BookInfo::Info.new(title: "走れメロス", author: "太宰治", total_pages: 286) : nil
    }
    @ctx = Shiori::Commands::Context.new(store: @store, source: "test", lookup: lookup)
  end

  def run_text(text) = Shiori::Commands.execute(Shiori::Parser.parse(text), @ctx)

  def blocks_text(message) = JSON.generate(message[:blocks])

  def test_add_by_isbn_uses_lookup_and_rejects_duplicates
    msg = run_text("追加 978-4-10-100601-7")
    assert_match "走れメロス", msg[:text]
    book = @store.get_book(1)
    assert_equal [286, "tsundoku", "9784101006017"], [book.total_pages, book.status, book.isbn]
    assert_match "すでに登録してあります", run_text("追加 9784101006017")[:text]
  end

  def test_add_unknown_isbn_reports_error
    assert_match "書誌が見つかりませんでした", run_text("追加 9784000000000")[:text]
    assert_nil @store.get_book(1)
  end

  def test_mistyped_isbn_is_not_added_as_title
    assert_match "ISBN として正しくありません", run_text("追加 9784000000002")[:text]
    assert_empty @lookups
    assert_nil @store.get_book(1)
  end

  def test_bulk_add
    msg = run_text("追加\n人間失格 180\n斜陽")
    assert_match "人間失格", blocks_text(msg)
    assert_equal 2, @store.count_by_status("tsundoku")
  end

  def test_page_on_tsundoku_starts_reading_and_relative_works
    add_book(@store)
    assert_match "読書中の本がありません", run_text("50")[:text]
    run_text("#1 50")
    assert_equal ["reading", 50], @store.get_book(1).then { [_1.status, _1.current_page] }
    @clock.advance(days: 1)
    msg = run_text("+30")
    assert_equal 80, @store.get_book(1).current_page
    assert_match "50 → *80*p（+30p）", blocks_text(msg)
  end

  def test_page_beyond_total_is_rejected
    add_book(@store, total: 100, status: "reading")
    assert_match "総ページは 100p です", run_text("120")[:text]
    assert_equal 0, @store.get_book(1).current_page
  end

  def test_reaching_total_finishes_book
    add_book(@store, total: 100, status: "reading")
    msg = run_text("100")
    book = @store.get_book(1)
    assert_equal "finished", book.status
    refute_nil book.finished_at
    assert_match "読み終えました", msg[:text]
    assert_match "今年 1 冊目", blocks_text(msg)
  end

  def test_ambiguous_target_offers_choices
    add_book(@store, title: "A", status: "reading")
    add_book(@store, title: "B", status: "reading")
    msg = run_text("10")
    assert_equal "どの本ですか？", msg[:text]
    button = msg[:blocks][1][:elements].first
    data = JSON.parse(button[:value], symbolize_names: true)
    assert_equal({ kind: "page", target: nil, value: 10, relative: false }, data[:cmd])
  end

  def test_query_target
    add_book(@store, title: "走れメロス", status: "reading")
    add_book(@store, title: "人間失格", status: "reading")
    run_text("メロス 42")
    assert_equal 42, @store.get_book(1).current_page
  end

  def test_undo_reverts_page_and_status_together
    add_book(@store)
    run_text("#1 50")
    run_text("取消")
    book = @store.get_book(1)
    assert_equal ["tsundoku", 0, nil], [book.status, book.current_page, book.started_at]
    # 次の取消は登録そのものを取り消す
    assert_match "登録を取り消しました", run_text("取消")[:text]
    assert_nil @store.get_book(1)
  end

  def test_undo_by_old_button_is_refused_when_newer_exists
    add_book(@store, status: "reading")
    first = @store.apply_change(@store.get_book(1), { current_page: 10 }, "t")
    @store.apply_change(@store.get_book(1), { current_page: 20 }, "t")
    result = Shiori::Commands.execute({ kind: "undo", batch_id: first.batch_id }, @ctx)
    assert_match "取り消せません", result[:text]
    assert_equal 20, @store.get_book(1).current_page
  end

  def test_undone_pages_do_not_count_toward_pace
    add_book(@store, status: "reading")
    run_text("100")
    run_text("取消")
    assert_empty @store.page_events_since("2000-01-01T00:00:00Z")
  end

  def test_finish_and_pause_and_total
    add_book(@store, total: nil, status: "reading")
    assert_match "総ページを 320p", blocks_text(run_text("総ページ 320"))
    run_text("中断")
    assert_equal "paused", @store.get_book(1).status
    run_text("開始")
    run_text("読了")
    assert_equal "finished", @store.get_book(1).status
  end

  def test_skipped_ranges_count_only_read_pages
    add_book(@store, total: 300, status: "reading")
    msg = run_text("120-144 160〜188")
    book = @store.get_book(1)
    assert_equal [[120, 144], [160, 188]], book.ranges
    assert_equal [188, 54], [book.current_page, book.read_count]
    assert_match "120–144, 160–188 を記録（+54p）", blocks_text(msg)
    assert_match "未読 1–119, 145–159", blocks_text(msg)

    # 栞（188）から続けて読むと、189〜200 が足される。読み返した所は二重に数えない
    run_text("200")
    run_text("130-150")
    book = @store.get_book(1)
    assert_equal [[120, 150], [160, 200]], book.ranges
    assert_equal 72, book.read_count
    assert_equal 72, Shiori::Stats.pages_read(@store.page_events_since("2000-01-01T00:00:00Z"))
  end

  def test_reaching_last_page_with_gaps_does_not_finish
    add_book(@store, total: 100, status: "reading")
    run_text("50-100")
    assert_equal "reading", @store.get_book(1).status
    run_text("1-49")
    assert_equal "finished", @store.get_book(1).status
  end

  def test_range_beyond_total_and_total_below_read_pages_are_rejected
    add_book(@store, total: 100, status: "reading")
    assert_match "総ページは 100p です", run_text("90-120")[:text]
    run_text("80-90")
    assert_match "90p まで", run_text("総ページ 85")[:text]
  end

  def test_delete_hides_book_and_can_be_undone
    add_book(@store, title: "要らない本")
    assert_equal "invalid", Shiori::Parser.parse("削除")[:kind]
    msg = run_text("削除 #1")
    assert_match "削除しました", msg[:text]
    assert_equal 0, @store.count_by_status("tsundoku")
    assert_match "見つかりません", run_text("#1 10")[:text]
    assert_match "見つかりません", run_text("要らない 10")[:text]

    run_text("取消")
    assert_equal "tsundoku", @store.get_book(1).status
  end

  def test_adding_deleted_isbn_restores_the_book
    run_text("追加 9784101006017")
    run_text("削除 #1")
    assert_match "積読に追加しました", run_text("追加 9784101006017")[:text]
    assert_equal "tsundoku", @store.get_book(1).status
    assert_nil @store.get_book(2)
  end

  def test_add_with_title_and_unknown_isbn_uses_the_title
    msg = Shiori::Commands.execute({ kind: "add", items: [{ query: "9784000000000", total_pages: 200, title: "自作の本" }] }, @ctx)
    assert_match "積読に追加しました", msg[:text]
    book = @store.get_book(1)
    assert_equal ["自作の本", 200, "9784000000000"], [book.title, book.total_pages, book.isbn]
  end

  def test_finish_offers_note_and_list_shows_it
    add_book(@store, title: "読み切る本", total: 100, status: "reading")
    @clock.advance(days: 2)
    msg = run_text("100")
    assert_match "note:1", blocks_text(msg)

    Shiori::Commands.execute({ kind: "note", target: { kind: "id", id: 1 }, text: "  面白かった \n" }, @ctx)
    assert_equal "面白かった", @store.get_book(1).note

    list = blocks_text(run_text("読了一覧"))
    assert_match "2026年に読んだ本 1冊", list
    assert_match "読み切る本", list
    assert_match "面白かった", list
    assert_match "まだありません", run_text("読了一覧 2025")[:text]
  end

  def test_list_shows_reading_and_tsundoku
    add_book(@store, title: "読んでる本", status: "reading")
    add_book(@store, title: "積んでる本")
    text = blocks_text(run_text(""))
    assert_match "読書中 1冊", text
    assert_match "積読 1冊", text
  end
end

class JobsTest < Minitest::Test
  include StoreHelper

  def setup
    @clock = FakeClock.new("2026-11-01T03:00:00Z")
    @store = new_store(@clock)
  end

  def test_nudge_only_stalled_books_and_not_every_day
    stalled = add_book(@store, title: "止まってる本", status: "reading")
    read_to(@store, stalled, 10)
    @clock.advance(days: 3)
    active = add_book(@store, title: "読んでる本", status: "reading")
    read_to(@store, active, 10)

    msg = Shiori::Jobs.daily_nudge(@store, @clock.time, 3)
    assert_match "止まってる本", JSON.generate(msg[:blocks])
    refute_match "読んでる本", JSON.generate(msg[:blocks])

    @clock.advance(days: 1)
    assert_nil Shiori::Jobs.daily_nudge(@store, @clock.time, 3)
    @clock.advance(days: 2)
    refute_nil Shiori::Jobs.daily_nudge(@store, @clock.time, 3)
  end

  def test_suggests_tsundoku_when_nothing_is_being_read
    add_book(@store, title: "古い積読")
    msg = Shiori::Jobs.daily_nudge(@store, @clock.time, 3)
    assert_match "古い積読", JSON.generate(msg[:blocks])
    assert_nil Shiori::Jobs.daily_nudge(@store, @clock.time, 3)
  end

  def test_weekly_report_counts_pages
    book = add_book(@store, status: "reading")
    read_to(@store, book, 40)
    msg = Shiori::Jobs.weekly_report(@store, @clock.time + 86_400)
    assert_equal "今週の読書: 40p", msg[:text]
    # 昨日 40p 読んだので、7 日のグラフの最後から 2 番目だけが伸びる
    assert_match "この7日 ▁▁▁▁▁█▁  計 40p", JSON.generate(msg[:blocks])
  end
end
