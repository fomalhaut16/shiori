# frozen_string_literal: true

module Shiori
  # 定期通知の中身を作る
  module Jobs
    module_function

    def weekly_report(store, now)
      from = now - (7 * Stats::DAY)
      events = store.page_events_since(Stats.iso(from))
      Render.weekly(Render::Weekly.new(
        pages: Stats.pages_read(events),
        books_touched: events.map { |e| e["book_id"] }.uniq.size,
        finished: store.finished_since(Stats.iso(from)),
        overview: Commands.load_overview(store, now),
        from: from,
        to: now,
      ))
    end

    # 止まっている本だけを知らせる。何もなければ送らない（nil）。
    # 同じ本へは stall_days 日に 1 回まで。読書中の本がなければ、積読から選ぶよう促す。
    def daily_nudge(store, now, stall_days)
      reading = store.list_books(["reading"])
      unless reading.empty?
        due = Commands.load_views(store, reading, now).select do |v|
          v.idle_days >= stall_days &&
            (v.book.last_nudged_at.nil? || Stats.days_between(v.book.last_nudged_at, now) >= stall_days)
        end
        return nil if due.empty?

        store.mark_nudged(due.map { |v| v.book.id }, Stats.iso(now))
        return Render.nudge(due)
      end

      last = store.get_meta("last_suggested_at")
      return nil if last && Stats.days_between(last, now) < stall_days

      picks = store.oldest_tsundoku(3)
      return nil if picks.empty?

      store.set_meta("last_suggested_at", Stats.iso(now))
      Render.suggest(picks, now)
    end
  end
end
