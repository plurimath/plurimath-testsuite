# frozen_string_literal: true

# Writes model-roundtrip stage cases for the XML model gems, mml (MathML) and
# omml (OMML), from the inputs of an earlier generation of that language.
#
# Run it from a checkout of the gem, inside the gem's own bundle:
#
#   cd mml  && bundle exec ruby <testsuite>/scripts/generate-xml-stage-cases.rb \
#     mathml <testsuite> <from-generation> <out-dir> [<errors-file>]
#   cd omml && bundle exec ruby <testsuite>/scripts/generate-xml-stage-cases.rb \
#     omml <testsuite> <from-generation> <out-dir> [<errors-file>]
#
# For every case of every payload of stages/<language>/generations/<from>, in
# payload and file order, it writes one row with id "<id>.model-roundtrip" to
# <out-dir>/model-roundtrip-<group>.yaml. A row records the input, the typed
# model the gem parses it into, and the string the gem serializes that model
# to; or, when the gem raises, a refusal with the stage that raised
# (parse_error or serialize_error) and the exception class. Exceptions are
# never swallowed silently: each one is also written to <errors-file> with its
# message. As a diagnostic that never changes a row, it also parses each
# output again and lists in <errors-file> the rows whose output the gem cannot
# read back (reparse_error) or re-serializes differently (not_idempotent).
#
# A model is written in the canonical tagged form of
# docs/tree-parity-contract.adoc: {node: <model class>, fields: [...]} with the
# declared attributes that are not at their default, in declaration order. A
# model that tracks the order of its XML children also gets an
# "@element_order" field, because that order (and any mixed text) is part of
# what the gem serializes and is held nowhere else in the model.

require "yaml"
require "bigdecimal"

module XmlStageCases
  GEMS = {
    "mathml" => { require: "mml", entry: "Mml.parse",
                  parse: ->(input) { Mml.parse(input) } },
    "omml" => { require: "omml", entry: "Omml.parse",
                parse: ->(input) { Omml.parse(input) } },
  }.freeze

  ID_SUFFIX = ".model-roundtrip"

  class Untaggable < StandardError; end

  module_function

  def tag(value, path = [])
    case value
    when nil then { "nil" => true }
    when true, false then { "bool" => value }
    when Integer then { "int" => value.to_s }
    when Float then { "float" => value.inspect }
    when BigDecimal then { "decimal" => value.to_s }
    when Symbol then { "sym" => value.to_s }
    when String then tag_string(value)
    when Array then { "array" => value.map { |v| tag(v, path) } }
    when Hash
      { "hash" => value.map { |k, v| [tag(k, path), tag(v, path)] } }
    when Lutaml::Model::Serializable then tag_model(value, path)
    else
      raise Untaggable, "no tagged form for #{value.class}"
    end
  end

  def tag_string(value)
    if value.encoding == Encoding::UTF_8 && value.valid_encoding?
      { "str" => value.to_s }
    else
      { "bytes" => value.unpack1("H*"), "encoding" => value.encoding.name }
    end
  end

  def tag_model(model, path)
    if path.any? { |seen| seen.equal?(model) }
      raise Untaggable, "cycle at #{model.class}"
    end

    inner = path + [model]
    fields = model.class.attributes.filter_map do |name, _attribute|
      next if model.using_default?(name)

      [name.to_s, tag(model.public_send(name), inner)]
    end
    order = model.element_order if model.respond_to?(:element_order)
    if order && !order.empty?
      fields << ["@element_order", { "array" => order.map { |e| tag_order(e) } }]
    end
    { "node" => model.class.name, "fields" => fields }
  end

  def tag_order(entry)
    pairs = [["type", entry.type], ["name", entry.name]]
    pairs << ["text", entry.text_content] if entry.node_type == :text
    { "hash" => pairs.map { |k, v| [{ "str" => k }, tag(v)] } }
  end

  def run_case(gem, input)
    begin
      model = gem[:parse].call(input)
    rescue StandardError => e
      return [nil, "parse_error", e]
    end
    begin
      output = model.to_xml
    rescue StandardError => e
      return [nil, "serialize_error", e]
    end
    [{ "model" => tag(model), "output" => tag_string(output) }, nil, nil,
     output]
  end

  # Diagnostic only, never written to a row: parse the gem's own output again
  # and serialize it. Returns nil when that gives the same output.
  def reparse(gem, output)
    again = gem[:parse].call(output).to_xml
    return nil if again == output

    ["not_idempotent", nil, "re-serializing the output gives different " \
                            "bytes (#{output.bytesize} -> #{again.bytesize})"]
  rescue StandardError => e
    ["reparse_error", e, nil]
  end

  def main(argv)
    language, root, from, out_dir, errors_file = argv
    gem = GEMS.fetch(language) do
      abort "usage: generate-xml-stage-cases.rb mathml|omml <testsuite> " \
            "<from-generation> <out-dir> [<errors-file>]"
    end
    require gem[:require]

    source = File.join(root, "stages", language, "generations",
                       format("%06d", Integer(from, 10)), "payloads")
    files = Dir.glob(File.join(source, "*.yaml")).sort_by(&:b)
    abort "no payloads in #{source}" if files.empty?

    errors = []
    totals = Hash.new(0)
    files.each do |file|
      group = File.basename(file, ".yaml")
      cases = YAML.safe_load_file(file)["cases"].map do |c|
        input = c.fetch("input")
        expected, category, error, output = run_case(gem, input)
        id = "#{c.fetch('id')}#{ID_SUFFIX}"
        if error
          totals[category] += 1
          errors << [id, category, error.class.name, error.message]
          expected = { "refusal" => { "category" => category,
                                      "error_class" => error.class.name } }
        else
          totals["roundtrip"] += 1
          kind, again, note = reparse(gem, output)
          if kind
            totals[kind] += 1
            errors << [id, kind, again ? again.class.name : "-",
                       again ? again.message : note]
          end
        end
        { "id" => id, "input" => tag_string(input), "options" => {},
          "expected" => expected }
      end
      payload = {
        "schema" => "plurimath-stage/#{language}/cases/1",
        "group" => "model-roundtrip-#{group}",
        "description" => "#{gem[:entry]} model and to_xml output for every " \
                         "case of payloads/#{group}.yaml, ids " \
                         "<id>#{ID_SUFFIX}. Each model is its class with " \
                         "the declared attributes that are not at their " \
                         "default, in declaration order, plus @element_order " \
                         "where the model tracks child order. An input the " \
                         "gem raises on is a refusal with the raising stage " \
                         "and exception class.",
        "boundary" => "model-roundtrip",
        "cases" => cases,
      }
      text = "# Written by plurimath-testsuite " \
             "scripts/generate-xml-stage-cases.rb. Do not edit.\n" +
             YAML.dump(payload)
      File.binwrite(File.join(out_dir, "model-roundtrip-#{group}.yaml"), text)
    end

    if errors_file
      File.open(errors_file, "wb") do |io|
        errors.each do |id, category, klass, text|
          message = text.to_s.lines.first.to_s.strip[0, 400]
          io.write("#{language}\t#{id}\t#{category}\t#{klass}\t#{message}\n")
        end
      end
    end
    warn "#{language}: #{files.length} payloads, " \
         "#{totals.values_at('roundtrip', 'parse_error', 'serialize_error').sum} " \
         "rows, #{totals.sort.to_h}"
  end
end

XmlStageCases.main(ARGV) if $PROGRAM_NAME == __FILE__
