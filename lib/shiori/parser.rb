# frozen_string_literal: true

module Shiori
  # Slack に書かれた 1 通のメッセージを、実行するコマンド（Hash）に変換する。
  # スマホから打つ前提なので、全角数字や「ページ」付きの書き方も受け付ける。
  #
  # コマンドの形:
  #   { kind: "page", target:, value:, relative: }
  #   { kind: "page", target:, ranges: [[from, to], ...] }   飛ばし読み（120-144 160-188）
  #   { kind: "start" | "finish" | "pause" | "delete", target: }
  #   { kind: "total", target:, total_pages: }
  #   { kind: "add", items: [{ query:, total_pages:, title: }] }   title は追加画面で書名と ISBN を両方入れたとき
  #   { kind: "finished_list", year: }   year が nil なら今年
  #   { kind: "note", target:, text: }   ひとこと感想（入力画面からだけ作る）
  #   { kind: "undo", batch_id: }  { kind: "list" }  { kind: "help" }
  #   { kind: "invalid", message: }
  # target は nil、{ kind: "id", id: }、{ kind: "query", text: } のどれか。
  module Parser
    VERBS = {
      "add" => "add", "追加" => "add", "ついか" => "add", "積読" => "add", "つんどく" => "add",
      "start" => "start", "開始" => "start", "読む" => "start", "よむ" => "start", "再開" => "start",
      "done" => "finish", "finish" => "finish", "読了" => "finish", "どくりょう" => "finish", "読み終わった" => "finish",
      "pause" => "pause", "drop" => "pause", "中断" => "pause",
      "delete" => "delete", "rm" => "delete", "削除" => "delete",
      "total" => "total", "総ページ" => "total", "ページ数" => "total",
      "list" => "list", "ls" => "list", "一覧" => "list", "いちらん" => "list", "状況" => "list",
      "finished" => "finished_list", "読了一覧" => "finished_list", "読んだ本" => "finished_list",
      "undo" => "undo", "取消" => "undo", "取り消し" => "undo", "とりけし" => "undo", "戻す" => "undo",
      "help" => "help", "ヘルプ" => "help", "?" => "help", "使い方" => "help",
    }.freeze

    MAX_PAGE = 100_000
    PAGE_RE = /\A(?:p\.?)?([+-]?\d+)(?:p|ページ|頁)?\z/i
    RANGE_RE = /\A(?:pp?\.?)?(\d+)(?:p|ページ|頁)?[-~〜−–—](?:p\.?)?(\d+)(?:p|ページ|頁)?\z/i

    module_function

    def normalize(text)
      text.to_s
          .gsub(/<@[A-Z0-9]+>/, " ")
          .gsub("&lt;", "<").gsub("&gt;", ">").gsub("&amp;", "&")
          .unicode_normalize(:nfkc)
          .gsub(/[^\S\n]+/, " ")
          .strip
    end

    def page_token(token)
      m = PAGE_RE.match(token) or return nil
      value = Integer(m[1], 10)
      return nil if value.abs > MAX_PAGE

      { value: value, relative: m[1].start_with?("+", "-") }
    end

    def range_token(token)
      m = RANGE_RE.match(token) or return nil
      a = Integer(m[1], 10)
      b = Integer(m[2], 10)
      [a, b] if a <= b && b <= MAX_PAGE
    end

    def unquote(text)
      text.sub(/\A[『「"](.*)[』」"]\z/, '\1').strip
    end

    def parse_target(text)
      t = text.strip
      return nil if t.empty?
      return { kind: "id", id: Regexp.last_match(1).to_i } if t =~ /\A#?(\d+)\z/

      { kind: "query", text: unquote(t) }
    end

    def parse_add_item(line)
      tokens = line.split(" ")
      if tokens.size >= 2
        p = page_token(tokens.last)
        return { query: unquote(tokens[0...-1].join(" ")), total_pages: p[:value] } if p && !p[:relative] && p[:value].positive?
      end
      { query: unquote(tokens.join(" ")), total_pages: nil }
    end

    def invalid(message) = { kind: "invalid", message: message }

    def parse(text)
      t = normalize(text)
      return { kind: "list" } if t.empty?

      first, *more = t.split("\n").map(&:strip).reject(&:empty?)
      tokens = first.split(" ")
      verb = VERBS[tokens.first.downcase]
      rest = tokens.drop(1).join(" ")

      if verb == "add"
        items = [rest, *more].reject(&:empty?).map { |l| parse_add_item(l) }
        return invalid("追加する本の ISBN か書名を書いてください（例: 追加 9784101006017）") if items.empty?

        return { kind: "add", items: items }
      end
      return invalid("複数行で送れるのは「追加」だけです") unless more.empty?

      case verb
      when "list", "help" then { kind: verb }
      when "finished_list"
        return { kind: verb, year: nil } if rest.empty?
        return invalid("年は「読了一覧 2025」のように 4 桁で書いてください") unless rest.match?(/\A\d{4}\z/)

        { kind: verb, year: rest.to_i }
      when "undo" then { kind: "undo", batch_id: nil }
      when "start", "finish", "pause" then { kind: verb, target: parse_target(rest) }
      when "delete"
        # 取り違えると困るので、本の指定を必須にする
        target = parse_target(rest) or return invalid("削除する本を「削除 #3」のように指定してください")

        { kind: "delete", target: target }
      when "total"
        parts = rest.split(" ")
        p = parts.empty? ? nil : page_token(parts.last)
        return invalid("総ページ数を数字で書いてください（例: 総ページ #3 350）") if p.nil? || p[:relative] || !p[:value].positive?

        { kind: "total", target: parse_target(parts[0...-1].join(" ")), total_pages: p[:value] }
      else
        # 末尾に続く範囲を集める。「#3 120-144, 160-188」なら #3 が本の指定
        words = first.split(/[\s,、]+/).reject(&:empty?)
        found = words.reverse.take_while { |w| range_token(w) }.reverse
        unless found.empty?
          return { kind: "page", target: parse_target(words[0...-found.size].join(" ")), ranges: found.map { |w| range_token(w) } }
        end

        p = page_token(tokens.last) or return invalid("「#{first}」を読み取れませんでした")
        { kind: "page", target: parse_target(tokens[0...-1].join(" ")), value: p[:value], relative: p[:relative] }
      end
    end
  end
end
