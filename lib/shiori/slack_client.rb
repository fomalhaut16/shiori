# frozen_string_literal: true

require "net/http"
require "uri"

module Shiori
  class SlackClient
    class Error < StandardError; end

    def initialize(token)
      @token = token
    end

    def call(method, payload)
      data = post_json("https://slack.com/api/#{method}", payload, authorization: "Bearer #{@token}")
      raise Error, "Slack #{method} failed: #{data['error']}" unless data["ok"]

      data
    end

    # channel にユーザー ID を渡すと、アプリとの DM に投稿される
    def post(channel, message)
      call("chat.postMessage", { channel: channel, text: message[:text], blocks: message[:blocks], unfurl_links: false })
    end

    def respond(response_url, message, replace_original: false)
      post_json(response_url, { text: message[:text], blocks: message[:blocks], replace_original: replace_original })
    end

    private

    def post_json(url, payload, headers = {})
      uri = URI(url)
      req = Net::HTTP::Post.new(uri, { "content-type" => "application/json; charset=utf-8" }.merge(headers))
      req.body = JSON.generate(payload)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |http| http.request(req) }
      raise Error, "#{uri.host}#{uri.path}: HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      body = res.body.to_s.force_encoding(Encoding::UTF_8)
      body.start_with?("{") ? JSON.parse(body) : { "ok" => true }
    end
  end
end
