# frozen_string_literal: true

module Shiori
  module Stats
    DAY = 86_400
    # 日付の区切りは日本時間で数える。夏時間がないので固定の時差で足りる。
    JST_OFFSET = 9 * 3600
    PACE_WINDOW_DAYS = 14

    BookView = Data.define(:book, :percent, :remaining, :pace, :eta_days, :idle_days)

    module_function

    def to_time(t) = t.is_a?(String) ? Time.iso8601(t) : t

    def jst_day(t) = (to_time(t).to_i + JST_OFFSET).div(DAY)

    def days_between(from, to) = jst_day(to) - jst_day(from)

    def jst(t) = to_time(t).getutc + JST_OFFSET

    def start_of_jst_year(now) = Time.utc(jst(now).year, 1, 1) - JST_OFFSET

    def month_day(t)
      j = jst(t)
      "#{j.month}/#{j.day}"
    end

    def iso(t) = to_time(t).getutc.iso8601(3)

    def percent(book)
      return nil unless book.total_pages

      [100, book.read_count * 100 / book.total_pages].min
    end

    def remaining(book) = book.total_pages && [0, book.total_pages - book.read_count].max

    # 新しく読んだページだけを数える。読み返しや栞を戻した記録は読んだ量に入れない。
    def pages_read(events) = events.sum { |e| e["pages"].to_i }

    # 直近 days 日（今日を含む）の、日ごとの読んだページ数。古い日から並ぶ
    def daily_pages(events, now, days = 7)
      today = jst_day(now)
      totals = Array.new(days, 0)
      events.each do |e|
        i = days - 1 - (today - jst_day(e["at"]))
        totals[i] += e["pages"].to_i if i.between?(0, days - 1)
      end
      totals
    end

    SPARKS = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █].freeze

    # 読まなかった日は ▁、読んだ日は量に応じて ▂〜█
    def sparkline(values)
      max = values.max.to_f
      values.map { |v| v.zero? ? SPARKS[0] : SPARKS[1 + ((v / max) * (SPARKS.size - 2)).round] }.join
    end

    # recent_events はこの本の、直近 window 日のページ記録
    def view(book, recent_events, last_page_at, now, window = PACE_WINDOW_DAYS)
      started = book.started_at || book.created_at
      span = (days_between(started, now) + 1).clamp(1, window)
      pace = pages_read(recent_events).to_f / span
      rem = remaining(book)
      BookView.new(
        book: book,
        percent: percent(book),
        remaining: rem,
        pace: pace,
        eta_days: rem&.positive? && pace.positive? ? (rem / pace).ceil : nil,
        idle_days: [0, days_between(last_page_at || started, now)].max,
      )
    end

    # スマホの 1 行に収まるマスの数。折り返し位置は端末で変わるので、行は自分で区切る
    BAR_WIDTH = 19

    # 読んだ場所の地図。総ページを BAR_WIDTH × rows マスに分け、飛ばした所は空いたまま残る
    def progress_bar(book, rows = 1)
      Ranges.cells(book.ranges, book.total_pages, BAR_WIDTH * rows)
            .map { |on| on ? "▰" : "▱" }
            .each_slice(BAR_WIDTH).map(&:join).join("\n")
    end
  end
end
