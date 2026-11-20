#!/usr/bin/env ruby
# Historical bytes stay immutable; replacements remain exact assertions.
require 'json'
require 'yaml'
require 'digest'
require 'pathname'

root = Pathname.new(ARGV.fetch(0, File.expand_path('..', __dir__))).realpath
manifest = JSON.parse((root / 'exceptions/rejection-offsets.json').read)
abort 'unknown rejection exception schema' unless manifest.fetch('schema') == 'plurimath-rejection-offset-exceptions/1'
path = manifest.fetch('path')
abort 'invalid rejection payload path' unless path.match?(%r{\Acorpus/[a-z]+/rejections\.yaml\z})
bytes = (root / path).binread
abort 'rejection payload digest changed' unless Digest::SHA256.hexdigest(bytes) == manifest.fetch('sha256')
oracle = manifest.fetch('oracle')
abort 'missing oracle evidence' unless oracle.fetch('commit').match?(/\A[0-9a-f]{40}\z/) && !oracle.fetch('reason').strip.empty?
payload = YAML.safe_load(bytes, aliases: false)
rows = payload.fetch('cases').to_h { |row| [row.fetch('id'), row] }
seen = []
manifest.fetch('exceptions').each do |entry|
  id = entry.fetch('id')
  abort "duplicate exception #{id}" if seen.include?(id)
  seen << id
  row = rows.fetch(id)
  abort "rejection input changed: #{id}" unless row.fetch('input') == entry.fetch('input')
  abort "not a rejection: #{id}" unless row.fetch('error').fetch('category') == 'parse_error'
  abort "historical offset changed: #{id}" unless row.fetch('error').fetch('index') == entry.fetch('historicalPreprocessedOffset')
  offsets = entry.values_at('historicalOriginalOffset', 'currentOriginalOffset', 'rubyByteOffset', 'rubyCharOffset')
  abort "invalid offset: #{id}" unless offsets.all? { |value| value.is_a?(Integer) && value >= 0 }
  abort "oracle character offset differs: #{id}" unless entry.fetch('currentOriginalOffset') == entry.fetch('rubyCharOffset')
end
abort 'empty exception list' if seen.empty?
puts "Validated #{seen.length} exact rejection offset exceptions (#{path})"
