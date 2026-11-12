# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  BASE = { "SLACK_APP_TOKEN" => "xapp-x", "SLACK_BOT_TOKEN" => "xoxb-x", "ALLOWED_USER_IDS" => "U1" }.freeze

  def load(extra = {})
    Dir.mktmpdir { |dir| Shiori::Config.load(dir, BASE.merge(extra)) }
  end

  def test_scheduled_notifications_are_off_by_default
    c = load
    assert_equal [false, false, false], [c.daily_nudge, c.weekly_report, c.year_report]
  end

  def test_google_books_key_is_optional
    assert_nil load.google_books_key
    assert_equal "abc", load("GOOGLE_BOOKS_API_KEY" => " abc ").google_books_key
  end

  def test_scheduled_notifications_can_be_turned_on
    c = load("DAILY_NUDGE" => "on", "WEEKLY_REPORT" => "TRUE", "YEAR_REPORT" => "off")
    assert_equal [true, true, false], [c.daily_nudge, c.weekly_report, c.year_report]
  end
end
