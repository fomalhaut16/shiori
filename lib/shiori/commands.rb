# frozen_string_literal: true

module Shiori
  # Parser が作ったコマンドを実行し、返信するメッセージを返す
  module Commands
    # lookup は ISBN を受け取り BookInfo::Info か nil を返す
    Context = Data.define(:store, :source, :lookup)

    module_function

    def load_views(store, books, now)
      return [] if books.empty?

      since = Stats.iso(now - (Stats::PACE_WINDOW_DAYS * Stats::DAY))
      events = store.page_events_since(since).group_by { |e| e["book_id"] }
      last = store.last_page_times
      books.map { |b| Stats.view(b, events.fetch(b.id, []), last[b.id], now) }
    end

    def load_overview(store, now)
      Render::Overview.new(
        reading: load_views(store, store.list_books(["reading"]), now),
        paused: store.list_books(["paused"]),
        tsundoku: store.oldest_tsundoku(5),
        tsundoku_count: store.count_by_status("tsundoku"),
        finished_this_year: finished_this_year(store, now),
        week: Stats.daily_pages(store.page_events_since(Stats.iso(now - (7 * Stats::DAY))), now),
        now: now,
      )
    end

    def finished_this_year(store, now) = store.finished_since(Stats.iso(Stats.start_of_jst_year(now))).size

    def execute(cmd, c)
      case cmd[:kind]
      when "invalid" then return { text: cmd[:message], blocks: Render.error(Render.escape(cmd[:message]))[:blocks] + Render.help[:blocks] }
      when "help" then return Render.help
      when "list" then return Render.overview(load_overview(c.store, c.store.now))
      when "undo" then return undo(cmd[:batch_id], c)
      when "add" then return add(cmd[:items], c)
      end

      resolved = resolve(cmd[:target], cmd[:kind], c.store)
      return Render.error(resolved[:error]) if resolved[:error]
      return Render.choose(resolved[:candidates], cmd) if resolved[:candidates]

      book = resolved[:book]
      case cmd[:kind]
      when "page"
        return log_ranges(book, cmd[:ranges], c) if cmd[:ranges]

        log_page(book, cmd[:relative] ? book.current_page + cmd[:value] : cmd[:value], c)
      when "start"
        return Render.info("#{Render.title(book)} はすでに読書中です") if book.status == "reading"

        change_status(book, "reading", book.status == "paused" ? "を再開しました" : "を読み始めました", c)
      when "pause"
        return Render.info("#{Render.title(book)} はすでに中断中です") if book.status == "paused"

        change_status(book, "paused", "を中断にしました。再開は「開始 ##{book.id}」", c)
      when "finish"
        return Render.info("#{Render.title(book)} はすでに読了です") if book.status == "finished"

        # 飛ばした所は読んだことにしない。読んだページ数はそのまま残す
        finished_or_updated(c.store.apply_change(book, { status: "finished" }, c.source), c)
      when "total" then set_total(book, cmd[:total_pages], c)
      when "delete"
        change = c.store.apply_change(book, { status: "deleted" }, c.source)
        Render.deleted(book, change.batch_id)
      else Render.error("知らないコマンドです")
      end
    end

    def resolve(target, kind, store)
      case target&.dig(:kind)
      when "id"
        book = store.get_book(target[:id])
        return book && !book.deleted? ? { book: book } : { error: "##{target[:id]} の本は見つかりません" }
      when "query"
        found = store.find_books(target[:text])
        return { error: "「#{Render.escape(target[:text])}」に当たる本が見つかりません" } if found.empty?

        return found.size == 1 ? { book: found.first } : { candidates: found.first(5) }
      end

      # 本の指定がないとき、開始なら中断中と積読から、それ以外は読書中の本から選ぶ
      pool = kind == "start" ? (store.list_books(["paused"]) + store.oldest_tsundoku(5)).first(5) : store.list_books(["reading"])
      return { book: pool.first } if pool.size == 1
      return { candidates: pool.first(5) } if pool.size > 1

      if kind == "start"
        { error: "積読の本がありません。「追加 ISBN」か「追加 書名 ページ数」で登録してください" }
      else
        { error: "読書中の本がありません。「#3 128」のように本の番号を付けてください" }
      end
    end

    def log_page(book, page, c)
      return Render.error("ページは 0 以上で指定してください") if page.negative?
      if book.total_pages && page > book.total_pages
        return Render.error("#{Render.title(book)} の総ページは #{book.total_pages}p です。" \
                            "総ページを直すときは「総ページ ##{book.id} #{page}」と送ってください")
      end

      # 栞から先へ進んだぶんを読んだ範囲に足す。栞を戻すだけなら範囲は変えない
      ranges = page > book.current_page ? Ranges.add(book.ranges, [[book.current_page + 1, page]]) : book.ranges
      record(book, { current_page: page, ranges: ranges }, c, already: "#{Render.title(book)} はすでに #{page}p です")
    end

    def log_ranges(book, ranges, c)
      return Render.error("ページは 1 から数えてください") if ranges.any? { |a, _| a < 1 }

      over = ranges.map(&:last).max
      if book.total_pages && over > book.total_pages
        return Render.error("#{Render.title(book)} の総ページは #{book.total_pages}p です。" \
                            "総ページを直すときは「総ページ ##{book.id} #{over}」と送ってください")
      end

      label = Ranges.format(Ranges.normalize(ranges))
      # 栞は最後に書いた範囲の終わりに置く
      record(book, { current_page: ranges.last[1], ranges: Ranges.add(book.ranges, ranges) }, c,
             label: label, already: "#{Render.title(book)} の #{label} は記録済みです")
    end

    # 全ページを読んだら読了、そうでなければ読書中にする
    def record(book, patch, c, already:, label: nil)
      if book.total_pages && Ranges.count(patch[:ranges]) >= book.total_pages
        patch[:status] = "finished"
      elsif book.status != "reading"
        patch[:status] = "reading"
      end
      change = c.store.apply_change(book, patch, c.source)
      return Render.info(already) unless change

      finished_or_updated(change, c, label)
    end

    def finished_or_updated(change, c, label = nil)
      now = c.store.now
      view = load_views(c.store, [change.after], now).first
      count = change.after.status == "finished" ? finished_this_year(c.store, now) : 0
      added = change.after.read_count - change.before.read_count
      Render.updated(view, change.before.current_page, added, change.batch_id, count, label)
    end

    def change_status(book, status, note, c)
      change = c.store.apply_change(book, { status: status }, c.source)
      Render.status_changed(load_views(c.store, [change.after], c.store.now).first, note, change.batch_id)
    end

    def set_total(book, total, c)
      if total < book.furthest_page
        return Render.error("読んだ所（#{book.furthest_page}p まで）より少ない総ページは設定できません")
      end

      change = c.store.apply_change(book, { total_pages: total }, c.source)
      return Render.info("#{Render.title(book)} の総ページはすでに #{total}p です") unless change

      Render.status_changed(load_views(c.store, [change.after], c.store.now).first, "の総ページを #{total}p にしました", change.batch_id)
    end

    def add(items, c)
      lines = []
      created = nil
      items.each do |item|
        isbn = Isbn.parse(item[:query])
        if isbn.nil? && Isbn.looks_like?(item[:query])
          lines << "・#{Render.escape(item[:query])} は ISBN として正しくありません。番号を確かめてください"
          next
        end
        info = nil
        if isbn
          if (dup = c.store.find_by_isbn(isbn))
            if dup.deleted?
              change = c.store.apply_change(dup, { status: "tsundoku" }, c.source)
              created = [change.after, change.batch_id]
              lines << "・##{dup.id} #{Render.title(dup)}（削除していた本を積読に戻しました）"
            else
              lines << "・#{Render.title(dup)} はすでに登録してあります（##{dup.id}）"
            end
            next
          end
          info = begin
            c.lookup.call(isbn)
          rescue StandardError
            nil
          end
          unless info
            lines << "・ISBN #{isbn} の書誌が見つかりませんでした。「追加 書名 ページ数」で登録してください"
            next
          end
        end

        book, batch_id = c.store.create_book(
          title: info&.title || item[:query], author: info&.author,
          total_pages: item[:total_pages] || info&.total_pages, isbn: isbn, status: "tsundoku", source: c.source,
        )
        created = [book, batch_id]
        lines << "・##{book.id} #{Render.title(book)}#{book.total_pages ? "（#{book.total_pages}p）" : '（総ページ未設定）'}"
      end

      if items.size == 1
        return created ? Render.added(*created) : Render.error(lines.first.delete_prefix("・"))
      end

      { text: "積読に追加しました", blocks: [Render.section("*積読に追加しました*\n#{lines.join("\n")}")] }
    end

    def undo(batch_id, c)
      r = c.store.undo(batch_id)
      return Render.error(r[:reason]) unless r[:ok]
      return Render.info("↩️ #{Render.title(r[:book])} の登録を取り消しました") if r[:kind] == "deleted"

      after = r[:after]
      Render.info("↩️ #{Render.title(after)} を元に戻しました（栞 #{after.current_page}p・#{STATUS_LABEL[after.status]}）")
    end
  end
end
