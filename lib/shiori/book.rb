# frozen_string_literal: true

module Shiori
  STATUS_LABEL = {
    "tsundoku" => "積読",
    "reading" => "読書中",
    "paused" => "中断",
    "finished" => "読了",
    "deleted" => "削除済み",
  }.freeze

  # books テーブルの 1 行。変更は with で新しい値を作る。
  # current_page は栞（最後に読んだページ）、read_ranges は読んだ範囲の JSON。
  Book = Data.define(
    :id, :title, :author, :total_pages, :current_page, :read_ranges, :status, :isbn,
    :created_at, :started_at, :finished_at, :updated_at, :last_nudged_at, :note,
  ) do
    def self.from_row(row)
      new(**members.to_h { |m| [m, row[m.to_s]] })
    end

    def ranges = JSON.parse(read_ranges || "[]")

    def read_count = Ranges.count(ranges)

    # 総ページをこれより小さくはできない
    def furthest_page = [current_page, ranges.last&.last || 0].max

    def deleted? = status == "deleted"
  end
end
