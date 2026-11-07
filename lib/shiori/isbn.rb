# frozen_string_literal: true

module Shiori
  module Isbn
    module_function

    # ISBN-10 / ISBN-13 を検証し、ISBN-13 にそろえる。ISBN でなければ nil。
    def parse(text)
      s = text.to_s.unicode_normalize(:nfkc).gsub(/[-\s]/, "").upcase
      if s.match?(/\A97[89]\d{10}\z/)
        check13(s[0, 12]) == s[12] ? s : nil
      elsif s.match?(/\A\d{9}[\dX]\z/) && valid10?(s)
        body = "978#{s[0, 9]}"
        body + check13(body)
      end
    end

    # 桁数は ISBN だが検証に通らないもの（打ち間違い）を、書名と取り違えないために使う
    def looks_like?(text)
      text.to_s.unicode_normalize(:nfkc).gsub(/[-\s]/, "").match?(/\A(97[89]\d{10}|\d{9}[\dXx])\z/)
    end

    def check13(first12)
      sum = first12.chars.each_with_index.sum { |c, i| c.to_i * (i.even? ? 1 : 3) }
      ((10 - (sum % 10)) % 10).to_s
    end

    def valid10?(s)
      s.chars.each_with_index.sum { |c, i| (10 - i) * (c == "X" ? 10 : c.to_i) } % 11 == 0
    end
  end
end
