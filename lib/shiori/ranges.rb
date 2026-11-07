# frozen_string_literal: true

module Shiori
  # 読んだページの範囲の集まり。[[1, 144], [160, 188]] のように、両端を含む範囲を昇順に持つ。
  # 重なりや隣り合う範囲はまとめるので、ページ数は単純な足し算で数えられる。
  module Ranges
    module_function

    def normalize(list)
      list.map { |a, b| [a, b].minmax }.sort.each_with_object([]) do |(a, b), out|
        if out.any? && a <= out.last[1] + 1
          out.last[1] = [out.last[1], b].max
        else
          out << [a, b]
        end
      end
    end

    def add(list, more) = normalize(list + more)

    def count(list) = list.sum { |a, b| b - a + 1 }

    # 最後に読んだページより前で、まだ読んでいない範囲
    def gaps(list)
      edges = [[0, 0], *list]
      edges.each_cons(2).filter_map { |(_, b), (c, _)| [b + 1, c - 1] if c > b + 1 }
    end

    def format(list) = list.map { |a, b| a == b ? a.to_s : "#{a}–#{b}" }.join(", ")

    # 総ページを width 個のマスに分け、半分以上読んだマスを true にする
    def cells(list, total, width)
      (0...width).map do |i|
        lo = (total * i / width) + 1
        hi = total * (i + 1) / width
        next false if hi < lo

        covered = list.sum { |a, b| [0, [b, hi].min - [a, lo].max + 1].max }
        covered * 2 >= hi - lo + 1
      end
    end
  end
end
