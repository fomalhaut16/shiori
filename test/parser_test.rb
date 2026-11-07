# frozen_string_literal: true

require "test_helper"

class ParserTest < Minitest::Test
  P = Shiori::Parser

  def test_bare_number_is_absolute_page
    assert_equal({ kind: "page", target: nil, value: 128, relative: false }, P.parse("128"))
  end

  def test_fullwidth_and_page_suffixes
    assert_equal 128, P.parse("１２８")[:value]
    assert_equal 128, P.parse("128ページ")[:value]
    assert_equal 128, P.parse("p.128")[:value]
    assert_equal 128, P.parse("128p")[:value]
  end

  def test_relative_pages
    assert_equal({ kind: "page", target: nil, value: 20, relative: true }, P.parse("+20"))
    assert_equal({ kind: "page", target: nil, value: -5, relative: true }, P.parse("－5"))
  end

  def test_targets
    assert_equal({ kind: "id", id: 3 }, P.parse("#3 128")[:target])
    assert_equal({ kind: "id", id: 3 }, P.parse("＃3 128")[:target])
    assert_equal({ kind: "query", text: "走れメロス" }, P.parse("『走れメロス』 +20")[:target])
  end

  def test_mention_and_entities_are_removed
    assert_equal 50, P.parse("<@U012ABC> 50")[:value]
  end

  def test_empty_message_lists
    assert_equal({ kind: "list" }, P.parse("  "))
  end

  def test_verbs
    assert_equal({ kind: "finish", target: nil }, P.parse("読了"))
    assert_equal({ kind: "start", target: { kind: "id", id: 4 } }, P.parse("開始 4"))
    assert_equal({ kind: "pause", target: { kind: "id", id: 2 } }, P.parse("中断 #2"))
    assert_equal({ kind: "undo", batch_id: nil }, P.parse("取消"))
    assert_equal({ kind: "help" }, P.parse("？"))
    assert_equal({ kind: "total", target: { kind: "id", id: 3 }, total_pages: 350 }, P.parse("総ページ #3 350"))
  end

  def test_add_single_and_bulk
    assert_equal({ kind: "add", items: [{ query: "9784101006017", total_pages: nil }] }, P.parse("追加 9784101006017"))
    bulk = P.parse("追加\n「人間失格」 180\n9784101006017\nアルジャーノンに花束を")
    assert_equal [
      { query: "人間失格", total_pages: 180 },
      { query: "9784101006017", total_pages: nil },
      { query: "アルジャーノンに花束を", total_pages: nil },
    ], bulk[:items]
  end

  def test_ranges
    assert_equal({ kind: "page", target: nil, ranges: [[120, 144], [160, 188]] }, P.parse("120-144 160-188"))
    assert_equal [[120, 144], [160, 188]], P.parse("１２０〜１４４、160～188")[:ranges]
    assert_equal [[120, 144]], P.parse("p.120-144")[:ranges]
    assert_equal({ kind: "id", id: 3 }, P.parse("#3 120-144, 160-188")[:target])
    assert_equal({ kind: "query", text: "SICP" }, P.parse("SICP 10-20")[:target])
    # 逆順の範囲は読み取らない
    assert_equal "invalid", P.parse("144-120")[:kind]
  end

  def test_finished_list
    assert_equal({ kind: "finished_list", year: nil }, P.parse("読了一覧"))
    assert_equal({ kind: "finished_list", year: 2025 }, P.parse("読了一覧 2025"))
    assert_equal "invalid", P.parse("読了一覧 去年")[:kind]
    # 「読了」は今までどおり読了の操作
    assert_equal "finish", P.parse("読了")[:kind]
  end

  def test_delete
    assert_equal({ kind: "delete", target: { kind: "id", id: 3 } }, P.parse("削除 #3"))
  end

  def test_invalid_inputs
    assert_equal "invalid", P.parse("こんにちは")[:kind]
    assert_equal "invalid", P.parse("128\n130")[:kind]
    assert_equal "invalid", P.parse("総ページ #3")[:kind]
    assert_equal "invalid", P.parse("追加")[:kind]
    assert_equal "invalid", P.parse("9999999")[:kind]
  end
end
