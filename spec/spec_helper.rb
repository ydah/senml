# frozen_string_literal: true

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
    add_filter "/script/"
    add_filter "/vendor/"
    add_filter "/tmp/"
    minimum_coverage line: 90
  end
end
require "senml"
require "stringio"
RSpec.configure { |config| config.order = :random }
