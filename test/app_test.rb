# frozen_string_literal: true

require "test_helper"

class AppTest < Minitest::Test
  include StoreHelper

  OWNER = "U_OWNER"

  def setup
    @clock = FakeClock.new("2026-11-01T03:00:00Z")
    @store = new_store(@clock)
    @slack = FakeSlack.new
    @app = build_app(@slack)
  end

  def build_app(slack)
    Shiori::App.new(store: @store, slack: slack, allowed_users: [OWNER], notify_channel: OWNER, stall_days: 3,
                    lookup: ->(_) { nil })
  end

  def dm(text, ts:, user: OWNER, **extra)
    { "event" => { "type" => "message", "channel_type" => "im", "channel" => "D1", "user" => user, "text" => text, "ts" => ts }.merge(extra) }
  end

  def test_dm_records_and_refreshes_home
    add_book(@store, status: "reading")
    @app.process("events_api", dm("42", ts: "1.0"))
    assert_equal 42, @store.get_book(1).current_page
    assert_equal "D1", @slack.posts.last[0]
    assert(@slack.calls.any? { |m, _| m == "views.publish" })
  end

  def test_redelivered_message_is_processed_once
    add_book(@store, status: "reading")
    2.times { @app.process("events_api", dm("+10", ts: "1.0")) }
    assert_equal 10, @store.get_book(1).current_page
  end

  def test_ignores_strangers_and_bots
    add_book(@store, status: "reading")
    @app.process("events_api", dm("42", ts: "1.0", user: "U_OTHER"))
    @app.process("events_api", dm("42", ts: "2.0", "bot_id" => "B1"))
    assert_equal 0, @store.get_book(1).current_page
    assert_empty @slack.posts
  end

  def test_catch_up_processes_messages_sent_while_offline
    add_book(@store, status: "reading")
    assert_equal 0, @app.catch_up # 初回は基準時刻を記録するだけ
    offline = FakeSlack.new(history: [
      { "user" => OWNER, "text" => "+5", "ts" => "2000000002.000000" },
      { "user" => OWNER, "text" => "30", "ts" => "2000000001.000000" },
      { "user" => "B_BOT", "text" => "bot", "ts" => "2000000003.000000", "bot_id" => "B" },
    ])
    assert_equal 2, build_app(offline).catch_up
    # 古い順に処理される: 30 → +5
    assert_equal 35, @store.get_book(1).current_page
    assert_equal "2000000002.000000", @store.get_meta(Shiori::App::LAST_SEEN_KEY)
  end

  def submission(to, from = "", total: 100)
    view_submission("log_page", { id: 1, total: total }, "from" => from, "to" => to)
  end

  def test_modal_validation_is_answered_in_ack
    assert_equal "errors", @app.ack_for("interactive", submission("150"))[:response_action]
    assert_equal "errors", @app.ack_for("interactive", submission(""))[:response_action]
    assert_equal "errors", @app.ack_for("interactive", submission("60", "70"))[:response_action]
    assert_nil @app.ack_for("interactive", submission("60"))
    assert_nil @app.ack_for("interactive", submission("60", "40"))
  end

  def test_modal_submission_records_page_or_range
    add_book(@store, total: 100, status: "reading")
    @app.process("interactive", submission("30"))
    assert_equal [30, [[1, 30]]], @store.get_book(1).then { [_1.current_page, _1.ranges] }
    assert_equal OWNER, @slack.posts.last[0]

    @app.process("interactive", submission("60", "50"))
    assert_equal [60, [[1, 30], [50, 60]]], @store.get_book(1).then { [_1.current_page, _1.ranges] }
  end

  def test_log_button_opens_modal
    add_book(@store, status: "reading")
    @app.process("interactive", {
      "type" => "block_actions", "user" => { "id" => OWNER }, "trigger_id" => "T1",
      "actions" => [{ "action_id" => "log_page:1", "value" => "1" }],
    })
    method, payload = @slack.calls.last
    assert_equal "views.open", method
    assert_equal "log_page", payload[:view][:callback_id]
  end

  def menu_select(value)
    @app.process("interactive", {
      "type" => "block_actions", "user" => { "id" => OWNER }, "trigger_id" => "T1",
      "actions" => [{ "action_id" => "menu:1", "selected_option" => { "value" => value } }],
    })
  end

  def view_submission(callback_id, meta, values = {})
    {
      "type" => "view_submission", "user" => { "id" => OWNER },
      "view" => {
        "callback_id" => callback_id, "private_metadata" => JSON.generate(meta),
        "state" => { "values" => values.to_h { |block, v| [block, { "value" => { "value" => v } }] } },
      },
    }
  end

  def test_menu_runs_status_commands
    add_book(@store, status: "reading")
    menu_select("pause:1")
    assert_equal "paused", @store.get_book(1).status
    assert_equal OWNER, @slack.posts.last[0]
  end

  def test_menu_delete_confirms_in_modal_then_deletes
    add_book(@store)
    menu_select("delete:1")
    method, payload = @slack.calls.last
    assert_equal ["views.open", "delete_book"], [method, payload[:view][:callback_id]]
    assert_equal "tsundoku", @store.get_book(1).status

    @app.process("interactive", view_submission("delete_book", { id: 1 }))
    assert_equal "deleted", @store.get_book(1).status
  end

  def test_total_modal_rejects_less_than_read
    error = @app.ack_for("interactive", view_submission("set_total", { id: 1, min: 90 }, "total" => "80"))
    assert_equal "errors", error[:response_action]
    assert_nil @app.ack_for("interactive", view_submission("set_total", { id: 1, min: 90 }, "total" => "120"))
  end

  def test_pick_book_button_runs_original_command
    add_book(@store, title: "A", status: "reading")
    add_book(@store, title: "B", status: "reading")
    choose = Shiori::Commands.execute(Shiori::Parser.parse("+7"), Shiori::Commands::Context.new(store: @store, source: "t", lookup: nil))
    button = choose[:blocks][1][:elements].find { |b| b[:action_id] == "pick_book:2" }
    @app.process("interactive", {
      "type" => "block_actions", "user" => { "id" => OWNER }, "response_url" => "https://hooks",
      "actions" => [{ "action_id" => button[:action_id], "value" => button[:value] }],
    })
    assert_equal [0, 7], [@store.get_book(1).current_page, @store.get_book(2).current_page]
    assert @slack.responses.last[2][:replace_original]
  end

  def test_errors_are_reported_to_the_user
    broken = Class.new(FakeSlack) do
      def call(method, payload)
        raise "boom" if method == "views.publish"

        super
      end
    end.new
    add_book(@store, status: "reading")
    build_app(broken).process("events_api", dm("5", ts: "9.0"))
    assert_match "エラーが起きました", broken.last_text
  end
end
