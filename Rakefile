# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
RSpec::Core::RakeTask.new(:spec)
desc "Fetch verified sources and extract temporary RFC examples"
task :fixtures do
  require_relative "script/prepare_fixtures"
  ReferenceFixtures.prepare
  ruby "script/update_registry.rb"
end
task spec: :fixtures
task test: :spec
task default: :spec
