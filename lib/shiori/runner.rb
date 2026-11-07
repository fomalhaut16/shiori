# frozen_string_literal: true

require "fileutils"

module Shiori
  # 常駐プロセスの組み立て。
  # DB を触る処理（Slack からの操作、定期通知、取りこぼしの処理）は、すべて 1 本の作業スレッドで順番に行う。
  class Runner
    def initialize(config)
      @config = config
      FileUtils.mkdir_p([File.dirname(config.db_path), config.backup_dir, File.dirname(config.log_path)])
      @logger = Logger.new(config.log_path, 5, 1_048_576)
      @logger.formatter = proc { |sev, time, _, msg| "#{time.iso8601} #{sev} #{msg}\n" }
      @queue = Queue.new
    end

    def run
      @store = Store.open(@config.db_path)
      @app = App.new(
        store: @store,
        slack: SlackClient.new(@config.bot_token),
        allowed_users: @config.allowed_users,
        notify_channel: @config.notify_channel,
        stall_days: @config.stall_days,
        logger: @logger,
      )
      @socket = SocketMode.new(
        app_token: @config.app_token,
        ack_for: @app.method(:ack_for),
        on_envelope: ->(type, payload) { @queue << [:envelope, type, payload] },
        on_connected: -> { @queue << [:catch_up] },
        logger: @logger,
      )

      worker = Thread.new { work }
      ticker = Thread.new do
        loop do
          @queue << [:tick]
          sleep 60
        end
      end
      %w[INT TERM].each { |sig| trap(sig) { Thread.new { shutdown } } }

      @logger.info("shiori started (db: #{@config.db_path})")
      @socket.run
      [ticker, worker].each(&:kill)
      @store.close
      @logger.info("shiori stopped")
    end

    def shutdown
      @logger.info("shutting down")
      @socket.stop
    end

    private

    def work
      loop do
        kind, *args = @queue.pop
        case kind
        when :envelope then @app.process(*args)
        when :catch_up
          n = @app.catch_up
          @logger.info("processed #{n} message(s) sent while offline") if n.positive?
        when :tick then tick
        end
      rescue StandardError => e
        @logger.error("#{kind} failed: #{e.class}: #{e.message}")
      end
    end

    # 送るべき定期通知が残っていないか確かめる。失敗したら印を付けず、次の tick でやり直す。
    def tick
      now = @store.now
      weekly = Schedule.latest_weekly_slot(now, @config.weekly_day, @config.notify_hour)
      if Schedule.due?(@store, "weekly_slot", weekly)
        @app.send_weekly
        Schedule.mark_done(@store, "weekly_slot", weekly)
        @logger.info("weekly report sent")
      end

      daily = Schedule.latest_daily_slot(now, @config.notify_hour)
      return unless Schedule.due?(@store, "daily_slot", daily)

      # 週報と同じ時刻なら、週報に含まれるので催促は送らない
      @app.send_nudge unless daily == weekly
      backup(now)
      @store.prune_events(Stats.iso(now - (30 * Stats::DAY)))
      Schedule.mark_done(@store, "daily_slot", daily)
      @logger.info("daily jobs done")
    end

    def backup(now)
      file = File.join(@config.backup_dir, "shiori-#{Stats.jst(now).strftime('%F')}.db")
      @store.backup(file) unless File.exist?(file)
      old = Dir.glob(File.join(@config.backup_dir, "shiori-*.db")).sort[0...-@config.keep_backups] || []
      old.each { |f| File.delete(f) }
    end
  end
end
