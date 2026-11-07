# frozen_string_literal: true

require "net/http"
require "uri"

module Shiori
  # ISBN から書名・著者・総ページ数を引く。
  # openBD は国内の本に強いがページ数が欠けることがあるので、Google Books で補う。
  module BookInfo
    Info = Data.define(:title, :author, :total_pages)

    module_function

    def default_fetch(url)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |http| http.get(uri.request_uri) }
      raise "#{url}: #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body.force_encoding(Encoding::UTF_8))
    end

    # fetch は URL を受け取り、パース済みの JSON を返す
    def lookup(isbn, fetch: method(:default_fetch))
      openbd = safely { from_openbd(isbn, fetch) }
      return openbd if openbd&.total_pages

      google = safely { from_google_books(isbn, fetch) }
      title = openbd&.title || google&.title or return nil
      Info.new(title: title, author: openbd&.author || google&.author, total_pages: google&.total_pages)
    end

    def safely
      yield
    rescue StandardError
      nil
    end

    def from_openbd(isbn, fetch)
      rec = fetch.call("https://api.openbd.jp/v1/get?isbn=#{isbn}")&.first or return nil
      title = rec.dig("summary", "title")
      return nil if title.nil? || title.empty?

      pages = Array(rec.dig("onix", "DescriptiveDetail", "Extent"))
              .map { |e| Integer(e["ExtentValue"], 10, exception: false) }
              .find { |n| n&.positive? }
      Info.new(title: title, author: clean_author(rec.dig("summary", "author")), total_pages: pages)
    end

    def from_google_books(isbn, fetch)
      v = fetch.call("https://www.googleapis.com/books/v1/volumes?q=isbn:#{isbn}").dig("items", 0, "volumeInfo") or return nil
      return nil if v["title"].to_s.empty?

      Info.new(
        title: [v["title"], v["subtitle"]].compact.join(" "),
        author: v["authors"]&.join("・"),
        total_pages: v["pageCount"].to_i.positive? ? v["pageCount"] : nil,
      )
    end

    # openBD の著者欄は「太宰 治／著 山田 花子／訳」のような形なので、役割を落として名前だけにする
    def clean_author(raw)
      return nil if raw.nil? || raw.empty?

      names = raw.split(/／[^\s　]*[\s　]*/).map(&:strip).reject(&:empty?).uniq
      names.empty? ? nil : names.join("・")
    end
  end
end
