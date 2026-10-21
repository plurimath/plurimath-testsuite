# frozen_string_literal: true

require "json"
require "yaml"

# Emit JSON-compatible authored fixtures consistently across YAML 1.1 and 1.2
# readers. A scoped visitor quotes all strings; no global Psych behavior changes.
module PortableYaml
  class Error < ArgumentError; end

  class StringQuotedTree < Psych::Visitors::YAMLTree
    def visit_NilClass(_value)
      @emitter.scalar("null", nil, nil, true, false, Psych::Nodes::Scalar::PLAIN)
    end

    def visit_String(value)
      @emitter.scalar(value, nil, nil, false, true, Psych::Nodes::Scalar::DOUBLE_QUOTED)
    end
  end

  module_function

  def dump(payload, **options)
    validate!(payload)
    # JSON roundtrip removes shared identities so Psych cannot emit aliases.
    plain = JSON.parse(JSON.generate(payload, allow_nan: false, max_nesting: false), max_nesting: false)
    options = { line_width: -1 }.merge(options)
    tree = StringQuotedTree.create(options)
    tree << plain
    tree.tree.yaml(nil, options)
  end

  def validate!(value, active = {})
    case value.class.name
    when "Hash", "Array"
      raise Error, "cyclic portable YAML data" if active.key?(value.object_id)

      active[value.object_id] = true
      begin
        if value.instance_of?(Hash)
          value.each do |key, child|
            raise Error, "portable YAML mapping keys must be strings" unless key.instance_of?(String)

            validate!(key, active)
            validate!(child, active)
          end
        else
          value.each { |child| validate!(child, active) }
        end
      ensure
        active.delete(value.object_id)
      end
    when "String"
      raise Error, "invalid portable YAML string encoding" unless value.valid_encoding?
    when "Integer", "TrueClass", "FalseClass", "NilClass"
      nil
    when "Float"
      raise Error, "non-finite portable YAML number" unless value.finite?
    else
      raise Error, "non-JSON portable YAML value #{value.class}"
    end
  end
end
