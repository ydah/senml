# frozen_string_literal: true

module SenML
  LABELS = YAML.safe_load_file(File.expand_path("../../data/labels.yml", __dir__)).transform_values do |fields|
    fields.transform_values(&:freeze).freeze
  end.freeze
  BASE_LABELS = LABELS.select { |_, fields| fields["base"] }.keys.freeze
  VALUE_LABELS = %w[v vs vb vd vlo].freeze
  module Units
    SYMBOLS = YAML.safe_load_file(File.expand_path("../../data/units.yml", __dir__)).map(&:freeze).freeze
    def self.registered?(symbol) = SYMBOLS.include?(symbol)
  end
end
