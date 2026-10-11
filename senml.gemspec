# frozen_string_literal: true

require_relative "lib/senml/version"
Gem::Specification.new do |spec|
  spec.name = "senml"
  spec.version = Senml::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]
  spec.summary = "Read, validate, and resolve SenML sensor measurements"
  spec.description = "RFC 8428 SenML JSON, base-value resolution, incremental SenSML streams, fragments, and CBOR."
  spec.homepage = "https://github.com/ydah/senml"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb", "sig/**/*.rbs", "data/*.yml", "README.md", "LICENSE.txt", "CHANGELOG.md", "SECURITY.md"] }
  spec.require_paths = ["lib"]
  spec.add_dependency "json", ">= 2.19.4", "< 4"
end
