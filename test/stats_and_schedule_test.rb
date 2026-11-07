# frozen_string_literal: true

require "test_helper"

class StatsTest < Minitest::Test
  include StoreHelper

  def test_days_are_counted_in_jst
    # 日本時間 23:30 と翌 0:30 は 1 日違い
    assert_equal 1, Shiori::Stats.days_between("2026-11-01T14:30:00Z", "2026-11-01T15:30:00Z")
    assert_equal 0, Shiori::Stats.days_between("2026-11-01T15:30:00Z", "2026-11-02T14:00:00Z")
  end

  def test_start_of_year_in_jst
    assert_equal Time.utc(2025, 12, 31, 15), Shiori::Stats.start_of_jst_year(Time.utc(2026, 6, 1))
  end

  def test_view_pace_and_eta
    book = book(total: 300, ranges: [[1, 100]], current: 100)
    events = [{ "pages" => 60 }, { "pages" => 0 }, { "pages" => 50 }]
    v = Shiori::Stats.view(book, events, "2026-10-30T00:00:00Z", Time.utc(2026, 11, 1, 3))
    # 開始から 4 日（10/29〜11/1）で 110 ページ
    assert_in_delta 27.5, v.pace
    assert_equal 8, v.eta_days
    assert_equal 2, v.idle_days
    assert_equal 33, v.percent
  end

  def book(total:, ranges:, current:)
    Shiori::Book.new(id: 1, title: "t", author: nil, total_pages: total, current_page: current, read_ranges: JSON.generate(ranges),
                     status: "reading", isbn: nil, created_at: "2026-10-01T00:00:00Z", started_at: "2026-10-29T00:00:00Z",
                     finished_at: nil, updated_at: "2026-11-01T00:00:00Z", last_nudged_at: nil)
  end

  def test_progress_bar_maps_read_places
    # 190 ページを 19 マスに。1〜80 と 151〜190 を読んだ
    b = book(total: 190, ranges: [[1, 80], [151, 190]], current: 190)
    assert_equal "▰▰▰▰▰▰▰▰▱▱▱▱▱▱▱▰▰▰▰", Shiori::Stats.progress_bar(b)
    # 3 段なら 19 マスずつ改行する
    rows = Shiori::Stats.progress_bar(b, 3).split("\n")
    assert_equal [19, 19, 19], rows.map(&:length)
  end

  def test_daily_pages_and_sparkline
    now = Time.utc(2026, 11, 7, 3) # 日本時間 11/7 12:00
    events = [
      { "at" => "2026-11-07T01:00:00Z", "pages" => 10 },
      { "at" => "2026-11-06T16:00:00Z", "pages" => 30 }, # 日本時間 11/7 1:00
      { "at" => "2026-11-01T03:00:00Z", "pages" => 20 },
      { "at" => "2026-10-20T03:00:00Z", "pages" => 99 },
    ]
    days = Shiori::Stats.daily_pages(events, now)
    assert_equal [20, 0, 0, 0, 0, 0, 40], days
    assert_equal "▅▁▁▁▁▁█", Shiori::Stats.sparkline(days)
  end
end

class RangesTest < Minitest::Test
  R = Shiori::Ranges

  def test_normalize_merges_overlaps_and_neighbours
    assert_equal [[1, 20], [30, 40]], R.normalize([[30, 35], [11, 20], [1, 10], [33, 40]])
  end

  def test_count_gaps_and_format
    list = [[120, 144], [160, 188]]
    assert_equal 54, R.count(list)
    assert_equal [[1, 119], [145, 159]], R.gaps(list)
    assert_equal "120–144, 160–188", R.format(list)
    assert_empty R.gaps([[1, 50]])
  end
end

class ScheduleTest < Minitest::Test
  include StoreHelper
  S = Shiori::Schedule

  def test_daily_slot
    # 日本時間 11/6 20:59 → 前日 21:00、21:00 ちょうど → 当日
    assert_equal Time.utc(2026, 11, 5, 12), S.latest_daily_slot(Time.utc(2026, 11, 6, 11, 59), 21)
    assert_equal Time.utc(2026, 11, 6, 12), S.latest_daily_slot(Time.utc(2026, 11, 6, 12), 21)
  end

  def test_weekly_slot_is_previous_sunday
    # 2026-11-06 は金曜。直近の日曜 21:00 JST は 11/1 12:00 UTC
    assert_equal Time.utc(2026, 11, 1, 12), S.latest_weekly_slot(Time.utc(2026, 11, 6, 3), 0, 21)
  end

  def test_first_run_does_not_send_past_slots
    store = new_store
    slot = Time.utc(2026, 11, 1, 12)
    refute S.due?(store, "k", slot)
    refute S.due?(store, "k", slot)
    assert S.due?(store, "k", slot + 86_400)
    S.mark_done(store, "k", slot + 86_400)
    refute S.due?(store, "k", slot + 86_400)
  end
end
