# frozen_string_literal: true

module Shiori
  # Slack から届いたものを処理する。通信の方式（Socket Mode）には依存しない。
  #
  # Slack には 3 秒以内に受け取りを返す必要があるので、処理を 2 段に分けている。
  #   ack_for  受信スレッドで呼ぶ。DB に触らずに決められる即時応答だけを返す
  #   process  作業スレッドで呼ぶ。記録や返信など本来の処理をする
  class App
    LAST_SEEN_KEY = "last_seen_dm_ts"

    attr_reader :store

    def initialize(store:, slack:, allowed_users:, notify_channel:, stall_days:,
                   lookup: ->(isbn) { BookInfo.lookup(isbn) }, logger: Logger.new(nil))
      @store = store
      @slack = slack
      @allowed = allowed_users
      @notify_channel = notify_channel
      @stall_days = stall_days
      @lookup = lookup
      @logger = logger
    end

    def allowed?(user) = @allowed.include?(user)

    def ack_for(type, payload)
      submission_errors(payload) if type == "interactive" && payload["type"] == "view_submission"
    end

    def process(type, payload)
      case type
      when "events_api" then on_event(payload["event"] || {})
      when "interactive" then on_interaction(payload)
      end
    end

    def on_event(event)
      user = event["user"]
      return unless allowed?(user)

      if event["type"] == "message" && event["channel_type"] == "im"
        on_direct_message(event["channel"], user, event["text"], event["ts"], event)
      elsif event["type"] == "app_home_opened" && event["tab"] == "home"
        guard(user) { refresh_home(user) }
      end
    end

    # ライブで届いたものも、起動時に履歴から拾ったものも、ここを通る。ts で二重処理を防ぐ。
    def on_direct_message(channel, user, text, ts, raw = {})
      return if raw["bot_id"] || raw["subtype"] || !allowed?(user) || channel.nil? || ts.nil?
      return unless @store.claim_event("msg:#{channel}:#{ts}")

      guard(user) do
        @slack.post(channel, Commands.execute(Parser.parse(text), context("slack-dm")))
        last = @store.get_meta(LAST_SEEN_KEY)
        @store.set_meta(LAST_SEEN_KEY, ts) if last.nil? || ts.to_f > last.to_f
        refresh_home(user)
      end
    end

    # 止まっている間に届いた DM を処理する。初回は今より前を拾わない。
    def catch_up
      last = @store.get_meta(LAST_SEEN_KEY)
      unless last
        @store.set_meta(LAST_SEEN_KEY, format("%.6f", @store.now.to_f))
        return 0
      end

      @allowed.sum do |user|
        channel = @slack.call("conversations.open", { users: user }).dig("channel", "id")
        next 0 unless channel

        history = @slack.call("conversations.history", { channel: channel, oldest: last, limit: 200 })
        messages = Array(history["messages"]).select { |m| m["user"] == user }.sort_by { |m| m["ts"].to_f }
        messages.each { |m| on_direct_message(channel, user, m["text"], m["ts"], m) }
        messages.size
      end
    end

    def on_interaction(payload)
      user = payload.dig("user", "id")
      return unless allowed?(user)

      case payload["type"]
      when "block_actions"
        action = payload.dig("actions", 0) or return
        name = action["action_id"].split(":").first
        # メニューは選んだ項目の値に「操作:本の番号」が入っている
        name, id = action.dig("selected_option", "value").to_s.split(":") if name == "menu"
        id ||= action["value"]
        if name == "add_book"
          guard(user) { @slack.call("views.open", { trigger_id: payload["trigger_id"], view: Render.add_modal }) }
        elsif (modal = MODALS[name])
          guard(user) do
            book = @store.get_book(id.to_i)
            @slack.call("views.open", { trigger_id: payload["trigger_id"], view: Render.public_send(modal, book) }) if book && !book.deleted?
          end
        elsif (cmd = action_command(name, id.to_s))
          guard(user) { run_action(cmd, user, payload["response_url"], replace_original: name == "pick_book") }
        end
      when "view_submission"
        return unless submission_errors(payload).nil?

        cmd = submission_command(payload["view"]) or return
        guard(user) { run_action(cmd, user, nil) }
      end
    end

    # ボタンからの操作。元のメッセージがあればそこへ返し、ホームタブやモーダルからなら DM に送る
    def run_action(cmd, user, response_url, replace_original: false)
      message = Commands.execute(cmd, context("slack-button"))
      if response_url
        @slack.respond(response_url, message, replace_original: replace_original)
      else
        @slack.post(user, message)
      end
      refresh_home(user)
    end

    def refresh_home(user)
      @slack.call("views.publish", { user_id: user, view: Render.home_view(Commands.load_overview(@store, @store.now)) })
    end

    def send_weekly
      @slack.post(@notify_channel, Jobs.weekly_report(@store, @store.now))
    end

    def send_year_report
      notify(Commands.finished_list(@store, Stats.jst(@store.now).year))
    end

    def send_nudge
      message = Jobs.daily_nudge(@store, @store.now, @stall_days)
      @slack.post(@notify_channel, message) if message
    end

    # 失敗しても常駐は止めず、ログに残して本人に知らせる
    def guard(user = nil)
      yield
    rescue StandardError => e
      @logger.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}")
      if user
        begin
          @slack.post(user, Render.error("処理中にエラーが起きました。少し待ってからもう一度送ってください"))
        rescue StandardError
          nil
        end
      end
    end

    private

    def context(source) = Commands::Context.new(store: @store, source: source, lookup: @lookup)

    # ボタンやメニューの名前と、開く入力画面
    MODALS = {
      "log_page" => :page_modal, "edit" => :edit_modal, "delete" => :delete_modal, "note" => :note_modal,
    }.freeze

    def submitted(view, block) = view.dig("state", "values", block, "value", "value").to_s

    def metadata(view) = (JSON.parse(view["private_metadata"].to_s) rescue {})

    # モーダルの入力を、private_metadata の値だけで確かめる
    def submission_errors(payload)
      view = payload["view"] || {}
      meta = metadata(view)
      block, problem =
        case view["callback_id"]
        when "log_page"
          from = submitted(view, "from")
          to = submitted(view, "to")
          if !to.match?(/\A\d+\z/) || to.to_i < 1 then ["to", "1 以上の整数で入力してください"]
          elsif meta["total"] && to.to_i > meta["total"] then ["to", "総ページ（#{meta['total']}p）を超えています"]
          elsif !from.empty? && (!from.match?(/\A\d+\z/) || from.to_i < 1) then ["from", "1 以上の整数で入力してください"]
          elsif !from.empty? && from.to_i > to.to_i then ["from", "「どこまで」より後ろになっています"]
          end
        when "edit_book"
          raw = submitted(view, "total")
          if submitted(view, "title").strip.empty? then ["title", "書名を入れてください"]
          elsif !raw.empty? && (!raw.match?(/\A\d+\z/) || raw.to_i < meta["min"].to_i)
            ["total", "#{meta['min']} 以上の整数で入力してください（読んだ所より少なくはできません）"]
          end
        when "add_book"
          isbn = submitted(view, "isbn").strip
          if submitted(view, "title").strip.empty? && isbn.empty? then ["title", "書名か ISBN を入れてください"]
          elsif !isbn.empty? && Isbn.parse(isbn).nil? then ["isbn", "ISBN として正しくありません。番号を確かめてください"]
          end
        end
      problem && { response_action: "errors", errors: { block => problem } }
    end

    def submission_command(view)
      target = { kind: "id", id: metadata(view)["id"] }
      case view["callback_id"]
      when "log_page"
        from = submitted(view, "from")
        to = submitted(view, "to").to_i
        if from.empty?
          { kind: "page", target: target, value: to, relative: false }
        else
          { kind: "page", target: target, ranges: [[from.to_i, to]] }
        end
      when "edit_book"
        total = submitted(view, "total")
        { kind: "edit", target: target, title: submitted(view, "title"), total_pages: total.empty? ? nil : total.to_i }
      when "delete_book" then { kind: "delete", target: target }
      when "finish_note" then { kind: "note", target: target, text: submitted(view, "note") }
      when "add_book"
        title = submitted(view, "title").strip
        isbn = submitted(view, "isbn").strip
        total = submitted(view, "total")
        item = { query: isbn.empty? ? title : isbn, total_pages: total.empty? ? nil : total.to_i, title: title.empty? ? nil : title }
        { kind: "add", items: [item] }
      end
    end

    def action_command(name, value)
      case name
      when "pick_book"
        data = JSON.parse(value, symbolize_names: true)
        data[:cmd].merge(target: { kind: "id", id: data[:id] })
      when "undo" then { kind: "undo", batch_id: value }
      when "start_book", "start" then { kind: "start", target: { kind: "id", id: value.to_i } }
      when "pause", "finish" then { kind: name, target: { kind: "id", id: value.to_i } }
      when "finished_list" then { kind: "finished_list", year: nil }
      end
    end
  end
end
