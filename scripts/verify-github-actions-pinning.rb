#!/usr/bin/env ruby
# frozen_string_literal: true

workflow_paths = Dir.glob(".github/workflows/**/*.{yml,yaml}").sort
violations = []

workflow_paths.each do |path|
  File.readlines(path, chomp: true).each_with_index do |line, index|
    match = line.match(/^\s*uses:\s*(["']?)([^"'\s#]+)\1/)
    next unless match

    reference = match[2]
    next if reference.start_with?("./", "docker://")
    next if reference.match?(/\A[^@\s]+@[0-9a-fA-F]{40}\z/)

    violations << "#{path}:#{index + 1}: #{reference}"
  end
end

if violations.any?
  warn "External GitHub Actions must be pinned to a full commit SHA:"
  violations.each { |violation| warn "  #{violation}" }
  exit 1
end

puts "Verified GitHub Actions pinning for #{workflow_paths.length} workflow file(s)."
