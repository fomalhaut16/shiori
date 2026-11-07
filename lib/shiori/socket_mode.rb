# frozen_string_literal: true

require "socket"
require "openssl"
require "websocket"

module Shiori
  # Slack Socket Mode のクライアント。PC から Slack へ接続しにいくので、公開 URL が要らない。
  # https://api.slack.com/apis/socket-mode
  #
  # 受信した封筒（envelope）には ack_for の結果ですぐ受け取りを返し、
  # 本来の処理は on_envelope に渡して別スレッドに任せる。
  class SocketMode
    class Disconnect < StandardError; end

    # この時間なにも届かない接続は、切れているのに気づけていないとみなして張り直す
    STALE_SECONDS = 3600
    MAX_BACKOFF = 60

    def initialize(app_token:, ack_for:, on_envelope:, on_connected:, logger:)
      @app_token = app_token
      @ack_for = ack_for
      @on_envelope = on_envelope
      @on_connected = on_connected
      @logger = logger
      @write_lock = Mutex.new
      @stopped = false
    end

    def run
      backoff = 1
      until @stopped
        started = Time.now
        begin
          connect_once
        rescue Disconnect => e
          @logger.info("socket: #{e.message}")
        rescue StandardError => e
          @logger.warn("socket: #{e.class}: #{e.message}") unless @stopped
        end
        break if @stopped

        # 長く繋がっていたなら待ち時間を戻す
        backoff = Time.now - started > 300 ? 1 : [backoff * 2, MAX_BACKOFF].min
        sleep backoff
      end
    end

    def stop
      @stopped = true
      @io&.close
    rescue IOError
      nil
    end

    private

    def open_url
      uri = URI("https://slack.com/api/apps.connections.open")
      req = Net::HTTP::Post.new(uri, "authorization" => "Bearer #{@app_token}",
                                     "content-type" => "application/x-www-form-urlencoded")
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) { |http| http.request(req) }
      data = JSON.parse(res.body)
      raise "apps.connections.open: #{data['error']}" unless data["ok"]

      data["url"]
    end

    def connect_once
      uri = URI(open_url)
      tcp = TCPSocket.new(uri.host, uri.port || 443)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new.tap(&:set_params))
      ssl.hostname = uri.host
      ssl.sync_close = true
      ssl.connect
      ssl.post_connection_check(uri.host)
      @io = ssl

      handshake = WebSocket::Handshake::Client.new(url: uri.to_s)
      ssl.write(handshake.to_s)
      handshake << ssl.readpartial(4096) until handshake.finished?
      raise "WebSocket handshake failed: #{handshake.error}" unless handshake.valid?

      @version = handshake.version
      incoming = WebSocket::Frame::Incoming::Client.new(version: @version)
      incoming << handshake.leftovers if handshake.leftovers

      loop do
        while (frame = incoming.next)
          handle_frame(frame)
        end
        # SSL の内部バッファに残っている分は select では見えないので先に読む
        if ssl.pending.zero? && !IO.select([ssl], nil, nil, STALE_SECONDS)
          raise Disconnect, "no traffic for #{STALE_SECONDS}s; reconnecting"
        end

        incoming << ssl.readpartial(16_384)
      end
    ensure
      begin
        @io&.close
      rescue IOError
        nil
      end
      @io = nil
    end

    def handle_frame(frame)
      case frame.type
      when :ping then send_frame(frame.to_s, :pong)
      when :close then raise Disconnect, "closed by server"
      when :text then on_text(frame.to_s.dup.force_encoding(Encoding::UTF_8))
      end
    end

    def on_text(text)
      msg = JSON.parse(text)
      case msg["type"]
      when "hello"
        @logger.info("socket: connected")
        @on_connected.call
      when "disconnect"
        raise Disconnect, "disconnect requested (#{msg['reason']})"
      else
        id = msg["envelope_id"] or return
        ack = begin
          @ack_for.call(msg["type"], msg["payload"] || {})
        rescue StandardError => e
          @logger.error("ack failed: #{e.class}: #{e.message}")
          nil
        end
        send_frame(JSON.generate(ack ? { envelope_id: id, payload: ack } : { envelope_id: id }), :text)
        @on_envelope.call(msg["type"], msg["payload"] || {})
      end
    end

    def send_frame(data, type)
      frame = WebSocket::Frame::Outgoing::Client.new(version: @version, data: data, type: type)
      @write_lock.synchronize { @io.write(frame.to_s) }
    end
  end
end
