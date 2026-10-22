# frozen_string_literal: true

# Extract only complete, statically understood parser contexts. No spec loading.
require_relative "lib/portable_yaml"
require "digest"
require "json"
require "open3"
require "yaml"
require_relative "lib/model_recipes"

module ParserExpectations
  FORMATS = {
    "asciimath" => "Asciimath::Parser", "latex" => "Latex::Parser",
    "html" => "Html::Parser", "unicode_math" => "UnicodeMath::Parser",
  }.freeze

  SOURCE_SPECS = FORMATS.map do |format, parser|
    ["spec/plurimath/#{format}/parser_spec.rb", format, parser]
  end.concat([
    ["spec/plurimath/asciimath/asciidoctor_examples_spec.rb", "asciimath", "Asciimath::Parser"],
    ["spec/plurimath/asciimath/metanorma_examples_spec.rb", "asciimath", "Asciimath::Parser"],
    *%w[bipm itu jcgm nist].map { |name| ["spec/plurimath/asciimath/metanorma/mn_samples_#{name}_spec.rb", "asciimath", "Asciimath::Parser"] },
    ["spec/plurimath/latex/latexmath_aggregator_spec.rb", "latex", "Latex::Parser"],
    ["spec/plurimath/latex/metanorma_examples_spec.rb", "latex", "Latex::Parser"],
  ]).freeze

  class Extractor
    attr_reader :cases, :ledger, :sources

    def initialize(root:, revision:)
      @root, @revision = root, revision
      @cases, @ledger, @sources, @replacements = [], [], [], {}
      path = "spec/plurimath/fixtures/formula_modules/unicode_math_transform_values.rb"
      source = read_source(path)
      @sources << { "path" => path, "sha256" => Digest::SHA256.hexdigest(source) }
      @constants = ModelRecipes::Bindings.new.add_source(source)
      @decoder = ModelRecipes::Decoder.new(constants: @constants)
    end

    def extract
      SOURCE_SPECS.each do |path, format, parser|
        source = read_source(path)

        parsed = Prism.parse(source)
        raise ModelRecipes::Unsupported, "invalid Ruby source #{path}" unless parsed.success?

        @sources << { "path" => path, "sha256" => Digest::SHA256.hexdigest(source) }
        @replacements[path] = { source: source, replacements: [] }
        visit(parsed.value, [], path, format, parser)
      end
      raise ModelRecipes::Unsupported, "empty extraction" if @cases.empty?
      raise ModelRecipes::Unsupported, "duplicate case IDs" unless @cases.map { |row| row.fetch("id") }.uniq.length == @cases.length

      { "schema" => "plurimath-fixtures/parser-expectations/1",
        "source" => { "revision" => @revision, "files" => @sources },
        "cases" => @cases, "ledger" => @ledger }
    end

    def rewritten_source(path, original, replacements)
      output = original.b.dup
      replacements.sort_by(&:first).reverse_each do |start, length, ids|
        indent = original.byteslice(0, start).split("\n").last.to_s[/\A */].to_s
        text = Array(ids).map { |id| "it_behaves_like \"shared parser constructor expectation\", #{id.inspect}" }.join("\n#{indent}")
        output[start, length] = text.b
      end
      if path == "spec/plurimath/unicode_math/parser_spec.rb"
        output = output.lines.reject { |line| line == 'require "plurimath/fixtures/formula_modules/unicode_math_transform_values"' + "\n" }.join
      end
      helper = "../" * (path.count("/") - 1) + "support/shared_parser_examples"
      output.sub('require "spec_helper"', "require \"spec_helper\"\nrequire_relative #{helper.inspect}")
    end

    def previous_replacements(previous, path, original)
      records = previous.fetch("ledger").select { |entry| entry["file"] == path && entry["status"] == "exported" }
      all = calls(Prism.parse(original).value)
      records.map do |entry|
        if entry["replacement"]
          location = entry.fetch("replacement")
          source = original.byteslice(location.fetch("start"), location.fetch("length"))
          raise ModelRecipes::Unsupported, "previous replacement digest differs" unless Digest::SHA256.hexdigest(source) == location.fetch("sha256")

          [location.fetch("start"), location.fetch("length"), location.fetch("case_ids")]
        else
          matches = all.select { |node| context?(node) && node.location.start_line == entry.fetch("line") && Digest::SHA256.hexdigest(node.location.slice) == entry.fetch("context_sha256") }
          raise ModelRecipes::Unsupported, "previous source mapping differs" unless matches.length == 1

          node = matches.first
          [node.location.start_offset, node.location.length, entry["case_ids"] || [entry.fetch("case_id")]]
        end
      end.uniq
    end

    def rewrite!(previous: nil)
      outputs = @replacements.to_h do |path, data|
        original = data.fetch(:source)
        current = File.binread(File.join(@root, path))
        output = rewritten_source(path, original, data.fetch(:replacements))
        permitted = [original.b, output]
        permitted << rewritten_source(path, original, previous_replacements(previous, path, original)) if previous
        unless permitted.include?(current)
          raise ModelRecipes::Unsupported, "#{path}: source differs from pinned original and proven rewrites; refusing overwrite"
        end
        [path, output]
      end
      outputs.each { |path, output| File.binwrite(File.join(@root, path), output) }
    end

    private

    def read_source(path)
      source, status = Open3.capture2("git", "-C", @root, "show", "#{@revision}:#{path}")
      raise ModelRecipes::Unsupported, "missing source #{path}" unless status.success?

      source
    end

    def calls(node)
      return [] unless node

      [node, *node.compact_child_nodes.flat_map { |child| calls(child) }].grep(Prism::CallNode)
    end

    def statements(call)
      body = call.block&.body
      raise ModelRecipes::Unsupported, "missing simple block" unless body.is_a?(Prism::StatementsNode)

      body.body
    end

    def context?(node)
      node.is_a?(Prism::CallNode) && %i[context describe].include?(node.name) && node.block
    end

    def visit(node, ancestors, path, format, parser)
      return unless node
      if node.is_a?(Prism::CallNode) && node.name == :each && node.block &&
          extract_context_loop(node, ancestors, path, format, parser)
        return
      end


      if context?(node)
        descendants = node.block&.body
        if node.name == :context && calls(descendants).none? { |call| context?(call) }
          extract_context(node, ancestors, path, format, parser)
        end
        ancestors = ancestors + [node]
      elsif node.is_a?(Prism::CallNode) && node.block && !%i[it let subject around before after].include?(node.name)
        ancestors = ancestors + [node]
      end
      node.compact_child_nodes.each { |child| visit(child, ancestors, path, format, parser) }
    end

    def configuration(ancestors)
      result = {}
      ancestors.each do |scope|
        next unless context?(scope)

        statements(scope).each do |statement|
          next unless statement.is_a?(Prism::CallNode) && %i[around before after].include?(statement.name)
          raise ModelRecipes::Unsupported, "non-locale inherited hook" unless statement.name == :around

          result["locale"] = locale_hook(statement)
        end
      end
      result
    end

    def local_reference?(node, name)
      node.is_a?(Prism::LocalVariableReadNode) && node.name == name || variable?(node, name)
    end

    def one_parameter(block)
      parameters = block&.parameters&.parameters
      required = parameters&.requireds || []
      unless required.length == 1 && parameters.compact_child_nodes == required
        raise ModelRecipes::Unsupported, "unsupported hook parameters"
      end
      required.first.name
    end

    def locale_hook(hook)
      raise ModelRecipes::Unsupported, "unsupported locale hook call" unless hook.receiver.nil? && hook.arguments.nil?

      example = one_parameter(hook.block)
      body = statements(hook)
      call = body.first
      unless body.length == 1 && call.is_a?(Prism::CallNode) && call.name == :with_configuration &&
          call.receiver.is_a?(Prism::ConstantReadNode) && call.receiver.name == :Plurimath && call.arguments.nil?
        raise ModelRecipes::Unsupported, "around hook is not exact with_configuration scaffold"
      end
      config = one_parameter(call.block)
      body = statements(call)
      setter, run = body
      unless body.length == 2 && setter.is_a?(Prism::CallNode) && setter.name == :locale= &&
          local_reference?(setter.receiver, config) && setter.arguments&.arguments&.length == 1 &&
          setter.arguments.arguments.first.is_a?(Prism::SymbolNode) && setter.block.nil? &&
          run.is_a?(Prism::CallNode) && run.name == :run && local_reference?(run.receiver, example) &&
          run.arguments.nil? && run.block.nil?
        raise ModelRecipes::Unsupported, "around hook contains unrepresented configuration or work"
      end
      setter.arguments.arguments.first.unescaped
    end

    def variable?(node, name)
      node.is_a?(Prism::CallNode) && node.name == name && node.receiver.nil? &&
        node.arguments.nil? && node.block.nil?
    end

    def inherited_declaration(ancestors, method, name = nil)
      ancestors.reverse_each do |scope|
        next unless context?(scope)

        matches = statements(scope).select do |entry|
          entry.is_a?(Prism::CallNode) && entry.name == method &&
            (name.nil? || entry.arguments&.arguments&.first.is_a?(Prism::SymbolNode) &&
              entry.arguments.arguments.first.unescaped == name)
        end
        raise ModelRecipes::Unsupported, "ambiguous inherited declaration" if matches.length > 1
        return matches.first unless matches.empty?
      end
      nil
    end

    def validate_entrypoint(ancestors, bindings, parser)
      declared = ancestors.any? do |scope|
        next false unless scope.is_a?(Prism::CallNode) && scope.name == :describe &&
          scope.receiver.is_a?(Prism::ConstantReadNode) && scope.receiver.name == :RSpec

        ModelRecipes.constant_name(scope.arguments.arguments.first) == "Plurimath::#{parser}"
      end
      raise ModelRecipes::Unsupported, "described parser class differs" unless declared

      subject = inherited_declaration(ancestors, :subject)
      unless subject && subject.arguments&.arguments&.first.is_a?(Prism::SymbolNode) &&
          subject.arguments.arguments.first.unescaped == "formula"
        raise ModelRecipes::Unsupported, "unsupported inherited subject name"
      end
      expressions = statements(subject)
      parse = expressions.first
      unless expressions.length == 1 && parse.is_a?(Prism::CallNode) && parse.name == :parse &&
          parse.arguments.nil? && parse.block.nil?
        raise ModelRecipes::Unsupported, "unsupported actual parser callchain"
      end
      construct = parse.receiver
      unless construct.is_a?(Prism::CallNode) && construct.name == :new && construct.block.nil? &&
          variable?(construct.receiver, :described_class) && construct.arguments&.arguments&.length == 1
        raise ModelRecipes::Unsupported, "unsupported actual parser constructor"
      end
      argument = construct.arguments.arguments.first
      return "identity" if variable?(argument, :string)
      raise ModelRecipes::Unsupported, "unsupported actual parser input" unless variable?(argument, :parser_input)

      expression = bindings["parser_input"]
      unless expression
        declaration = inherited_declaration(ancestors, :let, "parser_input")
        expressions = declaration && statements(declaration)
        raise ModelRecipes::Unsupported, "missing parser_input definition" unless expressions&.length == 1

        expression = expressions.first
      end
      return "identity" if variable?(expression, :string)
      unless expression.is_a?(Prism::CallNode) && expression.name == :gsub && expression.block.nil? &&
          variable?(expression.receiver, :string) && expression.arguments&.arguments&.length == 2
        raise ModelRecipes::Unsupported, "unsupported parser_input transformation"
      end
      pattern, replacement = expression.arguments.arguments
      unless pattern.is_a?(Prism::RegularExpressionNode) && pattern.unescaped == "\\s" && pattern.options.zero? &&
          replacement.is_a?(Prism::StringNode) && replacement.unescaped.empty?
        raise ModelRecipes::Unsupported, "unsupported parser_input gsub arguments"
      end
      "strip_whitespace"
    end

    def tuple_parameters(block)
      parameters = block.parameters&.parameters
      required = parameters&.requireds || []
      unless !required.empty? && parameters.compact_child_nodes == required
        raise ModelRecipes::Unsupported, "unsupported literal each parameters"
      end
      required.map { |parameter| parameter.name.to_s }
    end

    def literal_iterations(call, bindings)
      unless call.name == :each && call.arguments.nil? && call.block
        raise ModelRecipes::Unsupported, "not a bounded literal each"
      end
      array = ModelRecipes.unwrap(@decoder.emit_ast(call.receiver, bindings: bindings))
      raise ModelRecipes::Unsupported, "each receiver is not a literal array" unless array["kind"] == "array"

      names = tuple_parameters(call.block)
      array.fetch("items").each_with_index.map do |item, index|
        tuple = names.length == 1 ? [item] : ModelRecipes.unwrap(item).fetch("items")
        raise ModelRecipes::Unsupported, "literal tuple arity differs" unless tuple.length == names.length

        ids = bindings.fetch("__memo_ids__", {}).dup
        names.each { |name| ids[name] = "each:#{call.location.start_offset}:#{index}:#{name}" }
        bindings.merge(names.zip(tuple).to_h).merge("__memo_ids__" => ids)
      end
    end

    def rewrite_record(node, ids)
      { "start" => node.location.start_offset, "length" => node.location.length,
        "sha256" => Digest::SHA256.hexdigest(node.location.slice), "case_ids" => ids }
    end

    def extract_context_loop(node, ancestors, path, format, parser)
      body = statements(node)
      return false unless body.length == 1 && context?(body.first) && body.first.name == :context

      before_cases, before_ledger = @cases.length, @ledger.length
      begin
        iterations = literal_iterations(node, {})
        raise ModelRecipes::Unsupported, "empty literal loop" if iterations.empty?

        iterations.each_with_index do |bindings, index|
          extract_observed_context(body.first, ancestors, path, format, parser,
                                   external: bindings, suffix: "-iteration-#{index + 1}", rewrite: false)
        end
        ids = @cases[before_cases..].map { |row| row.fetch("id") }
        record = rewrite_record(node, ids)
        @ledger[before_ledger..].each { |entry| entry["replacement"] = record }
        @replacements.fetch(path).fetch(:replacements) << [node.location.start_offset, node.location.length, ids]
        true
      rescue ModelRecipes::Unsupported
        @cases.slice!(before_cases..)
        @ledger.slice!(before_ledger..)
        false
      end
    end

    def parser_descriptor(expression, bindings, actuals, ancestors, parser, scope)
      if variable?(expression, :formula)
        input = ModelRecipes.unwrap(@decoder.emit_ast(bindings.fetch("string"), bindings: bindings))
        raise ModelRecipes::Unsupported, "formula input is not text" unless input["kind"] == "literal" && input["value"].is_a?(String)

        return { key: "#{scope}:subject", input: input.fetch("value"), transform: validate_entrypoint(ancestors, bindings, parser) }
      end
      if expression.is_a?(Prism::LocalVariableReadNode) && actuals.key?(expression.name.to_s)
        return actuals.fetch(expression.name.to_s)
      end
      unless expression.is_a?(Prism::CallNode) && expression.name == :parse && expression.arguments.nil? && expression.block.nil?
        raise ModelRecipes::Unsupported, "unsupported actual parse expression"
      end
      construct = expression.receiver
      unless construct.is_a?(Prism::CallNode) && construct.name == :new && construct.block.nil? &&
          variable?(construct.receiver, :described_class) && construct.arguments&.arguments&.length == 1
        raise ModelRecipes::Unsupported, "unsupported direct parser constructor"
      end
      input = ModelRecipes.unwrap(@decoder.emit_ast(construct.arguments.arguments.first, bindings: bindings))
      raise ModelRecipes::Unsupported, "direct parser input is not literal text" unless input["kind"] == "literal" && input["value"].is_a?(String)

      { key: "#{scope}:direct:#{expression.location.start_offset}", input: input.fetch("value"), transform: "identity" }
    end

    def append_observation(steps, descriptor, observation)
      step = { "parse_id" => descriptor.fetch(:key), "input" => descriptor.fetch(:input),
        "input_transform" => descriptor.fetch(:transform), "observations" => [observation] }
      if steps.last && steps.last["parse_id"] == step["parse_id"]
        steps.last.fetch("observations") << observation
      else
        steps << step
      end
    end

    def observation_assertion(node, bindings, actuals, ancestors, parser, scope, steps)
      unless node.is_a?(Prism::CallNode) && node.name == :to && node.block.nil? && node.arguments&.arguments&.length == 1
        raise ModelRecipes::Unsupported, "unsupported assertion operation"
      end
      expect = node.receiver
      matcher = node.arguments.arguments.first
      unless expect.is_a?(Prism::CallNode) && expect.name == :expect && expect.receiver.nil? && matcher.is_a?(Prism::CallNode) && matcher.receiver.nil?
        raise ModelRecipes::Unsupported, "unsupported matcher wrapper"
      end
      if matcher.name == :raise_error
        expression = statements(expect)
        args = matcher.arguments&.arguments || []
        unless expression.length == 1 && args.length == 1 && ModelRecipes.constant_name(args.first) == "Parslet::ParseFailed"
          raise ModelRecipes::Unsupported, "unsupported native refusal assertion"
        end
        descriptor = parser_descriptor(expression.first, bindings, actuals, ancestors, parser, scope)
        append_observation(steps, descriptor, { "kind" => "parse_error", "category" => "parse_error" })
        return
      end
      unless matcher.name == :eq && matcher.arguments&.arguments&.length == 1 && expect.block.nil? && expect.arguments&.arguments&.length == 1
        raise ModelRecipes::Unsupported, "unsupported positive parser observation"
      end
      actual = expect.arguments.arguments.first
      expected = @decoder.emit_ast(matcher.arguments.arguments.first, bindings: bindings)
      if actual.is_a?(Prism::CallNode) && %i[to_asciimath to_latex to_mathml to_omml to_html to_unicodemath].include?(actual.name)
        unless actual.arguments.nil? && actual.block.nil? && ModelRecipes.unwrap(expected)["kind"] == "literal" && ModelRecipes.unwrap(expected)["value"].is_a?(String)
          raise ModelRecipes::Unsupported, "unsupported render observation arguments/value"
        end
        descriptor = parser_descriptor(actual.receiver, bindings, actuals, ancestors, parser, scope)
        append_observation(steps, descriptor, { "kind" => "render_equal", "method" => actual.name.to_s, "expected" => expected })
      else
        unless ModelRecipes.unwrap(expected)["kind"] == "constructor"
          raise ModelRecipes::Unsupported, "model observation is not constructor data"
        end
        descriptor = parser_descriptor(actual, bindings, actuals, ancestors, parser, scope)
        append_observation(steps, descriptor, { "kind" => "model_equal", "expected" => expected })
      end
    end

    def observation_program(body, bindings, actuals, ancestors, parser, scope, steps)
      body.each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          if statement.value.is_a?(Prism::CallNode) && statement.value.name == :parse
            actuals[statement.name.to_s] = parser_descriptor(statement.value, bindings, actuals, ancestors, parser, scope)
          else
            bindings[statement.name.to_s] = statement.value
            ids = bindings.fetch("__memo_ids__", {}).merge(statement.name.to_s => "#{scope}:local:#{statement.name}")
            bindings["__memo_ids__"] = ids
          end
        elsif statement.is_a?(Prism::CallNode) && statement.name == :each && statement.block
          literal_iterations(statement, bindings).each_with_index do |iteration, index|
            observation_program(statements(statement), iteration, actuals.dup, ancestors, parser, "#{scope}:each#{index}", steps)
          end
        else
          observation_assertion(statement, bindings, actuals, ancestors, parser, scope, steps)
        end
      end
    end

    def extract_observed_context(node, ancestors, path, format, parser, external: {}, suffix: "", rewrite: true)
      body = statements(node)
      lets = body.select { |statement| statement.is_a?(Prism::CallNode) && statement.name == :let }
      hooks = body.select { |statement| statement.is_a?(Prism::CallNode) && statement.name == :around }
      examples = body.select { |statement| statement.is_a?(Prism::CallNode) && statement.name == :it }
      unless !examples.empty? && body.length == lets.length + hooks.length + examples.length
        raise ModelRecipes::Unsupported, "context has unrepresented declarations"
      end
      bindings = external.dup
      lets.each do |declaration|
        name = declaration.arguments&.arguments&.first
        expression = statements(declaration)
        unless name.is_a?(Prism::SymbolNode) && expression.length == 1
          raise ModelRecipes::Unsupported, "unrecognized observation let"
        end
        bindings[name.unescaped] = expression.first
      end
      config = configuration(ancestors)
      hooks.each { |hook| config["locale"] = locale_hook(hook) }
      # Class/subject must still be checked even if every observation parses
      # explicit text instead of reading the inherited subject.
      validate_entrypoint(ancestors, bindings, parser)
      stem = File.basename(path, "_spec.rb").tr("_", "-")
      ids = []
      examples.each_with_index do |example, index|
        id = "#{format.tr('_', '-')}-#{stem}-#{node.location.start_line}#{suffix}-example-#{index + 1}"
        steps = []
        observation_program(statements(example), bindings.dup, {}, ancestors, parser, id, steps)
        raise ModelRecipes::Unsupported, "empty observation program" if steps.empty?

        source = { "file" => path, "line" => node.location.start_line,
          "context_sha256" => Digest::SHA256.hexdigest(node.location.slice) }
        @cases << { "id" => id, "input_format" => format == "unicode_math" ? "unicode" : format,
          "parser_class" => parser, "input" => steps.first.fetch("input"),
          "input_transform" => steps.first.fetch("input_transform"), "configuration" => config,
          "configuration_mode" => hooks.empty? ? "assert" : "apply", "sequence" => steps, "source" => source }
        ids << id
      end
      source = { "file" => path, "line" => node.location.start_line,
        "context_sha256" => Digest::SHA256.hexdigest(node.location.slice),
        "assertion_sites" => calls(node).count { |call| call.name == :expect }, "status" => "exported",
        "case_ids" => ids }
      if rewrite
        source["replacement"] = rewrite_record(node, ids)
        @replacements.fetch(path).fetch(:replacements) << [node.location.start_offset, node.location.length, ids]
      end
      @ledger << source
    end

    def extract_context(node, ancestors, path, format, parser)
      record = { "file" => path, "line" => node.location.start_line,
        "context_sha256" => Digest::SHA256.hexdigest(node.location.slice),
        "assertion_sites" => calls(node).count { |call| call.name == :expect } }
      begin
        raise ModelRecipes::Unsupported, "context inside unsupported loop/block" if ancestors.any? { |scope| !context?(scope) }

        body = statements(node)
        lets = body.select { |statement| statement.is_a?(Prism::CallNode) && statement.name == :let }
        examples = body.select { |statement| statement.is_a?(Prism::CallNode) && statement.name == :it }
        unless examples.length == 1 && lets.length + 1 == body.length
          raise ModelRecipes::Unsupported, "context has hooks, nested declarations, or multiple/extra examples"
        end
        bindings = {}
        lets.each do |binding|
          name = binding.arguments&.arguments&.first
          raise ModelRecipes::Unsupported, "nonliteral let name" unless name.is_a?(Prism::SymbolNode)
          raise ModelRecipes::Unsupported, "duplicate let" if bindings.key?(name.unescaped)

          exprs = statements(binding)
          raise ModelRecipes::Unsupported, "multi-statement let" unless exprs.length == 1

          bindings[name.unescaped] = exprs.first
        end
        raise ModelRecipes::Unsupported, "no literal input let" unless bindings.key?("string")
        raise ModelRecipes::Unsupported, "extra let declarations" unless (bindings.keys - (format == "html" ? %w[string parser_input expected_value] : %w[string expected_value])).empty?

        input = ModelRecipes.unwrap(@decoder.emit_ast(bindings.fetch("string"), bindings: bindings))
        raise ModelRecipes::Unsupported, "input is not a literal string" unless input["kind"] == "literal" && input["value"].is_a?(String)

        transform = validate_entrypoint(ancestors, bindings, parser)
        checks = statements(examples.first)
        assertion = checks.last
        assignments = checks[0...-1]
        unless assignments.all? { |entry| entry.is_a?(Prism::LocalVariableWriteNode) } && assignments.length <= 1
          raise ModelRecipes::Unsupported, "extra example statements"
        end
        assignments.each { |assignment| bindings[assignment.name.to_s] = assignment.value }
        expected_node = equality_expected(assertion)
        if assignments.any? && !(expected_node.is_a?(Prism::LocalVariableReadNode) &&
            expected_node.name == assignments.first.name)
          raise ModelRecipes::Unsupported, "unused or indirect local assignment"
        end
        raise ModelRecipes::Unsupported, "extra assertions" unless record.fetch("assertion_sites") == 1

        recipe = @decoder.emit_ast(expected_node, bindings: bindings)
        unless ModelRecipes.unwrap(recipe)["kind"] == "constructor"
          raise ModelRecipes::Unsupported, "expected value is not a model constructor"
        end
        # Decode every authored let/assignment too, so discarded hidden work
        # cannot disappear merely because the equality did not reference it.
        bindings.each_value { |expr| @decoder.emit_ast(expr, bindings: bindings) }
        stem = File.basename(path, "_spec.rb").tr("_", "-")
        id = "#{format.tr('_', '-')}-#{stem}-#{node.location.start_line}"
        @cases << { "id" => id, "input_format" => format == "unicode_math" ? "unicode" : format,
          "parser_class" => parser, "input" => input.fetch("value"),
          "input_transform" => transform,
          "configuration" => configuration(ancestors), "expected" => recipe,
          "source" => record.reject { |key, _| key == "assertion_sites" } }
        record["replacement"] = rewrite_record(node, [id])
        @ledger << record.merge("status" => "exported", "case_id" => id)
        @replacements.fetch(path).fetch(:replacements) << [node.location.start_offset, node.location.length, id]
      rescue ModelRecipes::Unsupported => e
        before_cases, before_ledger = @cases.length, @ledger.length
        begin
          raise e if ancestors.any? { |scope| !context?(scope) }

          extract_observed_context(node, ancestors, path, format, parser)
        rescue ModelRecipes::Unsupported => observed_error
          @cases.slice!(before_cases..)
          @ledger.slice!(before_ledger..)
          @ledger << record.merge("status" => "retained", "reason" => observed_error.message)
        end
      end
    end

    def equality_expected(node)
      unless node.is_a?(Prism::CallNode) && node.name == :to && node.block.nil?
        raise ModelRecipes::Unsupported, "not a single positive equality"
      end
      expect_call = node.receiver
      actual = expect_call&.arguments&.arguments
      matcher = node.arguments&.arguments
      unless expect_call.is_a?(Prism::CallNode) && expect_call.receiver.nil? && expect_call.name == :expect &&
          expect_call.block.nil? && actual&.length == 1 && actual.first.is_a?(Prism::CallNode) &&
          actual.first.name == :formula && actual.first.receiver.nil? && actual.first.arguments.nil? &&
          matcher&.length == 1 && matcher.first.is_a?(Prism::CallNode) && matcher.first.name == :eq &&
          matcher.first.receiver.nil? && matcher.first.arguments&.arguments&.length == 1
        raise ModelRecipes::Unsupported, "not expect(formula).to eq(expected)"
      end
      matcher.first.arguments.arguments.first
    end
  end
end

if $PROGRAM_NAME == __FILE__
  root = ARGV.shift or abort "usage: extract-parser-expectations.rb GEM_ROOT REVISION OUTPUT [--rewrite]"
  revision = ARGV.shift or abort "missing revision"
  output = ARGV.shift or abort "missing output"
  rewrite = ARGV.delete("--rewrite")
  previous = nil
  if (index = ARGV.index("--previous"))
    previous_path = ARGV.fetch(index + 1)
    previous = YAML.safe_load(File.read(previous_path), aliases: false)
    ARGV.slice!(index, 2)
  end
  abort "unexpected arguments #{ARGV.inspect}" unless ARGV.empty?
  extractor = ParserExpectations::Extractor.new(root: root, revision: revision)
  data = extractor.extract
  File.write(output, PortableYaml.dump(data, line_width: -1))
  extractor.rewrite!(previous: previous) if rewrite
  puts JSON.generate(cases: data.fetch("cases").length, contexts: data.fetch("ledger").length,
                     retained: data.fetch("ledger").count { |row| row["status"] == "retained" })
end
