# frozen_string_literal: true

module Shiori
  # 定期通知の時刻の計算。PC が止まっていて送れなかった回は、起動後に 1 回だけ送る。
  module Schedule
    DAY = Stats::DAY
    JST_OFFSET = Stats::JST_OFFSET

    module_function

    # now 以前で最も新しい「毎日 hour 時（日本時間）」
    def latest_daily_slot(now, hour)
      j = now.getutc + JST_OFFSET
      slot = Time.utc(j.year, j.month, j.day, hour) - JST_OFFSET
      slot > now ? slot - DAY : slot
    end

    # now 以前で最も新しい「毎週 wday 曜日（0 = 日曜）hour 時（日本時間）」
    def latest_weekly_slot(now, wday, hour)
      slot = latest_daily_slot(now, hour)
      slot -= DAY until (slot + JST_OFFSET).wday == wday
      slot
    end

    # slot をまだ処理していなければ true。初回は記録だけして false を返し、過去の分をまとめて送らない。
    def due?(store, key, slot)
      last = store.get_meta(key)
      if last.nil?
        store.set_meta(key, Stats.iso(slot))
        return false
      end
      last < Stats.iso(slot)
    end

    def mark_done(store, key, slot) = store.set_meta(key, Stats.iso(slot))
  end
end
