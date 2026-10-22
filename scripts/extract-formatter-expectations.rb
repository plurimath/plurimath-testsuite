# frozen_string_literal: true

# Reads authored Ruby syntax only. No spec is loaded and no formatter is run.
require_relative "lib/portable_yaml"
require "json"
require "yaml"
require "digest"
require "open3"
require_relative "lib/model_recipes"

module FormatterExpectations
  class Unsupported < StandardError; end

  SCHEMA = "plurimath-fixtures/formatter-expectations/1"
  COMPONENTS = %w[BaseNotation FormatOptions FormattedNotation FormattedNumber Fraction Integer NotationRenderer Parts SignRenderer Significant Source].freeze
  OPERATIONS = {
    "BaseNotation" => %w[wrap], "FormattedNotation" => %w[to_s formatted_exponent],
    "FormattedNumber" => %w[to_s sign_text digits_string], "Fraction" => %w[format format_groups change_base],
    "Integer" => %w[apply format_groups chop_group number_to_base],
    "NotationRenderer" => %w[render], "SignRenderer" => %w[apply],
    "Significant" => %w[apply_parts], "Source" => %w[to_parts], "Parts" => %w[to_s],
  }.freeze
  FILES = %w[base_notation formatted_notation formatted_number fraction integer notation_renderer sign_renderer significant source].map do |name|
    "spec/plurimath/formatter/numbers/#{name}_spec.rb"
  end.freeze
  EXPECTED_COUNTS = [2, 12, 17, 18, 47, 7, 4, 4, 2].freeze

  def self.args(node)
    node.arguments&.arguments || []
  end

  def self.body(node)
    value = node.respond_to?(:body) ? node.body : nil
    value.is_a?(Prism::StatementsNode) ? value.body : []
  end

  class Recipes
    def initialize(component, bindings, helpers)
      @component = component
      @bindings = bindings
      @helpers = helpers
      @resolving = []
    end

    def emit(node)
      case node
      when Prism::StringNode then { "kind" => "literal", "value" => node.unescaped }
      when Prism::SymbolNode then { "kind" => "symbol", "value" => node.unescaped }
      when Prism::IntegerNode, Prism::FloatNode then { "kind" => "literal", "value" => node.value }
      when Prism::TrueNode then { "kind" => "literal", "value" => true }
      when Prism::FalseNode then { "kind" => "literal", "value" => false }
      when Prism::NilNode then { "kind" => "literal", "value" => nil }
      when Prism::ArrayNode then { "kind" => "array", "items" => node.elements.map { |entry| emit(entry) } }
      when Prism::HashNode, Prism::KeywordHashNode
        entries = node.elements.map do |entry|
          raise Unsupported, "hash splat" unless entry.is_a?(Prism::AssocNode)

          { "key" => emit(entry.key), "value" => emit(entry.value) }
        end
        raise Unsupported, "duplicate typed hash key" unless entries.map { |entry| entry["key"] }.uniq.length == entries.length

        { "kind" => "map", "entries" => entries }
      when Prism::LocalVariableReadNode then binding(node.name)
      when Prism::CallNode then call(node)
      else raise Unsupported, "unsupported formatter expression #{node.class}: #{node.location.slice}"
      end
    end

    def binding(name)
      key = name.to_s
      raise Unsupported, "cyclic formatter binding #{key}" if @resolving.include?(key)

      value = @bindings.fetch(key) { raise Unsupported, "unresolved formatter binding #{key}" }
      @resolving << key
      begin
        value.is_a?(Hash) ? value : emit(value)
      ensure
        @resolving.pop
      end
    end

    def call(node)
      if node.receiver.nil? && FormatterExpectations.args(node).empty? && !node.block
        return binding(node.name)
      end

      if node.receiver.nil? && @helpers.key?(node.name.to_s)
        parameters, expression = @helpers.fetch(node.name.to_s)
        arguments = FormatterExpectations.args(node)
        raise Unsupported, "helper arity differs" unless parameters.length == arguments.length && !node.block

        bindings = @bindings.merge(parameters.zip(arguments).to_h)
        return self.class.new(@component, bindings, @helpers).emit(expression)
      end
      if node.name == :new
        name = if node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :described_class && node.receiver.receiver.nil?
                 raise Unsupported, "described_class receiver has arguments or a block" unless FormatterExpectations.args(node.receiver).empty? && !node.receiver.block

                 @component
               else
                 constant = ModelRecipes.constant_name(node.receiver)
                 raise Unsupported, "formatter constructor namespace differs" unless constant.start_with?("Plurimath::Formatter::Numbers::")

                 constant.delete_prefix("Plurimath::Formatter::Numbers::")
               end
        raise Unsupported, "unsupported formatter constructor" unless COMPONENTS.include?(name) && !node.block

        positional, keywords = arguments(node)
        return { "kind" => "component", "name" => name, "args" => positional, "kwargs" => keywords }
      end
      method = node.name.to_s
      if method == "send"
        raw = FormatterExpectations.args(node)
        raise Unsupported, "only Fraction change_base may use send" unless raw.first.is_a?(Prism::SymbolNode) && raw.first.unescaped == "change_base"

        method = "change_base"
        positional, keywords = arguments(node, skip: 1)
      else
        positional, keywords = arguments(node)
      end
      receiver = emit(node.receiver)
      type = result_type(receiver)
      if type == "FormattedNotation" && method == "coefficient" && positional.empty? && keywords["entries"].empty?
        return { "kind" => "operation", "receiver" => receiver, "method" => method, "args" => positional, "kwargs" => keywords }
      end
      unless OPERATIONS.fetch(type, []).include?(method) && !node.block
        raise Unsupported, "unsupported #{type} formatter operation #{method}"
      end

      { "kind" => "operation", "receiver" => receiver, "method" => method, "args" => positional, "kwargs" => keywords }
    end

    def arguments(node, skip: 0)
      nodes = FormatterExpectations.args(node).drop(skip)
      keyword = nodes.last.is_a?(Prism::KeywordHashNode) ? nodes.pop : nil
      [nodes.map { |entry| emit(entry) }, keyword ? emit(keyword) : { "kind" => "map", "entries" => [] }]
    end

    def result_type(recipe)
      return recipe.fetch("name") if recipe["kind"] == "component"
      return "value" unless recipe["kind"] == "operation"

      case recipe["method"]
      when "render" then "FormattedNotation"
      when "coefficient" then "FormattedNumber"
      when "to_parts", "apply_parts" then "Parts"
      else "value"
      end
    end
  end

  class Extractor
    attr_reader :cases, :replacements, :ledger

    def initialize
      @cases = []
      @replacements = []
      @ledger = []
    end

    def extract(path, source)
      file_index = FILES.index(path)
      raise Unsupported, "formatter source path outside the selected family" unless file_index

      initial_count = @cases.length
      @path = path
      @source = source
      @sha256 = Digest::SHA256.hexdigest(source)
      parsed = Prism.parse(source)
      raise Unsupported, "invalid source #{path}" unless parsed.success?

      group = parsed.value.statements.body.find { |node| node.is_a?(Prism::CallNode) && node.receiver&.location&.slice == "RSpec" && node.name == :describe }
      raise Unsupported, "missing single formatter group" unless group

      constant = ModelRecipes.constant_name(FormatterExpectations.args(group).fetch(0))
      @component = constant.delete_prefix("Plurimath::Formatter::Numbers::")
      raise Unsupported, "unsupported described formatter class" unless constant == "Plurimath::Formatter::Numbers::#{@component}" && COMPONENTS.include?(@component)

      walk(FormatterExpectations.body(group.block), {}, {}, [])
      count = EXPECTED_COUNTS.fetch(file_index)
      unless @cases.length - initial_count == count
        raise Unsupported, "#{path}: expected #{count} authored output assertions; review unsupported or expanded source"
      end
    end

    def walk(statements, inherited, helpers, labels)
      bindings = inherited.dup
      helpers = helpers.dup
      statements.each do |node|
        if node.is_a?(Prism::CallNode) && node.name == :let && node.block
          name = FormatterExpectations.args(node).fetch(0)
          body = FormatterExpectations.body(node.block)
          raise Unsupported, "unsupported let" unless name.is_a?(Prism::SymbolNode) && body.length == 1

          bindings[name.unescaped] = body.first
        elsif node.is_a?(Prism::DefNode)
          parameters = node.parameters
          required = parameters&.requireds || []
          unless parameters && parameters.compact_child_nodes.length == required.length && required.all?(Prism::RequiredParameterNode) && FormatterExpectations.body(node).length == 1
            raise Unsupported, "unsupported formatter helper"
          end

          helpers[node.name.to_s] = [required.map { |entry| entry.name.to_s }, FormatterExpectations.body(node).first]
        end
      end
      statements.each do |node|
        next unless node.is_a?(Prism::CallNode) && node.block

        if %i[describe context].include?(node.name)
          label = FormatterExpectations.args(node).first
          raise Unsupported, "nonliteral context label" unless label.is_a?(Prism::StringNode)

          walk(FormatterExpectations.body(node.block), bindings, helpers, labels + [label.unescaped])
        elsif node.name == :it
          example(node, bindings, helpers, labels)
        elsif !%i[let].include?(node.name)
          raise Unsupported, "unexpected formatter scaffold #{node.name}"
        end
      end
    end

    def example(node, inherited, helpers, labels)
      bindings = inherited.dup
      FormatterExpectations.body(node.block).each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          bindings[statement.name.to_s] = statement.value
        elsif statement.is_a?(Prism::CallNode) && statement.name == :[]=
          raise Unsupported, "only authored symbols option writes supported" unless statement.receiver&.location&.slice == "symbols"

          key, value = FormatterExpectations.args(statement)
          recipe = Recipes.new(@component, bindings, helpers).binding("symbols")
          key_recipe = Recipes.new(@component, bindings, helpers).emit(key)
          raise Unsupported, "symbols write requires a map" unless recipe["kind"] == "map"

          entries = recipe.fetch("entries").reject { |entry| entry.fetch("key") == key_recipe }
          bindings["symbols"] = recipe.merge("entries" => entries + [{ "key" => key_recipe, "value" => Recipes.new(@component, bindings, helpers).emit(value) }])
        elsif assertion?(statement)
          assertion(statement, bindings, helpers, labels)
        else
          raise Unsupported, "unexpected formatter example statement #{statement.location.slice}"
        end
      end
    end

    def assertion?(node)
      node.is_a?(Prism::CallNode) && %i[to not_to].include?(node.name) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect
    end

    def assertion(node, bindings, helpers, labels)
      line = node.receiver.location.start_line
      record = { "path" => @path, "line" => line, "disposition" => "native_internal" }
      @ledger << record
      return if node.receiver.block || node.name != :to

      decoder = Recipes.new(@component, bindings, helpers)
      actual_node = FormatterExpectations.args(node.receiver).fetch(0)
      matcher = FormatterExpectations.args(node).fetch(0)
      comparison, expected, input_node = comparison(actual_node, matcher)
      return unless comparison

      begin
        actual = decoder.emit(input_node)
      rescue Unsupported
        return
      end
      return unless actual["kind"] == "operation" && decoder.result_type(actual) == "value"

      id = "#{File.basename(@path, '_spec.rb').tr('_', '-')}-#{line.to_s.rjust(3, '0')}"
      row = { "id" => id, "component" => @component, "input" => actual, "comparison" => comparison,
              "expected" => expected, "source" => { "path" => @path, "sha256" => @sha256, "line" => line, "contexts" => labels } }
      @cases << row
      replacement = "expect_shared_formatter_output(#{id.inspect}, #{input_node.location.slice})"
      @replacements << { "path" => @path, "start" => node.location.start_offset, "end" => node.location.end_offset,
                         "original" => node.location.slice, "replacement" => replacement, "id" => id }
      record.merge!("disposition" => "shared_formatter_output", "id" => id)
    end

    def comparison(actual, matcher)
      if matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && %i[be_a be_an].include?(matcher.name) && FormatterExpectations.args(matcher).length == 1 && FormatterExpectations.args(matcher).first.location.slice == "String"
        return ["text_kind", "text", actual]
      elsif matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && matcher.name == :eq && FormatterExpectations.args(matcher).length == 1
        expected = FormatterExpectations.args(matcher).first
        return ["eq", expected.unescaped, actual] if expected.is_a?(Prism::StringNode)
      elsif matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && matcher.name == :be_nil
        return ["nil", nil, actual]
      elsif matcher.is_a?(Prism::CallNode) && matcher.name == :<= && matcher.receiver&.location&.slice == "be" && actual.is_a?(Prism::CallNode) && actual.name == :length
        expected = FormatterExpectations.args(matcher).first
        return ["max_length", expected.value, actual.receiver] if expected.is_a?(Prism::IntegerNode)
      elsif matcher&.location&.slice == "be(true)" && actual.is_a?(Prism::CallNode) && actual.name == :all? && actual.receiver.is_a?(Prism::CallNode) && actual.receiver.name == :chars
        body = FormatterExpectations.body(actual.block)
        predicate = body.first
        if body.length == 1 && predicate.is_a?(Prism::CallNode) && predicate.location.slice == '["0", "1"].include?(c)'
          return ["alphabet", %w[0 1], actual.receiver.receiver]
        elsif body.length == 1 && predicate.is_a?(Prism::CallNode) && predicate.location.slice == '("0".."7").cover?(c)'
          return ["alphabet", ("0".."7").to_a, actual.receiver.receiver]
        end
      end

      [nil, nil, nil]
    end
  end

  def self.export(repository, revision)
    raise Unsupported, "expected a pinned full Ruby commit" unless /\A[0-9a-f]{40}\z/.match?(revision)

    extractor = Extractor.new
    FILES.each do |path|
      source, status = Open3.capture2("git", "-C", repository, "show", "#{revision}:#{path}")
      raise Unsupported, "missing pinned formatter source #{path}" unless status.success?

      extractor.extract(path, source)
    end
    raise Unsupported, "duplicate formatter case" unless extractor.cases.map { |row| row.fetch("id") }.uniq.length == extractor.cases.length

    [{ "schema" => SCHEMA, "provenance" => { "repository" => "https://github.com/plurimath/plurimath", "ruby_commit" => revision },
       "cases" => extractor.cases }, { "replacements" => extractor.replacements, "ledger" => extractor.ledger }]
  end
end

if $PROGRAM_NAME == __FILE__
  repository, revision, output, manifest = ARGV
  abort "usage: ruby #{$PROGRAM_NAME} RUBY_REPOSITORY FULL_COMMIT OUTPUT_YAML MANIFEST_JSON" unless manifest
  payload, ledger = FormatterExpectations.export(repository, revision)
  File.write(output, PortableYaml.dump(payload))
  File.write(manifest, "#{JSON.pretty_generate(ledger)}\n")
  puts "exported #{payload.fetch('cases').length} authored formatter output assertions"
end
