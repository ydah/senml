# frozen_string_literal: true

require_relative "../lib/senml"
require "objspace"
require "tempfile"
count = 100_000
Tempfile.create("senml-benchmark") do |file|
  file.write("[")
  count.times do |index|
    file.write(",") if index.positive?
    file.write(JSON.generate(n: "sensor:#{index}", v: index, t: index))
  end
  file.write("]")
  file.rewind
  GC.start
  initial_heap = ObjectSpace.memsize_of_all
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  observed = SenML::StreamReader.new(file).count
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  raise "stream lost records" unless observed == count

  puts JSON.generate(operation: "stream", ruby: RUBY_DESCRIPTION, records: count, seconds: elapsed.round(3),
                     ruby_heap_growth_bytes: ObjectSpace.memsize_of_all - initial_heap)
end
pack = SenML::Pack.new(Array.new(10_000) { |index| { "bn" => "sensor:", "n" => index.to_s, "v" => index, "t" => -index } })
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
resolved = pack.resolve(now: 1_700_000_000)
raise "resolution lost records" unless resolved.size == 10_000 && resolved[0].time <= resolved[-1].time

puts JSON.generate(operation: "resolve", records: resolved.size, seconds: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3))
