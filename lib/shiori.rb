# frozen_string_literal: true

require "json"
require "time"
require "securerandom"
require "logger"

module Shiori
  ROOT = File.expand_path("..", __dir__)
end

require_relative "shiori/ranges"
require_relative "shiori/book"
require_relative "shiori/parser"
require_relative "shiori/isbn"
require_relative "shiori/book_info"
require_relative "shiori/stats"
require_relative "shiori/schedule"
require_relative "shiori/store"
require_relative "shiori/render"
require_relative "shiori/commands"
require_relative "shiori/jobs"
require_relative "shiori/slack_client"
require_relative "shiori/app"
require_relative "shiori/config"
require_relative "shiori/socket_mode"
require_relative "shiori/runner"
