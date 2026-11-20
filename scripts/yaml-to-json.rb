#!/usr/bin/env ruby
# frozen_string_literal: true

# The Psych side of validate-portable-yaml.py. Keep it gem-free.
require "json"
require "yaml"

canonical = lambda do |value|
  case value
  when Hash
    value.each_key do |key|
      raise TypeError, "non-string key #{key.inspect}" unless key.is_a?(String)
    end
    value.keys.sort.to_h { |key| [key, canonical.call(value[key])] }
  when Array then value.map(&canonical)
  else value
  end
end

begin
  document = YAML.safe_load(File.read(ARGV.fetch(0), encoding: "UTF-8"),
                            aliases: false)
  puts JSON.generate(canonical.call(document), allow_nan: false,
                                               max_nesting: false)
rescue Psych::Exception, JSON::GeneratorError, TypeError, ArgumentError,
       SystemCallError => e
  warn "#{e.class}: #{e.message}"
  exit 1
end
