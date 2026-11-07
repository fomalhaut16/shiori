# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/shiori"

# 時刻を進められる時計
class FakeClock
  attr_accessor :time

  def initialize(iso) = @time = Time.iso8601(iso)

  def call = @time

  def advance(days: 0, hours: 0) = @time += (days * 86_400) + (hours * 3600)
end

# 送ったものを記録するだけの Slack
class FakeSlack
  attr_reader :calls, :posts, :responses

  def initialize(history: [])
    @calls = []
    @posts = []
    @responses = []
    @history = history
  end

  def call(method, payload)
    @calls << [method, payload]
    case method
    when "conversations.open" then { "ok" => true, "channel" => { "id" => "D1" } }
    when "conversations.history" then { "ok" => true, "messages" => @history }
    else { "ok" => true }
    end
  end

  def post(channel, message) = @posts << [channel, message]

  def respond(url, message, **opts) = @responses << [url, message, opts]

  def last_text = @posts.last&.dig(1, :text)
end

module StoreHelper
  def new_store(clock = FakeClock.new("2026-11-01T03:00:00Z"))
    db = SQLite3::Database.new(":memory:", results_as_hash: true)
    Shiori::Store.migrate(db, File.join(Shiori::ROOT, "db", "migrations"))
    Shiori::Store.new(db, clock: clock)
  end

  # 本を 1 冊登録して返す
  def add_book(store, title: "走れメロス", total: 300, status: "tsundoku")
    store.create_book(title: title, author: nil, total_pages: total, isbn: nil, status: status, source: "test").first
  end

  # 先頭から page まで読んだことにする
  def read_to(store, book, page)
    store.apply_change(book, { current_page: page, ranges: [[1, page]] }, "test")
  end
end
