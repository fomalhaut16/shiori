# frozen_string_literal: true

module Shiori
  # Slack に出すメッセージ（Block Kit）を組み立てる。DB には触らない。
  # メッセージは { text:, blocks: } の Hash。text は通知やプレビューに出る代わりの文。
  module Render
    # week は直近 7 日の日ごとのページ数（古い日から）
    Overview = Data.define(:reading, :paused, :tsundoku, :tsundoku_count, :finished_this_year, :week, :now)
    Weekly = Data.define(:pages, :books_touched, :finished, :overview, :from, :to)

    DIVIDER = { type: "divider" }.freeze
    SHELF_LIMIT = 5

    module_function

    def escape(text) = text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

    def truncate(text, max) = text.length > max ? "#{text[0, max - 1]}…" : text

    def mrkdwn(text) = { type: "mrkdwn", text: text }

    def plain(text) = { type: "plain_text", text: text, emoji: true }

    def section(text, accessory = nil)
      accessory ? { type: "section", text: mrkdwn(text), accessory: accessory } : { type: "section", text: mrkdwn(text) }
    end

    def context(text) = { type: "context", elements: [mrkdwn(text)] }

    def header(text) = { type: "header", text: plain(truncate(text, 150)) }

    def actions(elements) = { type: "actions", elements: elements }

    # action_id はブロック内で重複できないので、「種類:識別子」の形にする
    def button(text, action_id, value, style = nil)
      b = { type: "button", text: plain(truncate(text, 70)), action_id: action_id, value: value }
      style ? b.merge(style: style) : b
    end

    def title(book) = "『#{escape(book.title)}』"

    def plain_title(book) = "『#{book.title}』"

    def start_button(book, label = "読む: #{book.title}") = button(label, "start_book:#{book.id}", book.id.to_s)

    def undo_button(batch_id) = button("取り消す", "undo:#{batch_id}", batch_id)

    def log_button(book, label = "記録") = button(label, "log_page:#{book.id}", book.id.to_s, "primary")

    # 本ごとの「︙」メニュー。選んだ値は「操作:本の番号」
    def menu(book)
      options = case book.status
                when "reading" then [["中断する", "pause"], ["読了にする", "finish"]]
                when "paused" then [["再開する", "start"], ["読了にする", "finish"]]
                when "tsundoku" then [["読み始める", "start"]]
                else []
                end
      options += [["総ページを直す", "total"], ["削除する", "delete"]]
      {
        type: "overflow", action_id: "menu:#{book.id}",
        options: options.map { |label, op| { text: plain(label), value: "#{op}:#{book.id}" } },
      }
    end

    # 一覧では 1 段、1 冊だけを見せる返信では 3 段の地図にする
    def progress_text(v, rows: 1)
      b = v.book
      return "栞 #{b.current_page}p・読んだ #{b.read_count}p（総ページ未設定）" if v.percent.nil?

      "#{Stats.progress_bar(b, rows)}\n*#{v.percent}%*　読んだ #{b.read_count} / #{b.total_pages}p・残り #{v.remaining}p"
    end

    # 飛ばした所があるときだけ、栞の位置と未読の範囲を出す
    def skipped_text(book)
      gaps = Ranges.gaps(book.ranges)
      return nil if gaps.empty?

      rest = gaps.size > 3 ? " ほか#{gaps.size - 3}か所" : ""
      "栞 #{book.current_page}p・未読 #{Ranges.format(gaps.first(3))}#{rest}"
    end

    def pace_text(v)
      return "ここ#{Stats::PACE_WINDOW_DAYS}日の記録なし" unless v.pace.positive?

      pace = v.pace >= 10 ? v.pace.round : v.pace.round(1)
      v.eta_days ? "1日あたり #{pace}p・このペースならあと #{v.eta_days} 日" : "1日あたり #{pace}p"
    end

    def last_read_text(days)
      case days
      when ..0 then "今日"
      when 1 then "昨日"
      else "#{days}日前"
      end
    end

    def book_blocks(v, with_buttons: true)
      b = v.book
      text = ["*#{title(b)}*  ##{b.id}", progress_text(v), skipped_text(b)].compact.join("\n")
      blocks = [
        section(text, with_buttons ? menu(b) : nil),
        context("#{pace_text(v)}　最後の記録: #{last_read_text(v.idle_days)}"),
      ]
      blocks << actions([log_button(b, "ページを記録")]) if with_buttons
      blocks
    end

    def week_text(week) = "この7日 #{Stats.sparkline(week)}  計 #{week.sum}p"

    def info(text) = { text: text, blocks: [section(text)] }

    def error(text) = info("⚠️ #{text}")

    # label は範囲で記録したときの「120–144, 160–188」
    def updated(v, from_page, added, batch_id, finished_this_year, label = nil)
      b = v.book
      if b.status == "finished"
        lines = ["🎉 *#{title(b)}* を読み終えました！"]
        if b.started_at && b.finished_at
          lines << "#{Stats.days_between(b.started_at, b.finished_at) + 1}日で読了・今年 #{finished_this_year} 冊目"
        end
        return { text: "#{plain_title(b)} を読み終えました", blocks: [section(lines.join("\n")), actions([undo_button(batch_id)])] }
      end

      head = label ? "#{label} を記録" : "#{from_page} → *#{b.current_page}*p"
      head += "（+#{added}p）" if added.positive?
      blocks = [section(["*#{title(b)}*  #{head}", progress_text(v, rows: 3), skipped_text(b)].compact.join("\n")), context(pace_text(v))]
      if b.total_pages && b.current_page == b.total_pages
        blocks << context("最後のページまで来ました。未読の所を読まずに終えるなら「読了」と送ってください")
      end
      blocks << actions([undo_button(batch_id)])
      { text: "#{plain_title(b)} #{label || "#{from_page} → #{b.current_page}p"}", blocks: blocks }
    end

    def status_changed(v, note, batch_id)
      b = v.book
      buttons = b.status == "reading" ? [log_button(b, "ページを記録"), undo_button(batch_id)] : [undo_button(batch_id)]
      { text: "#{plain_title(b)} #{note}", blocks: [section("*#{title(b)}*  #{note}\n#{progress_text(v)}"), actions(buttons)] }
    end

    def deleted(book, batch_id)
      {
        text: "#{plain_title(book)} を削除しました",
        blocks: [section("🗑 *#{title(book)}* を削除しました。読んだ記録は残っています"), actions([undo_button(batch_id)])],
      }
    end

    def added(book, batch_id)
      detail = [book.author && escape(book.author), book.total_pages ? "#{book.total_pages}p" : "総ページ未設定"].compact.join("・")
      lines = ["📚 積読に追加しました: *#{title(book)}*  ##{book.id}", detail]
      lines << "総ページは「総ページ ##{book.id} 320」のように設定できます" unless book.total_pages
      {
        text: "#{plain_title(book)} を積読に追加しました",
        blocks: [section(lines.join("\n")), actions([start_button(book, "読み始める"), undo_button(batch_id)])],
      }
    end

    def choose(books, cmd)
      buttons = books.map { |b| button("##{b.id} #{b.title}", "pick_book:#{b.id}", JSON.generate(id: b.id, cmd: cmd)) }
      { text: "どの本ですか？", blocks: [section("どの本ですか？"), actions(buttons)] }
    end

    def pages_label(book) = book.total_pages ? "#{book.total_pages}p" : "総ページ未設定"

    def tsundoku_blocks(o, with_buttons:)
      return [section("積読はありません 🎉")] if o.tsundoku_count.zero?

      blocks = [section("*積読 #{o.tsundoku_count}冊*（古い順）")]
      o.tsundoku.each do |b|
        blocks << section("##{b.id} #{title(b)}　#{pages_label(b)}・積んで#{Stats.days_between(b.created_at, o.now)}日", menu(b))
      end
      rest = o.tsundoku_count - o.tsundoku.size
      blocks << context("…ほか#{rest}冊") if rest.positive?
      blocks << actions(o.tsundoku.first(3).map { |b| start_button(b) }) if with_buttons
      blocks
    end

    def paused_blocks(paused)
      return [] if paused.empty?

      blocks = [DIVIDER, section("*中断中 #{paused.size}冊*")]
      paused.first(SHELF_LIMIT).each do |b|
        pct = b.total_pages ? "（#{[100, b.read_count * 100 / b.total_pages].min}%）" : ""
        blocks << section("##{b.id} #{title(b)}　栞 #{b.current_page}p#{pct}", menu(b))
      end
      blocks << context("…ほか#{paused.size - SHELF_LIMIT}冊") if paused.size > SHELF_LIMIT
      blocks
    end

    def overview_blocks(o, show_week: true)
      blocks = [header(o.reading.empty? ? "読書中の本はありません" : "読書中 #{o.reading.size}冊")]
      blocks << context(week_text(o.week)) if show_week && o.week
      o.reading.each { |v| blocks.concat(book_blocks(v)) }
      blocks.concat(paused_blocks(o.paused))
      blocks << DIVIDER
      blocks.concat(tsundoku_blocks(o, with_buttons: o.reading.empty?))
      blocks << context("今年の読了 #{o.finished_this_year}冊")
    end

    def overview(o) = { text: "読書中 #{o.reading.size}冊・積読 #{o.tsundoku_count}冊", blocks: overview_blocks(o) }

    def home_view(o)
      hint = context("「ページを記録」のほか、DM に `128`（今のページ）、`+20`（進んだページ数）、`120-144 160-188`（読んだ範囲）と送っても記録できます。`?` で使い方")
      { type: "home", blocks: [*overview_blocks(o), DIVIDER, hint] }
    end

    def weekly(w)
      summary = if w.pages.positive?
                  "この1週間で *#{w.pages}p* 読みました（#{w.books_touched}冊）\n#{week_text(w.overview.week)}"
                else
                  "この1週間は記録がありませんでした"
                end
      blocks = [header("今週の読書 #{Stats.month_day(w.from)}〜#{Stats.month_day(w.to)}"), section(summary)]
      blocks << section("読み終えた本: #{w.finished.map { |b| title(b) }.join('、')}") unless w.finished.empty?
      blocks << DIVIDER
      { text: "今週の読書: #{w.pages}p", blocks: blocks.concat(overview_blocks(w.overview, show_week: false)) }
    end

    def nudge(views)
      {
        text: "しばらく開いていない本が#{views.size}冊あります",
        blocks: [section("しばらく開いていない本があります。数ページだけでもどうですか？"), *views.flat_map { |v| book_blocks(v) }],
      }
    end

    def suggest(books, now)
      lines = books.map { |b| "##{b.id} #{title(b)}　積んで#{Stats.days_between(b.created_at, now)}日" }
      {
        text: "積読から1冊選びませんか",
        blocks: [
          section("読書中の本がありません。積読から1冊どうですか？\n#{lines.join("\n")}"),
          actions(books.map { |b| start_button(b) }),
        ],
      }
    end

    def help
      text = [
        "*記録*　`128` 今のページ　`+20` 進んだページ数　`#3 128` 本を番号で指定　`メロス 128` 書名の一部で指定",
        "*飛ばし読み*　`120-144 160-188` 読んだ範囲（`120〜144` でも可）。進み具合は読んだページの合計で数えます",
        "*追加*　`追加 9784101006017`（ISBN から書名とページ数を取得）　`追加 書名 320`　複数行で一括追加",
        "*状態*　`開始 #3`　`読了`　`中断 #3`　`総ページ #3 350`　`削除 #3`",
        "*確認*　`一覧`（空のメッセージでも可）　`取消`（直前の記録を取り消す）",
        "ホームタブの各本の「︙」からも、中断・読了・総ページ・削除ができます",
      ].join("\n")
      { text: "使い方", blocks: [section(text)] }
    end

    # 検証に要る値は private_metadata に入れておき、送信時に DB を見ずに確かめられるようにする
    def modal(callback_id, title_text, submit_text, meta, blocks)
      {
        type: "modal", callback_id: callback_id, private_metadata: JSON.generate(meta),
        title: plain(title_text), submit: plain(submit_text), close: plain("やめる"), blocks: blocks,
      }
    end

    # テンキーで打てる欄を 2 つ。「どこから」が空なら栞の続きから、書けばその範囲を記録する
    def page_modal(book)
      number = lambda do |placeholder, focus|
        e = { type: "number_input", action_id: "value", is_decimal_allowed: false, min_value: "1", placeholder: plain(placeholder) }
        e[:max_value] = book.total_pages.to_s if book.total_pages
        e[:focus_on_load] = true if focus
        e
      end
      read = book.ranges.empty? ? "" : "\n読んだ所: #{Ranges.format(book.ranges)}"
      modal("log_page", "ページを記録", "記録", { id: book.id, total: book.total_pages }, [
        section("*#{title(book)}*\n栞 #{book.current_page}p#{book.total_pages ? " / #{book.total_pages}p" : ''}#{read}"),
        {
          type: "input", block_id: "from", optional: true, label: plain("どこから（飛ばして読んだときだけ）"),
          element: number.call("空なら #{book.current_page + 1}p から", false),
        },
        { type: "input", block_id: "to", label: plain("どこまで読みましたか"), element: number.call("例 #{book.current_page + 20}", true) },
      ])
    end

    def total_modal(book)
      min = [1, book.furthest_page].max
      element = { type: "number_input", action_id: "value", is_decimal_allowed: false, min_value: min.to_s, focus_on_load: true }
      element[:initial_value] = book.total_pages.to_s if book.total_pages
      modal("set_total", "総ページを直す", "保存", { id: book.id, min: min }, [
        section("*#{title(book)}*"),
        { type: "input", block_id: "total", label: plain("総ページ数"), element: element },
      ])
    end

    def delete_modal(book)
      modal("delete_book", "本を削除", "削除する", { id: book.id }, [
        section("*#{title(book)}* を削除しますか？\n一覧から消えます。読んだ記録は残り、あとから取り消すこともできます。"),
      ])
    end
  end
end
