#!/usr/bin/env ruby
# frozen_string_literal: true

# squash-installs.rb — Group consecutive Dockerfile `RUN` instructions into
# subshell-isolated `( ... ) && ...` chains per input file.
#
# Usage:
#   ruby squash-installs.rb FILE [FILE...]
#
# Each input file should contain Dockerfile instructions (typically `RUN ...`,
# `ENV ...`, or `COPY ...` blocks from src/extra-installs/*.txt). Consecutive
# shell-form `RUN` lines are combined into one `RUN ( ... ) && ( ... )` layer
# so the resulting Dockerfile stays well under overlay2's layer limit while
# keeping `cd` and shell variables scoped per subshell. Non-`RUN` directives
# (`ENV`, `COPY`, `ARG`, etc.) flush the current group and pass through verbatim.
# Raises an error if a JSON/exec-form `RUN [...]` instruction is encountered.

if ARGV.empty? || ARGV.include?("-h") || ARGV.include?("--help")
  warn "Usage: ruby #{$PROGRAM_NAME} FILE [FILE...]"
  exit(ARGV.empty? ? 2 : 0)
end

out = []
ARGV.each do |f|
  insns = []
  cur = nil
  File.read(f, encoding: "UTF-8").each_line do |l|
    l = l.chomp
    if cur
      cur << "\n" << l
    else
      next if l.strip.empty? || l.lstrip.start_with?("#")

      cur = l.dup
    end
    if cur.end_with?("\\")
      next
    else
      insns << cur
      cur = nil
    end
  end
  insns << cur if cur

  group = []
  flush = lambda do
    next if group.empty?

    out << "RUN " + group.map { |b| "( #{b} )" }.join(" && \\\n    ")
    group.clear
  end

  insns.each do |i|
    if i =~ /\ARUN\s+(.*)\z/m
      body = Regexp.last_match(1)
      raise "#{f}: RUN in exec (JSON) form can't be squashed: #{i[0, 60]}" if body.start_with?("[")

      group << body
    else
      flush.call
      out << i
    end
  end
  flush.call
end

puts out
