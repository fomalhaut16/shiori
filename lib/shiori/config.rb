# frozen_string_literal: true

module Shiori
  Config = Data.define(
    :app_token, :bot_token, :allowed_users, :notify_channel,
    :db_path, :backup_dir, :log_path, :keep_backups,
    :notify_hour, :weekly_day, :stall_days,
    :daily_nudge, :weekly_report, :year_report,
    :google_books_key,
  ) do
    # .env を読み、足りない値は既定値で埋める。必須の値がなければ例外にする。
    def self.load(root = ROOT, env = ENV)
      load_dotenv(File.join(root, ".env"), env)
      fetch = lambda do |key, default = nil|
        value = env[key].to_s.strip
        value = default.to_s if value.empty?
        raise ArgumentError, "環境変数 #{key} が設定されていません。.env を確認してください" if value.empty?

        value
      end
      path = ->(key, default) { File.expand_path(fetch.call(key, default), root) }
      # 定期通知は既定でオフ。on / true / 1 / yes でオンにする
      flag = ->(key) { %w[on true 1 yes].include?(env[key].to_s.strip.downcase) }

      allowed = fetch.call("ALLOWED_USER_IDS").split(",").map(&:strip).reject(&:empty?)
      new(
        app_token: fetch.call("SLACK_APP_TOKEN"),
        bot_token: fetch.call("SLACK_BOT_TOKEN"),
        allowed_users: allowed,
        notify_channel: fetch.call("NOTIFY_CHANNEL", allowed.first),
        db_path: path.call("DB_PATH", "data/shiori.db"),
        backup_dir: path.call("BACKUP_DIR", "data/backups"),
        log_path: path.call("LOG_PATH", "data/shiori.log"),
        keep_backups: Integer(fetch.call("KEEP_BACKUPS", "30")),
        notify_hour: Integer(fetch.call("NOTIFY_HOUR", "21")),
        weekly_day: Integer(fetch.call("WEEKLY_DAY", "0")),
        stall_days: Integer(fetch.call("STALL_DAYS", "3")),
        daily_nudge: flag.call("DAILY_NUDGE"),
        weekly_report: flag.call("WEEKLY_REPORT"),
        year_report: flag.call("YEAR_REPORT"),
        # 任意。なければ Google Books へはキーなしで問い合わせる
        google_books_key: env["GOOGLE_BOOKS_API_KEY"].to_s.strip.then { |k| k.empty? ? nil : k },
      )
    end

    # KEY=VALUE の行だけを読む。すでに環境変数にある値は上書きしない。
    def self.load_dotenv(file, env)
      return unless File.exist?(file)

      File.foreach(file, encoding: "UTF-8") do |line|
        next if line.strip.empty? || line.lstrip.start_with?("#")

        key, value = line.split("=", 2)
        next unless value

        key = key.strip
        env[key] = value.strip.delete_prefix('"').delete_suffix('"') if env[key].to_s.empty?
      end
    end
  end
end
