# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "tempfile"
module ReferenceFixtures
  ROOT = File.expand_path("..", __dir__)
  SOURCES = JSON.parse(File.read(File.join(__dir__, "sources.json"))).freeze
  def self.fetch(name)
    source = SOURCES.fetch(name)
    directory = File.join(ROOT, "tmp", name.end_with?(".txt") ? "rfc" : "registry", "sources")
    FileUtils.mkdir_p(directory)
    path = File.join(directory, name)
    unless File.file?(path)
      Tempfile.create("download", directory) do |file|
        success = system("curl", "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https",
                         "--retry", "3", "--connect-timeout", "10", "--max-time", "60", source.fetch("url"), "--output", file.path)
        raise "Download failed: #{name}" unless success
        raise "Checksum mismatch: #{name}" unless Digest::SHA256.file(file.path).hexdigest == source.fetch("sha256")

        File.rename(file.path, path)
      end
    end
    raise "Checksum mismatch: #{name}" unless Digest::SHA256.file(path).hexdigest == source.fetch("sha256")

    path
  end

  def self.prepare
    text = File.read(fetch("rfc8428.txt"))
    lines = text.lines.reject { |line| line.start_with?("Jennings,", "RFC 8428", "\f") }
    directory = File.join(ROOT, "tmp/rfc/fixtures")
    FileUtils.mkdir_p(directory)
    section = ""
    counts = Hash.new(0)
    examples = []
    index = 0
    while index < lines.length
      line = lines[index]
      section = Regexp.last_match(1) if line =~ /\A(\d+(?:\.\d+)*)\.  /
      break if section == "6"

      unless line.match?(/\A\s*\[\s*\z/)
        index += 1
        next
      end
      original = +line
      index += 1
      until index >= lines.length || original.lines.last.match?(/\A\s*\]\s*\z/) || original.include?("...")
        original << lines[index]
        index += 1
      end
      corrected = original.dup
      corrections = []
      if corrected.include?("...")
        corrected = corrected.sub(/,\s*\.\.\..*/m, "\n]")
        corrections << "Close the explicitly unfinished SenSML stream after its final complete record."
      end
      data = JSON.parse(corrected)
      if data.first.keys == ["bn"]
        data[1] = data.first.merge(data[1])
        data.shift
        corrected = JSON.pretty_generate(data)
        corrections << "Move the base-only first record into the first measurement to satisfy section 4.2."
      end
      counts[section] += 1
      name = "#{section}-#{counts[section]}"
      # Preserve numeric spelling: some JSON generators emit uppercase exponents,
      # which are valid JSON but forbidden by SenML.
      File.write(File.join(directory, "#{name}.json"), "#{corrected}\n")
      File.write(File.join(directory, "#{name}.original.txt"), original)
      examples << { "name" => name, "section" => section, "corrections" => corrections }
    end
    hex = text.split(/^6\.  CBOR Representation/, 2).last.split(/^7\.  XML Representation/, 2).first.lines.filter_map do |line|
      line[/\A [0-9a-f]{4} ([0-9a-f ]+)\s+\|/, 1]
    end.join.delete(" ")
    raise "Unexpected CBOR fixture size" unless hex.size == 390

    File.binwrite(File.join(directory, "6.cbor"), [hex].pack("H*"))
    fragments = text.scan(%r{coap://example\.com/temp#(rec=[0-9*,-]+)}).flatten.uniq
    raise "Unexpected RFC example count" unless examples.length == 14 && fragments.length == 5

    File.write(File.join(directory, "9.1-fragments.json"), JSON.pretty_generate(fragments))
    File.write(File.join(directory, "manifest.json"), "#{JSON.pretty_generate(examples)}\n")
    # Short notice permitted by IETF Trust Legal Provisions sections 4.e and 6.d.
    File.write(File.join(directory, "LICENSE"), <<~NOTICE)
      RFC Code Components used only for conformance testing.
      Copyright (c) 2018 IETF Trust and the persons identified as authors of the code. All rights reserved.
      Redistribution and use in source and binary forms, with or without modification, is permitted pursuant to,
      and subject to the license terms contained in, the Revised BSD License set forth in Section 4.c of the
      IETF Trust's Legal Provisions Relating to IETF Documents (https://trustee.ietf.org/license-info).
      Source and full notices: ../sources/rfc8428.txt
      Original examples and all corrections: *.original.txt and manifest.json.
    NOTICE
    puts "Prepared #{examples.length} JSON examples, one CBOR example and #{fragments.length} fragments in ignored tmp/rfc/fixtures"
  end
end
ReferenceFixtures.prepare if $PROGRAM_NAME == __FILE__
