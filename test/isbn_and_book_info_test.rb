# frozen_string_literal: true

require "test_helper"

class IsbnTest < Minitest::Test
  def test_isbn13_with_hyphens
    assert_equal "9784101006017", Shiori::Isbn.parse("978-4-10-100601-7")
  end

  def test_isbn10_is_converted
    assert_equal "9784101006017", Shiori::Isbn.parse("4101006016")
  end

  def test_rejects_bad_check_digit_and_titles
    assert_nil Shiori::Isbn.parse("9784101006018")
    assert_nil Shiori::Isbn.parse("走れメロス")
    assert_nil Shiori::Isbn.parse("1984")
  end
end

class BookInfoTest < Minitest::Test
  OPENBD = [{
    "summary" => { "title" => "走れメロス", "author" => "太宰 治／著" },
    "onix" => { "DescriptiveDetail" => { "Extent" => [{ "ExtentValue" => "286" }] } },
  }].freeze

  def test_openbd_with_pages_skips_google
    calls = []
    fetch = lambda { |url|
      calls << url
      OPENBD
    }
    info = Shiori::BookInfo.lookup("9784101006017", fetch: fetch)
    assert_equal ["走れメロス", "太宰 治", 286], [info.title, info.author, info.total_pages]
    assert_equal 1, calls.size
  end

  def test_google_fills_missing_pages
    fetch = lambda { |url|
      if url.include?("openbd")
        [{ "summary" => { "title" => "走れメロス", "author" => "太宰治／著" } }]
      else
        { "items" => [{ "volumeInfo" => { "title" => "Run, Melos", "pageCount" => 290 } }] }
      end
    }
    info = Shiori::BookInfo.lookup("9784101006017", fetch: fetch)
    assert_equal ["走れメロス", "太宰治", 290], [info.title, info.author, info.total_pages]
  end

  def test_google_key_is_sent_only_when_given
    urls = []
    fetch = lambda { |url|
      urls << url
      url.include?("openbd") ? [nil] : { "items" => [{ "volumeInfo" => { "title" => "Book", "pageCount" => 300 } }] }
    }
    Shiori::BookInfo.lookup("9780063320222", fetch: fetch)
    Shiori::BookInfo.lookup("9780063320222", fetch: fetch, google_key: "k+1")
    google = urls.grep(/googleapis/)
    refute_includes google[0], "key="
    assert google[1].end_with?("&key=k%2B1")
  end

  def test_network_errors_return_nil
    assert_nil Shiori::BookInfo.lookup("9784101006017", fetch: ->(_) { raise "offline" })
  end

  def test_clean_author_drops_roles
    assert_equal "ハラリ,ユヴァル・ノア・柴田 裕之", Shiori::BookInfo.clean_author("ハラリ,ユヴァル・ノア／著 柴田 裕之／訳")
  end
end
