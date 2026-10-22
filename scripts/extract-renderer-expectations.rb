# frozen_string_literal: true

# Export authored expectations from Ruby syntax, without loading specs or calling
# the implementation. Unsupported contexts are retained and listed in the ledger.
require_relative "lib/portable_yaml"
require "yaml"
require "json"
require "digest"
require "fileutils"
require "open3"
require_relative "lib/model_recipes"

module RendererExpectations
  class Unsupported < StandardError; end
  METHODS = %w[to_asciimath to_latex to_html to_mathml to_omml to_unicodemath to_display to_mathml_without_math_tag to_omml_without_math_tag].freeze
  GROUPS = %i[describe context].freeze
  EXAMPLES = %i[it specify example].freeze
  INTENT_REPLACEMENTS = [["$n)", "$naryand)"], ["𝐴", "A"], ["𝑎", "a"], ["𝛼", "a"], ["𝑏", "b"], ["𝑆", "S"], ["𝑛", "n"], ["𝑘", "k"], ["𝑡", "t"], ["𝑥", "x"], ["𝑦", "y"], ["𝑁", "N"], ["α", "a"], ["𝜋", "π"]].freeze
  WRAPPERS = { "Asciimath" => "asciimath", "Latex" => "latex", "Mathml" => "mathml", "Omml" => "omml", "UnicodeMath" => "unicode", "Html" => "html" }.freeze

  class Pipeline
    attr_reader :steps

    def initialize
      @steps = []
      @count = 0
    end

    def emit(kind, attributes)
      slot = "v#{@count += 1}"
      @steps << { "kind" => kind, "save" => slot }.merge(attributes)
      slot
    end

    def build(recipe)
      emit("build", "recipe" => recipe)
    end

    def decode(source, format, boundary: "wrapper", format_argument: nil)
      attributes = { "source" => source, "boundary" => boundary, "format" => format }
      attributes["format_argument"] = format_argument if format_argument
      emit("decode", attributes)
    end

    def render(source, method, args: [], kwargs: { "kind" => "map", "entries" => [] })
      emit("render", "source" => source, "operation" => { "method" => method, "args" => args, "kwargs" => kwargs, "normalizations" => [] })
    end

    def observe(source, observation, arguments = {})
      attributes = { "source" => source, "observation" => observation }
      attributes["arguments"] = arguments unless arguments.empty?
      emit("observe", attributes)
    end

    def check(source, expected, line, comparison: "eq", expected_slot: nil)
      step = { "kind" => "assert", "source" => source, "comparison" => comparison, "assertion_line" => line }
      step.merge!(expected_slot ? { "expected_slot" => expected_slot } : { "expected" => expected })
      @steps << step
    end

    def finish(**options)
      { "steps" => @steps, "assertion_lines" => @steps.filter_map { |step| step["assertion_line"] }.uniq }.merge(options.transform_keys(&:to_s))
    end
  end

  # Compiler for a finite mathematical pipeline. Ruby source names become local
  # data slots; the runner only builds models, renders, decodes and compares.
  # There is no general Ruby expression/call operation in the exported data.
  class ProgramCompiler
    def initialize(extractor, bindings)
      @extractor = extractor
      @bindings = bindings.dup
      @bindings["__memo_ids__"] = bindings.fetch("__memo_ids__", {}).dup
      @variables = {}
      @resolving = []
      @steps = []
      @counter = 0
      @no_error = false
      @assertion_lines = []
    end

    def args(node)
      @extractor.arguments(node)
    end

    def compile(example)
      @extractor.statements(example).each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          name = statement.name.to_s
          id = "local:#{name}:#{statement.location.start_line}"
          begin
            recipe = @extractor.decoder.emit_ast(statement.value, bindings: @bindings)
            @variables[name] = emit("build", "recipe" => { "kind" => "memo", "id" => id, "value" => recipe })
            @bindings[name] = recipe
          rescue Unsupported, ModelRecipes::Unsupported
            begin
              value = @extractor.value(statement.value, @bindings)
              recipe = { "kind" => "literal", "value" => value }
              raise Unsupported, "non-scalar static assignment" unless [String, Numeric, TrueClass, FalseClass, NilClass].any? { |type| value.is_a?(type) }

              @variables[name] = emit("build", "recipe" => { "kind" => "memo", "id" => id, "value" => recipe })
              @bindings[name] = recipe
            rescue Unsupported, ModelRecipes::Unsupported
              @variables[name] = expression(statement.value)
              @bindings[name] = statement.value
            end
          end
          @bindings.fetch("__memo_ids__")[name] = id
        elsif no_error?(statement)
          raise Unsupported, "mixed no-error/assertion sequence" if @steps.any? { |step| step["kind"] == "assert" }

          @no_error = true
          @assertion_lines << statement.receiver.location.start_line
          @extractor.statements(statement.receiver).each { |expression| self.expression(expression) }
        elsif assertion?(statement)
          compile_assertion(statement)
        elsif statement.is_a?(Prism::CallNode) && statement.name == :number_formatter= && statement.receiver&.location&.slice == "Plurimath.configuration" && args(statement).length == 1
          @steps << { "kind" => "configure_number_formatter", "recipe" => @extractor.decoder.emit_ast(args(statement).first, bindings: @bindings) }
        elsif statement.is_a?(Prism::StringNode) || statement.is_a?(Prism::InterpolatedStringNode)
          expression(statement)
        else
          raise Unsupported, "unsupported sequence statement #{statement.location.slice.lines.first.to_s.strip}"
        end
      end
      raise Unsupported, "sequence has no assertions" unless @no_error || @steps.any? { |step| step["kind"] == "assert" }

      result = { "steps" => @steps, "assertion_lines" => @assertion_lines }
      result["no_error"] = true if @no_error
      { "program" => result }
    end

    def assertion?(node)
      node.is_a?(Prism::CallNode) && %i[to not_to].include?(node.name) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect && node.receiver.receiver.nil? && !node.receiver.block
    end

    def no_error?(node)
      node.is_a?(Prism::CallNode) && node.name == :not_to && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect && node.receiver.block && args(node).length == 1 && args(node).first.is_a?(Prism::CallNode) && args(node).first.name == :raise_error && args(args(node).first).empty?
    end

    def compile_assertion(node)
      @assertion_lines << node.receiver.location.start_line
      matcher = args(node).fetch(0)
      unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil? && %i[eq eql match be_xml_equivalent_to be_empty be_a be_an include start_with end_with].include?(matcher.name)
        raise Unsupported, "unsupported sequence matcher"
      end
      actual_node = args(node.receiver).fetch(0)
      actual = expression(actual_node)
      comparison = "#{node.name == :not_to ? 'not_' : ''}#{matcher.name}"
      if %i[be_a be_an].include?(matcher.name)
        if args(matcher).first.location.slice == "String"
          raise Unsupported, "unsupported negative text-kind observation" unless node.name == :to

          comparison = "text_kind"
          expected = { "expected" => "text" }
        elsif actual_node.is_a?(Prism::CallNode) && actual_node.name == :first && actual_node.receiver.is_a?(Prism::CallNode) && actual_node.receiver.name == :value
          comparison = "#{node.name == :not_to ? 'not_' : ''}model_class"
          expected = { "expected" => @extractor.class_name(args(matcher).fetch(0), @bindings) }
        else
          raise Unsupported, "native Ruby type observation"
        end
      elsif matcher.name == :be_empty
        expected = { "expected" => nil }
      else
        expected_node = args(matcher).fetch(0)
        begin
          raise Unsupported, "expected source binding" if binding_name(expected_node)

          expected = { "expected" => @extractor.value(expected_node, @bindings) }
        rescue Unsupported, ModelRecipes::Unsupported
          expected = { "expected_slot" => expression(expected_node) }
        end
      end
      @steps << { "kind" => "assert", "source" => actual, "comparison" => comparison,
                  "assertion_line" => node.receiver.location.start_line }.merge(expected)
    end

    def expression(node)
      if (name = binding_name(node))
        return @variables.fetch(name) if @variables.key?(name)
        raise Unsupported, "cyclic sequence binding #{name}" if @resolving.include?(name)
        if @bindings.key?(name) && !@bindings.fetch(name).is_a?(Hash)
          @resolving << name
          begin
            begin
              recipe = @extractor.decoder.emit_ast(node, bindings: @bindings)
              return @variables[name] = emit("build", "recipe" => recipe)
            rescue Unsupported, ModelRecipes::Unsupported
              first_step = @steps.length
              slot = expression(@bindings.fetch(name))
              if @bindings.fetch("__source_lets__", {})[name]
                step = @steps.find { |entry| entry["save"] == slot }
                prior = step.fetch("memo", { "ids" => [], "dependencies" => [] })
                dependencies = @steps[first_step..].filter_map { |entry| entry["save"] unless entry["save"] == slot }
                step["memo"] = { "ids" => (prior.fetch("ids") + ["let:#{name}"]).uniq,
                                 "dependencies" => (prior.fetch("dependencies") + dependencies).uniq }
              end
              return @variables[name] = slot
            end
          ensure
            @resolving.pop
          end
        end
      end
      if node.is_a?(Prism::CallNode)
        if node.name == :read && node.receiver&.location&.slice == "File"
          return emit("build", "recipe" => { "kind" => "literal", "value" => @extractor.value(node, @bindings) })
        end
        if %i[parse_mathml parse_omml].include?(node.name) && node.receiver.nil? && args(node).length == 1
          format = node.name.to_s.delete_prefix("parse_")
          @extractor.utility_signature!(format)
          return emit("decode", "source" => expression(args(node).first), "boundary" => "#{format}_utility_helper", "format" => format)
        end
        if node.name == :convert && node.receiver.nil? && args(node).length == 1 && @extractor.relative == "spec/plurimath/integration/asciimath_spec.rb"
          @extractor.integration_signature!
          source = args(node).first
          unless source.is_a?(Prism::CallNode) && source.name == :string_to_formula && args(source).length == 2
            raise Unsupported, "unsupported integration input"
          end
          format = ModelRecipes.unwrap(@extractor.decoder.emit_ast(args(source).last, bindings: @bindings)).fetch("value")
          input = emit("decode", "source" => expression(args(source).first), "boundary" => "math_parse", "format" => format,
                       "format_argument" => @extractor.decoder.emit_ast(args(source).last, bindings: @bindings))
          %w[omml latex mathml asciimath].each do |target|
            %w[omml latex mathml asciimath].each do |intermediate|
              rendered = emit("render", "source" => input, "operation" => simple_operation("to_#{intermediate}"))
              decoded = emit("decode", "source" => rendered, "boundary" => "math_parse", "format" => intermediate,
                             "format_argument" => { "kind" => "symbol", "value" => intermediate })
              emit("render", "source" => decoded, "operation" => simple_operation("to_#{target}"))
            end
          end
          return input
        end
        if (normalization = normalization(node))
          return emit("transform", "source" => expression(node.receiver), "normalization" => normalization)
        end
        if node.name == :dump_ox_nodes && node.receiver.nil? && args(node).length == 1
          return emit("transform", "source" => expression(args(node).first), "normalization" => "dump_ox_nodes")
        end
        if node.name == :first && args(node).empty? && !(node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :value)
          return emit("transform", "source" => expression(node.receiver), "normalization" => "first_fragment_node")
        end
        if node.name == :dump && node.receiver&.location&.slice == "Plurimath.xml_engine"
          options = args(node).drop(1)
          unless options.length == 1 && options.first.location.slice.gsub(/\s/, "").delete_suffix(",") == "indent:2"
            raise Unsupported, "unsupported sequence XML dump"
          end
          return emit("transform", "source" => expression(args(node).first), "normalization" => "xml_engine_indent_2")
        end
        if METHODS.include?(node.name.to_s) && !node.block
          positional = args(node).dup
          kwargs = positional.last.is_a?(Prism::KeywordHashNode) ? @extractor.decoder.emit_ast(positional.pop, bindings: @bindings) : { "kind" => "map", "entries" => [] }
          operation = { "method" => node.name.to_s, "args" => positional.map { |arg| @extractor.decoder.emit_ast(arg, bindings: @bindings) }, "kwargs" => kwargs, "normalizations" => [] }
          return emit("render", "source" => expression(node.receiver), "operation" => operation)
        end
        if node.name == :parse && @extractor.class_name(node.receiver, @bindings) == "Math"
          positional = args(node)
          raise Unsupported, "sequence Math.parse arguments" unless positional.length == 2

          format_recipe = @extractor.decoder.emit_ast(positional.last, bindings: @bindings)
          format = ModelRecipes.unwrap(format_recipe).fetch("value")
          check_format!(format)
          return emit("decode", "source" => expression(positional.first), "boundary" => "math_parse", "format" => format, "format_argument" => format_recipe)
        end
        if %i[to_formula parse].include?(node.name) && args(node).empty? && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :new
          constructor = node.receiver
          class_name = @extractor.class_name(constructor.receiver, @bindings)
          boundary = node.name == :to_formula ? "wrapper" : { "Html::Parser" => "html_parser", "Asciimath::Parser" => "asciimath_parser" }[class_name]
          format = WRAPPERS[class_name] || { "Html::Parser" => "html", "Asciimath::Parser" => "asciimath" }[class_name]
          unless boundary && format && args(constructor).length == 1
            raise Unsupported, "unsupported sequence decode boundary #{class_name}.#{node.name}"
          end
          return emit("decode", "source" => expression(args(constructor).first), "boundary" => boundary, "format" => format)
        end
        if node.name == :first && args(node).empty? && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :value && args(node.receiver).empty?
          return emit("observe", "source" => expression(node.receiver.receiver), "observation" => "first_model_value")
        end
      end
      recipe = if node.is_a?(Prism::InterpolatedStringNode)
                 { "kind" => "literal", "value" => @extractor.value(node, @bindings) }
               else
                 @extractor.decoder.emit_ast(node, bindings: @bindings)
               end
      emit("build", "recipe" => recipe)
    end

    def normalization(node)
      return "strip" if node.name == :strip && args(node).empty?
      return unless node.name == :gsub && args(node).length == 2

      arguments = args(node)
      if ['/\\s/', '/\\s+/'].include?(arguments.first.location.slice) && @extractor.value(arguments.last, @bindings) == ""
        "remove_whitespace"
      elsif @extractor.value(arguments.first, @bindings) == "&amp;" && @extractor.value(arguments.last, @bindings) == "&"
        "unescape_ampersand"
      else
        raise Unsupported, "unsupported sequence normalization"
      end
    end

    def binding_name(node)
      return node.name.to_s if node.is_a?(Prism::LocalVariableReadNode)
      return node.name.to_s if node.is_a?(Prism::CallNode) && node.receiver.nil? && args(node).empty? && !node.block
    end

    def emit(kind, attributes)
      slot = "v#{@counter += 1}"
      @steps << { "kind" => kind, "save" => slot }.merge(attributes)
      slot
    end

    def check_format!(format)
      raise Unsupported, "unsupported sequence format #{format.inspect}" unless %w[asciimath latex mathml omml unicode html].include?(format)
    end

    def simple_operation(method)
      { "method" => method, "args" => [], "kwargs" => { "kind" => "map", "entries" => [] }, "normalizations" => [] }
    end
  end

  class Extractor
    attr_reader :cases, :ledger, :dependencies, :decoder, :relative

    def initialize(root)
      @root = File.expand_path(root)
      @dependencies = []
      constants = ModelRecipes::Bindings.new
      %w[expected_values line_break_values unicode_math_transform_values unicode_math_string_values].each do |file|
        path = File.join(@root, "spec/plurimath/fixtures/formula_modules/#{file}.rb")
        relative = path.delete_prefix("#{@root}/")
        text = source_text(relative)
        constants.add_source(text)
        @dependencies << { "path" => relative, "sha256" => Digest::SHA256.hexdigest(text) }
      end
      @constants = constants
      @decoder = ModelRecipes::Decoder.new(constants: constants)
      @cases = []
      @ledger = []
    end

    def source_text(relative)
      unless relative.is_a?(String) && relative.start_with?("spec/") && !relative.split("/").include?("..")
        raise Unsupported, "source path outside spec"
      end
      unless ENV["RENDERER_SOURCE_REVISION"]
        return File.read(File.join(@root, relative), encoding: "UTF-8")
      end

      text, status = Open3.capture2("git", "-C", @root, "show", "#{ENV.fetch('RENDERER_SOURCE_REVISION')}:#{relative}")
      raise Unsupported, "cannot read source revision #{relative}" unless status.success?

      text
    end

    def source_ast(relative)
      result = Prism.parse(source_text(relative))
      raise Unsupported, "cannot parse source #{relative}" unless result.success?

      result.value
    end

    def arguments(node)
      node.arguments&.arguments || []
    end

    def class_name(node, bindings)
      name = if node.is_a?(Prism::CallNode) && node.receiver.nil? && arguments(node).empty?
               binding = bindings[node.name.to_s]
               binding.is_a?(Hash) && ModelRecipes.unwrap(binding)["kind"] == "class" ? ModelRecipes.unwrap(binding).fetch("name") : nil
             else
               ModelRecipes.constant_name(node).delete_prefix("Plurimath::")
             end
      name
    rescue ModelRecipes::Unsupported
      nil
    end

    def utility_signature!(format)
      signatures = {
        "mathml" => "c02e23528a48e50cd502bac8b2a670fe2d30e1516503976e58b4aafddca5e6a6",
        "omml" => "6b637bbf72ecbd1de6bdb59cca9f98a55cf000496a1f7cc22a01b147d2a0a3f5"
      }
      raise Unsupported, "utility helper file differs" unless @relative == "spec/plurimath/#{format}/utility_spec.rb"

      method = descendants(@ast).find { |node| node.is_a?(Prism::DefNode) && node.name == "parse_#{format}".to_sym }
      raise Unsupported, "utility helper changed" unless method && Digest::SHA256.hexdigest(method.location.slice) == signatures.fetch(format)
    end

    def integration_signature!
      expected = {
        "convert" => "7597d658bb79aebf64b2797a9a86b7180a99e65a361b23a87392607615020998",
        "re_convert" => "3b492e3ebf37ddb92821a21cbd91ef612cef5de041c4138036ffb326d31b0469",
        "string_to_formula" => "0ac41f9491e94ec2cb218c69eee159c496924f6257e0204d9fead2aaf0a9bb89",
        "conversion" => "d0e734f58a5d086b5aa887c83f2dd03f2717cd2100c189d945fe2d7a22c3a7c1"
      }
      definitions = descendants(Prism.parse(@source).value).select { |node| node.is_a?(Prism::DefNode) }
      expected.each do |name, hash|
        node = definitions.find { |definition| definition.name.to_s == name }
        raise Unsupported, "integration helper changed: #{name}" unless node && Digest::SHA256.hexdigest(node.location.slice) == hash
      end
      unless @source.include?('SUPPORTED_LANGUAGES = %i[omml latex mathml asciimath].freeze')
        raise Unsupported, "integration format matrix changed"
      end
    end

    def statements(node)
      node.block&.body&.body || []
    end

    def resolve(node, bindings)
      name = if node.is_a?(Prism::LocalVariableReadNode)
               node.name.to_s
             elsif node.is_a?(Prism::CallNode) && node.receiver.nil? && arguments(node).empty? && !node.block
               node.name.to_s
             end
      value = name && bindings[name]
      value && !value.is_a?(Hash) ? resolve(value, bindings.reject { |key, _| key == name }) : node
    end

    def resolve_memo_boundary(node, bindings)
      ids = []
      seen = []
      loop do
        name = if node.is_a?(Prism::LocalVariableReadNode)
                 node.name.to_s
               elsif node.is_a?(Prism::CallNode) && node.receiver.nil? && arguments(node).empty? && !node.block
                 node.name.to_s
               end
        expression = name && bindings[name]
        break unless expression && !expression.is_a?(Hash)
        raise Unsupported, "cyclic source binding" if seen.include?(name)

        seen << name
        if node.is_a?(Prism::CallNode) && bindings.fetch("__source_lets__", {})[name]
          ids << "let:#{name}"
        end
        node = expression
      end
      [node, ids.uniq]
    end

    def value(node, bindings)
      node = resolve(node, bindings)
      if node.is_a?(Prism::InterpolatedStringNode)
        return node.parts.map do |part|
          if part.is_a?(Prism::StringNode)
            part.unescaped
          elsif part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.length == 1
            entry = value(part.statements.body.first, bindings)
            raise Unsupported, "nonliteral interpolation" unless [String, Numeric, TrueClass, FalseClass, NilClass].any? { |type| entry.is_a?(type) }

            entry.to_s
          else
            raise Unsupported, "unsupported string interpolation"
          end
        end.join
      end
      return node.elements.map { |element| value(element, bindings) } if node.is_a?(Prism::ArrayNode)
      if node.is_a?(Prism::CallNode) && node.name == :gsub && arguments(node).length == 2 && arguments(node).first.location.slice == '/\\s/' && value(arguments(node).last, bindings) == ""
        return value(node.receiver, bindings).gsub(/\s/, "")
      end
      if node.is_a?(Prism::CallNode) && node.name == :read && node.receiver&.location&.slice == "File"
        args = arguments(node)
        raise Unsupported, "File.read arguments" unless args.length == 1

        path = value(args.first, bindings)
        full_path = File.expand_path(path, @root)
        raise Unsupported, "fixture path outside spec" unless full_path.start_with?("#{@root}/spec/")

        relative = full_path.delete_prefix("#{@root}/")
        text = source_text(relative)
        @dependencies << { "path" => path, "sha256" => Digest::SHA256.hexdigest(text) }
        return text
      end
      recipe = ModelRecipes.unwrap(@decoder.emit_ast(node, bindings: bindings))
      literal_recipe(recipe)
    end

    def literal_recipe(recipe)
      recipe = ModelRecipes.unwrap(recipe)
      case recipe.fetch("kind")
      when "literal", "symbol" then recipe.fetch("value")
      when "array" then recipe.fetch("items").map { |item| literal_recipe(item) }
      when "map"
        recipe.fetch("entries").to_h { |item| [literal_recipe(item.fetch("key")), literal_recipe(item.fetch("value"))] }
      else raise Unsupported, "expected a literal, got #{recipe['kind']}"
      end
    end

    # Finite render-call contract, intentionally separate from the migration CLI.
    def render_expression(node, bindings)
      node, memo_ids = resolve_memo_boundary(node, bindings)
      normalizations = []
      loop do
        if node.is_a?(Prism::CallNode) && node.name == :gsub
          args = arguments(node)
          if args.length == 2 && args.first.location.slice == '/\\s/' && value(args.last, bindings) == ""
            normalizations.unshift("remove_whitespace")
          elsif args.length == 2 && value(args.first, bindings) == "&amp;" && value(args.last, bindings) == "&"
            normalizations.unshift("unescape_ampersand")
          else
            raise Unsupported, "unsupported render normalization"
          end
          node, nested_memo = resolve_memo_boundary(node.receiver, bindings)
          memo_ids.concat(nested_memo)
        elsif node.is_a?(Prism::CallNode) && node.name == :strip && arguments(node).empty?
          normalizations.unshift("strip")
          node, nested_memo = resolve_memo_boundary(node.receiver, bindings)
          memo_ids.concat(nested_memo)
        else
          break
        end
      end
      dump = nil
      if node.is_a?(Prism::CallNode) && node.name == :dump && node.receiver&.location&.slice == "Plurimath.xml_engine"
        dump_args = arguments(node)
        unless dump_args.length == 2 && dump_args.last.is_a?(Prism::KeywordHashNode) && dump_args.last.location.slice.gsub(/\s/, "") == "indent:2,"
          # Prism's keyword-hash slice does not include a trailing comma on all versions.
          raise Unsupported, "unsupported XML dump options" unless dump_args.length == 2 && dump_args.last.location.slice.gsub(/\s/, "") == "indent:2"
        end
        dump = "xml_engine_indent_2"
        node, nested_memo = resolve_memo_boundary(dump_args.first, bindings)
        memo_ids.concat(nested_memo)
      elsif node.is_a?(Prism::CallNode) && node.name == :dump_ox_nodes && node.receiver.nil? && arguments(node).length == 1
        dump = "dump_ox_nodes"
        node, nested_memo = resolve_memo_boundary(arguments(node).first, bindings)
        memo_ids.concat(nested_memo)
      end
      unless node.is_a?(Prism::CallNode) && METHODS.include?(node.name.to_s) && !node.block
        raise Unsupported, "not a supported render call: #{node.location.slice}"
      end
      args = arguments(node).dup
      kwargs = args.last.is_a?(Prism::KeywordHashNode) ? @decoder.emit_ast(args.pop, bindings: bindings) : { "kind" => "map", "entries" => [] }
      receiver, input_memo = resolve_memo_boundary(node.receiver, bindings)
      input = if receiver.is_a?(Prism::CallNode) && receiver.name == :parse && receiver.receiver&.location&.slice == "Plurimath::Math"
                parse_args = arguments(receiver)
                raise Unsupported, "parse requires text and language" unless parse_args.length == 2

                { "kind" => "parse", "text" => value(parse_args.first, bindings),
                  "format" => ModelRecipes.unwrap(@decoder.emit_ast(parse_args.last, bindings: bindings)).fetch("value") }
              else
                { "kind" => "model", "recipe" => @decoder.emit_ast(receiver, bindings: bindings) }
              end
      operation = { "method" => node.name.to_s, "args" => args.map { |arg| @decoder.emit_ast(arg, bindings: bindings) },
                    "kwargs" => kwargs, "normalizations" => normalizations }
      input["memo"] = input_memo unless input_memo.empty?
      operation["memo"] = memo_ids.uniq unless memo_ids.empty?
      operation["dump"] = dump if dump
      [input, operation]
    end

    def assertion(example, bindings)
      body = statements(example)
      locals = bindings.dup
      body[0...-1].each do |statement|
        raise Unsupported, "extra example statement #{statement.class}" unless statement.is_a?(Prism::LocalVariableWriteNode)

        locals[statement.name.to_s] = statement.value
      end
      call = body.last
      unless call.is_a?(Prism::CallNode) && %i[to not_to].include?(call.name) && call.receiver.is_a?(Prism::CallNode) && call.receiver.name == :expect && call.receiver.receiver.nil? && !call.receiver.block
        raise Unsupported, "unsupported assertion"
      end
      matcher = arguments(call).first
      unless matcher.is_a?(Prism::CallNode) && %i[eq eql match be_xml_equivalent_to].include?(matcher.name) && matcher.receiver.nil? && arguments(matcher).length == 1
        raise Unsupported, "unsupported matcher"
      end
      raise Unsupported, "unsupported negative matcher" if call.name == :not_to && !%i[eq eql].include?(matcher.name)
      input, operation = render_expression(arguments(call.receiver).fetch(0), locals)
      expected_node = arguments(matcher).first
      expected_binding = if expected_node.is_a?(Prism::LocalVariableReadNode)
                           expected_node.name.to_s
                         elsif expected_node.is_a?(Prism::CallNode) && expected_node.receiver.nil? && arguments(expected_node).empty?
                           expected_node.name.to_s
                         end
      if expected_binding && JSON.generate(input).include?(%Q{"id":"let:#{expected_binding}"})
        raise Unsupported, "expected input binding must preserve aliasing"
      end
      expected = value(arguments(matcher).first, locals)
      raise Unsupported, "expected render string or literal array" unless expected.is_a?(String) || expected.is_a?(Array)

      { "input" => input, "operation" => operation,
        "comparison" => "#{call.name == :not_to ? 'not_' : ''}#{matcher.name}", "expected" => expected }
    end

    def extract_file(relative)
      @relative = relative
      @source = source_text(relative)
      parsed = Prism.parse(@source)
      raise Unsupported, "cannot parse #{relative}" unless parsed.success?

      ast = parsed.value
      if descendants(ast).any? { |node| node.is_a?(Prism::CallNode) && node.name == :it_behaves_like && arguments(node).first.is_a?(Prism::StringNode) && arguments(node).first.unescaped == "shared renderer fixture" }
        raise Unsupported, "source already migrated; select the pinned original renderer source revision"
      end
      @ast = ast
      @replacements = []
      first_case = @cases.length
      first_ledger = @ledger.length
      ast.statements.body.each do |node|
        next unless node.is_a?(Prism::CallNode) && GROUPS.include?(node.name) && node.block

        class_node = arguments(node).first
        class_name = ModelRecipes.constant_name(class_node).delete_prefix("Plurimath::")
        walk(node, { "described_class" => { "kind" => "class", "name" => class_name } }, [])
      end
      assertions = descendants(ast).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line }
      recorded = @cases[first_case..].flat_map do |row|
        if row["program"]
          row.fetch("program").fetch("assertion_lines")
        else
          [row.fetch("source").fetch("assertion_line")]
        end
      end + @ledger[first_ledger..].flat_map { |row| row.fetch("assertion_lines", []) }
      (assertions - recorded).each do |line|
        @ledger << { "path" => relative, "line" => line, "assertion_lines" => [line],
                     "disposition" => "retained", "reason" => "dynamic or unsupported enclosing group" }
      end
      remove_unused_fixture_requires(ast)
      { "path" => relative, "source_sha256" => Digest::SHA256.hexdigest(@source), "assertion_lines" => assertions,
        "replacements" => @replacements.sort_by { |entry| entry.fetch("start") } }
    end

    def remove_unused_fixture_requires(ast)
      rewritten = @source.dup
      @replacements.sort_by { |entry| entry.fetch("start") }.reverse_each do |entry|
        rewritten = rewritten.byteslice(0...entry.fetch("start")) + entry.fetch("replacement") + rewritten.byteslice(entry.fetch("end")..)
      end
      references = descendants(Prism.parse(rewritten).value).filter_map do |node|
        node.name.to_s if node.is_a?(Prism::ConstantReadNode)
      end
      namespaces = {
        "expected_values" => "ExpectedValues", "line_break_values" => "LineBreakValues",
        "unicode_math_transform_values" => "UnicodeMathTransformValues", "unicode_math_string_values" => "UnicodeMathStringValues"
      }
      ast.statements.body.each do |node|
        next unless node.is_a?(Prism::CallNode) && node.name == :require && arguments(node).first.is_a?(Prism::StringNode)

        file = arguments(node).first.unescaped
        namespace = namespaces[File.basename(file)]
        next unless namespace && file.start_with?("plurimath/fixtures/formula_modules/") && !references.include?(namespace)

        start = node.location.start_offset
        finish = node.location.end_offset
        finish += 1 if @source.byteslice(finish, 1) == "\n"
        @replacements << { "start" => start, "end" => finish, "original" => @source.byteslice(start...finish),
                           "replacement" => "", "case_ids" => [], "cleanup" => "unused fixture require #{namespace}" }
      end
    end

    def walk(group, inherited, labels)
      bindings = inherited.dup
      bindings["__source_lets__"] = inherited.fetch("__source_lets__", {}).dup
      label_node = arguments(group).first
      if label_node.is_a?(Prism::ConstantReadNode) || label_node.is_a?(Prism::ConstantPathNode)
        bindings["described_class"] = { "kind" => "class", "name" => ModelRecipes.constant_name(label_node).delete_prefix("Plurimath::") }
      end
      label = label_node.is_a?(Prism::StringNode) ? label_node.unescaped : label_node.location.slice
      labels = labels + [label]
      body = statements(group)
      body.each do |node|
        next unless node.is_a?(Prism::CallNode) && %i[let subject].include?(node.name)

        name = arguments(node).first
        expression = statements(node)
        next unless name.is_a?(Prism::SymbolNode) && expression.length == 1

        bindings[name.unescaped] = expression.first
        bindings.fetch("__source_lets__")[name.unescaped] = true
      end
      return if special_group(group, label, bindings)

      children = body.select { |node| node.is_a?(Prism::CallNode) && GROUPS.include?(node.name) && node.block }
      examples = body.select { |node| node.is_a?(Prism::CallNode) && EXAMPLES.include?(node.name) && node.block }
      children.each { |child| walk(child, bindings, labels) }
      return if examples.empty?

      unless children.empty?
        examples.each { |example| export_context(example, [example], bindings, labels, require_closed_body: false) }
        return
      end

      export_context(group, examples, bindings, labels, require_closed_body: true)
    end

    def export_context(group, examples, bindings, labels, require_closed_body:)
      begin
        allowed = !require_closed_body || statements(group).all? { |node| node.is_a?(Prism::CallNode) && (%i[let subject] + EXAMPLES).include?(node.name) && node.block }
        raise Unsupported, "extra context statements or hooks" unless allowed
        rows = examples.map do |example|
          begin
            assertion(example, bindings)
          rescue Unsupported, ModelRecipes::Unsupported
            raise Unsupported, "native Ruby contract" if labels.any? { |label| %w[.initialize .== .validate_function_formula].include?(label) }

            ProgramCompiler.new(self, bindings).compile(example)
          end
        end
        ids = rows.each_with_index.map do |row, index|
          family = if @relative.include?("/function/")
                     "function"
                   elsif @relative.include?("/math/formula/")
                     "formula"
                   else
                     "renderer-#{@relative.delete_prefix('spec/plurimath/').delete_suffix('_spec.rb').tr('/', '-')}"
                   end
          id = "#{family}-#{File.basename(@relative, '_spec.rb')}-#{group.location.start_line}-#{index + 1}"
          assertion_line = descendants(examples[index]).find { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.location.start_line
          @cases << { "id" => id, "source" => { "path" => @relative, "line" => examples[index].location.start_line, "assertion_line" => assertion_line },
                      "description" => (labels + [value(arguments(examples[index]).first, bindings)]).join(" / ") }.merge(row)
          id
        end
        replacement = replacement_for(group, ids)
        @replacements << { "start" => group.location.start_offset, "end" => group.location.end_offset,
                           "original" => group.location.slice, "replacement" => replacement, "case_ids" => ids }
        @ledger << { "path" => @relative, "line" => group.location.start_line, "disposition" => "shared", "case_ids" => ids, "labels" => labels }
      rescue Unsupported, ModelRecipes::Unsupported => error
        if require_closed_body && examples.length > 1
          examples.each { |example| export_context(example, [example], bindings, labels, require_closed_body: false) }
          return
        end
        code = examples.map { |example| example.location.slice }.join("\n")
        reason = if @relative.include?("/symbols/paren/") && labels.include?(".open?, .close?, .opening")
                   "native Ruby delimiter predicate and counterpart class contract"
                 elsif @relative.match?(%r{/(?:mathml|omml)/utility_spec\.rb$}) && !labels.include?("parser integration")
                   "native Ruby internal XML token/helper contract"
                 elsif @relative == "spec/plurimath/omml/translator_spec.rb" && labels.include?("#omml_to_plurimath")
                   "native Ruby typed-node and registration protocol"
                 elsif labels.any? { |label| label.include?("formatter receives formula and number node") } || code.include?("formatter: spy")
                   "native Ruby formatter callback and node identity protocol"
                 elsif error.message.include?("FormulaSpecFormatters::") || labels.any? { |label| label.include?("year formatter") } || code.include?("Class.new(Plurimath::NumberFormatter)")
                   "native Ruby formatter subclass and extension protocol"
                 elsif labels.include?(".type_error!")
                   "native Ruby exception-class contract for an invalid renderer type"
                 elsif code.include?("expect(expected_value.value)") || (code.include?("unicode.text") && code.include?("described_class.new"))
                   "native Ruby constructor storage getter contract"
                 elsif labels.include?(".initialize") || examples.all? { |example| example.location.slice.match?(/be_a\(described_class\)|\.parameter_(?:one|two|three)/) }
                   "native Ruby initialization and accessor contract"
                 elsif labels.include?(".validate_function_formula")
                   "native Ruby internal validation helper contract"
                 elsif labels.include?(".==")
                   "native Ruby object equality contract"
                 else
                   error.message
                 end
        @ledger << { "path" => @relative, "line" => group.location.start_line,
                     "disposition" => "retained", "reason" => reason, "labels" => labels,
                     "assertion_lines" => examples.flat_map { |example| descendants(example).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line } } }
      end
    end

    def descendants(node)
      [node] + node.compact_child_nodes.flat_map { |child| descendants(child) }
    end

    def replacement_for(group, ids)
      comments = group.location.slice.lines.filter_map { |line| line.strip if line.match?(/^\s*#/) }
      (comments + ids.map { |id| "it_behaves_like \"shared renderer fixture\", #{id.inspect}" }).join("\n#{' ' * group.location.start_column}")
    end

    # These loops/projections have a closed, source-pinned expansion. A source
    # change fails loudly instead of silently exporting a subset of assertions.
    def special_group(group, label, bindings)
      if @relative == "spec/plurimath/omml/translator_spec.rb"
        return true if translator_family(group, label, bindings)
      end
      if (family = additional_family(group, label, bindings))
        rows, replacement = family
        record_family(group, rows, replacement)
        return true
      end
      signatures = {
        ["unicodemath_spec.rb", ".to_unicodemath"] => "3b083decb4a21dc336b58939821d3c5d86233b857a5da64d27bf2a66fc042aa4",
        ["intent_encoding_spec.rb", "unicodemath examples"] => "f17fbe6e14d1646620b87f04574a8c0de54a24348d20d0aca3fbf2933bb6efce",
        ["unitsml_spec.rb", "contains a composed unit whose spacers must stay operators"] => "895b84a5b0b0a24828783f96d93f0f09f5289cef972483256a0f7124c75c14aa"
      }
      if @relative.include?("/function/")
        signatures.merge!({
          ["overset_spec.rb", "OMML operand order"] => "2158e47f62089cbc3698943698240f5eb268494c862f89810f96b337bfcb6208",
          ["underset_spec.rb", "OMML operand order"] => "ec7d62b4cd026af8e4e3d37eb5e346e8dcce3e332c69b266bfcbe8aaf08f683f",
          ["cancel_spec.rb", ".to_omml_without_math_tag"] => "ea3e36a30502c525ec68cce376614e1d1d6222b58ef8c777ebab9dd2b19de8fc"
        })
      end
      expected_hash = signatures[[File.basename(@relative), label]]
      return false unless expected_hash
      raise Unsupported, "dynamic/projection source changed: #{@relative}:#{group.location.start_line}" unless Digest::SHA256.hexdigest(group.location.slice) == expected_hash

      assertion_lines = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line }
      return cancel_group(group, bindings, assertion_lines) if @relative.end_with?("/function/cancel_spec.rb")

      rows = case File.basename(@relative)
             when "unicodemath_spec.rb" then unicode_rows(assertion_lines.fetch(0))
             when "intent_encoding_spec.rb" then intent_rows(assertion_lines.fetch(0))
             when "unitsml_spec.rb" then spacer_rows(assertion_lines, bindings)
             when "overset_spec.rb", "underset_spec.rb" then operand_rows(group, assertion_lines, bindings)
             end
      @cases.concat(rows)
      ids = rows.map { |row| row.fetch("id") }
      replacement = replacement_for(group, ids)
      @replacements << { "start" => group.location.start_offset, "end" => group.location.end_offset,
                         "original" => group.location.slice, "replacement" => replacement, "case_ids" => ids }
      @ledger << { "path" => @relative, "line" => group.location.start_line, "disposition" => "shared",
                   "case_ids" => ids, "assertion_lines" => assertion_lines, "expansion" => "source-pinned finite recipe" }
      true
    end

    # Only the pinned translator tables and shared examples are expanded here.
    # Typed-node dispatch/registration tests remain native Ruby contracts.
    def translator_family(group, label, bindings)
      case label
      when "#omml_to_plurimath", "Plurimath::Omml#to_formula"
        loop_node = statements(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :each }
        signature = label == "#omml_to_plurimath" ? "4bb1104156ee3b80fbb6023dc42c70a9dfbf6adf31ffcead4375e0e7450c70bd" : "80229f3f67d9cfc8d01aae48fceafc48daae3448621596d7bb7b80b8635b2c64"
        verify_family!(loop_node, signature)
        rows = []
        context = statements(loop_node).fetch(0)
        if label == "#omml_to_plurimath"
          value(loop_node.receiver, {}).each do |tag, function|
            local = collect_bindings(context, bindings.merge("tag" => literal(tag), "function" => enum(function)))
            # This exact const_get dispatch is a two-entry authored class table,
            # not a dynamic class lookup allowed by the portable recipe format.
            expression = local.fetch("expected_value").location.slice.sub("Plurimath::Math::Function.const_get(function)", "Plurimath::Math::Function::#{function}")
            local["expected_value"] = Prism.parse(expression).value.statements.body.fetch(0)
            example = statements(context).find { |node| node.is_a?(Prism::CallNode) && node.name == :it }
            nested = statements(context).find { |node| node.is_a?(Prism::CallNode) && node.name == :context }
            [[example, local, "text"], [statements(nested).find { |node| node.is_a?(Prism::CallNode) && node.name == :it }, collect_bindings(nested, local), "operator"]].each do |test, scope, kind|
              program = ProgramCompiler.new(self, scope).compile(test).fetch("program")
              rows << program_row("renderer-translator-operand-#{tag}-#{kind}", test.location.start_line, "imports #{tag} script/base with #{kind} label", program)
            end
          end
        else
          loop_node.receiver.elements.each do |entry|
            fixture_id = value(entry.key, {})
            local = collect_bindings(context, bindings.merge("fixture_id" => literal(fixture_id), "expected_formula" => @decoder.emit_ast(entry.value, bindings: bindings)))
            example = statements(context).find { |node| node.is_a?(Prism::CallNode) && node.name == :it }
            program = ProgramCompiler.new(self, local).compile(example).fetch("program")
            rows << program_row("renderer-translator-fixture-#{fixture_id}", example.location.start_line, "parses ##{fixture_id}.omml through the public typed-model facade", program)
          end
        end
        record_family(loop_node, rows)
        false
      when "when the omml context has not been populated yet"
        verify_family!(group, "ac6d5cc9d32e519c69f79f5b31bc07c9929d0449492b68d51a18114fdaef1ccc")
        example = statements(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :it }
        body = statements(example)
        assertion = body.fetch(2)
        pipeline = Pipeline.new
        input = pipeline.build(literal(value(arguments(arguments(assertion.receiver).first.receiver).first, bindings)))
        actual = pipeline.decode(input, "omml")
        expected = pipeline.build(@decoder.emit_ast(arguments(arguments(assertion).first).first, bindings: bindings))
        pipeline.check(actual, nil, assertion.receiver.location.start_line, expected_slot: expected)
        row = program_row("renderer-translator-reset-context", example.location.start_line, "populates the OMML context before parsing", pipeline)
        # The original require/reset statements stay in Ruby and execute before
        # every original engine invocation of this shared example.
        replacement = "context #{label.inspect} do\n      before do\n        #{body.fetch(0).location.slice}\n        #{body.fetch(1).location.slice}\n      end\n      #{replacement_for(group, [row.fetch('id')])}\n    end"
        record_family(group, [row], replacement)
        true
      when "when an m:r carries WordprocessingML run inner content"
        verify_family!(group, "e4cb00f65bd28b5d42fe85efd058e68a06b255839f1a6391250aa541eb5d6edf")
        declaration = statements(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :shared_examples }
        shared = statements(declaration).fetch(0)
        rows = []
        statements(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :context }.each_with_index do |context, index|
          local = collect_bindings(context, bindings)
          statements(context).each do |node|
            next unless node.is_a?(Prism::CallNode) && %i[include_examples it].include?(node.name)

            example = node.name == :include_examples ? shared : node
            program = ProgramCompiler.new(self, local).compile(example).fetch("program")
            kind = node.name == :include_examples ? "acceptance" : "output"
            rows << program_row("renderer-translator-word-content-#{index + 1}-#{kind}", example.location.start_line, "#{value(arguments(context).first, {})}: #{kind}", program)
          end
        end
        record_family(group, rows)
        true
      else false
      end
    end

    def collect_bindings(group, inherited)
      scope = inherited.merge("__source_lets__" => inherited.fetch("__source_lets__", {}).dup)
      statements(group).each_with_object(scope) do |node, local|
        next unless node.is_a?(Prism::CallNode) && node.name == :let && statements(node).length == 1

        local[arguments(node).first.unescaped] = statements(node).first
        local.fetch("__source_lets__")[arguments(node).first.unescaped] = true
      end
    end

    def verify_family!(node, signature)
      raise Unsupported, "closed source family changed: #{@relative}" unless node && Digest::SHA256.hexdigest(node.location.slice) == signature
    end

    def record_family(group, rows, replacement = nil)
      @cases.concat(rows)
      ids = rows.map { |row| row.fetch("id") }
      @replacements << { "start" => group.location.start_offset, "end" => group.location.end_offset,
                         "original" => group.location.slice, "replacement" => replacement || replacement_for(group, ids), "case_ids" => ids }
      lines = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line }
      @ledger << { "path" => @relative, "line" => group.location.start_line, "disposition" => "shared",
                   "case_ids" => ids, "assertion_lines" => lines, "expansion" => "source-pinned finite mathematical sequence" }
    end

    def program_row(id, line, description, pipeline)
      { "id" => id, "source" => { "path" => @relative, "line" => line, "assertion_line" => line },
        "description" => description, "program" => pipeline.is_a?(Pipeline) ? pipeline.finish : pipeline }
    end

    def literal(value)
      { "kind" => "literal", "value" => value }
    end

    def enum(value)
      { "kind" => "symbol", "value" => value }
    end

    def additional_family(group, label, bindings)
      signatures = {
        ["spec/plurimath/math_zone_spec.rb", "Overset display labels after OMML import"] => "245b1d2d07145a7a6be50f8f155e895be8daf7d6127d55e3307abb1384a67f98",
        ["spec/plurimath/mathml_spec.rb", "large-operator symbol round trips"] => "af57488e2070f17b3fb4981c4f4cc50909facaad4c574036c8824868aeb9e378",
        ["spec/plurimath/mathml_spec.rb", "unrecognised operator with rspace round trip"] => "cf009de7e764da99118d9646eee6d5c689b440ddb8a19341ab4c7a077abec4df",
        ["spec/plurimath/mathml_spec.rb", "MathML round-tripping"] => "3ba2bb70e81fd027c840f4faa4f54ff1efa0359a76594f9e8f9f0d447d42c4f4",
        ["spec/plurimath/omml_spec.rb", "Plurimath::Math::Formula"] => "c33ef1e0859a7c142576a76880e1f7bae105f340b28ccaa2a5ab38971d22bb75"
      }
      signature = signatures[[@relative, label]]
      return unless signature
      raise Unsupported, "closed mathematical family changed: #{@relative}:#{group.location.start_line}" unless Digest::SHA256.hexdigest(group.location.slice) == signature

      case label
      when "Overset display labels after OMML import" then [display_label_rows(group, bindings), nil]
      when "large-operator symbol round trips" then [large_operator_rows(group, bindings), nil]
      when "unrecognised operator with rspace round trip" then [spaced_operator_rows(group), nil]
      when "MathML round-tripping" then pretty_roundtrip_rows(group)
      when "Plurimath::Math::Formula" then [omml_operand_rows(group, bindings), nil]
      end
    end

    def display_label_rows(group, bindings)
      table = descendants(group).find { |node| node.is_a?(Prism::HashNode) }
      assertion = descendants(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :to && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect }
      assertion_line = assertion.location.start_line
      value(table, {}).map do |format, (script, base)|
        pipeline = Pipeline.new
        input = pipeline.build(@decoder.emit_ast(bindings.fetch("exp"), bindings: bindings))
        model = pipeline.decode(input, "omml", boundary: "math_parse", format_argument: enum("omml"))
        pipeline.steps.last["memo"] = { "ids" => ["let:formula"], "dependencies" => [input] }
        output = pipeline.render(model, "to_display", args: [enum(format)])
        labels = pipeline.observe(output, "display_tail_labels")
        expected = value(arguments(arguments(assertion).first).first, { "script" => literal(script), "base" => literal(base) })
        pipeline.check(labels, expected, assertion_line)
        program_row("renderer-display-label-#{format}", assertion_line, "labels imported OMML script and base in #{format}", pipeline)
      end
    end

    def large_operator_rows(group, bindings)
      table = descendants(group).find { |node| node.is_a?(Prism::HashNode) }
      assertions = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }
      comparisons = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :to && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect }
      rows = value(table, {}).map do |name, glyph|
        pipeline = Pipeline.new
        input = pipeline.build(literal("<math><mo>#{glyph}</mo></math>"))
        model = pipeline.decode(input, "mathml")
        output = pipeline.render(model, "to_mathml")
        tokens = pipeline.observe(output, "mathml_token_pairs", { "scope" => "all" })
        expected = value(arguments(arguments(comparisons.first).first).first, { "glyph" => literal(glyph) })
        pipeline.check(tokens, expected, assertions.first.location.start_line)
        program_row("renderer-large-operator-#{name}", assertions.first.location.start_line, "preserves #{name} as a MathML operator", pipeline)
      end
      nary = descendants(group).find { |node| node.is_a?(Prism::LocalVariableWriteNode) && node.name == :nary }
      # The pinned source binds symbols to this exact namespace. Resolve that
      # static alias before decoding; no namespace/class lookup comes from YAML.
      source = nary.value.location.slice.gsub(/\bsymbols::/, "Plurimath::Math::Symbols::")
      pipeline = Pipeline.new
      model = pipeline.build(@decoder.emit_ast(Prism.parse(source).value.statements.body.first))
      output = pipeline.render(model, "to_mathml_without_math_tag", args: [literal(false)], kwargs: @decoder.emit_ast(Prism.parse('{ options: {} }').value.statements.body.first))
      dumped = pipeline.emit("transform", "source" => output, "normalization" => "dump_ox_nodes")
      children = pipeline.observe(dumped, "mathml_token_pairs", { "scope" => "munderover_children" })
      expected = value(arguments(arguments(comparisons.last).first).first, {})
      pipeline.check(children, expected, assertions.last.location.start_line)
      rows << program_row("renderer-nary-limit-order", assertions.last.location.start_line, "keeps a Nary operator before its lower and upper limits", pipeline)
      rows
    end

    def spaced_operator_rows(group)
      context = statements(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :context }
      source = statements(context).find { |node| node.is_a?(Prism::CallNode) && node.name == :let }
      input = value(statements(source).first, {})
      statements(context).select { |node| node.is_a?(Prism::CallNode) && node.name == :it }.each_with_index.map do |example, index|
        assertion = statements(example).fetch(0)
        expected = value(arguments(arguments(assertion).first).first, {})
        pipeline = Pipeline.new
        model = pipeline.decode(pipeline.build(literal(input)), "mathml")
        output = pipeline.render(model, "to_mathml")
        dependencies = pipeline.steps.filter_map { |step| step["save"] unless step["save"] == output }
        pipeline.steps.last["memo"] = { "ids" => ["let:token"], "dependencies" => dependencies }
        property = pipeline.observe(output, "spaced_token_property", { "field" => %w[name rspace text].fetch(index) })
        pipeline.check(property, expected, assertion.location.start_line)
        program_row("renderer-spaced-operator-#{index + 1}", assertion.location.start_line, arguments(example).first.unescaped, pipeline)
      end
    end

    def pretty_roundtrip_rows(group)
      declarations = statements(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :shared_examples }
      operand, suite = declarations
      original_assertions = descendants(operand).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line }
      rows = []
      edits = [[operand.location.start_offset, operand.location.end_offset, ""]]
      statements(suite).select { |node| node.is_a?(Prism::CallNode) && node.name == :context }.each do |context|
        body = statements(context)
        label = arguments(context).first.unescaped
        pipeline = Pipeline.new
        if label == "contains generated AsciiMath expressions"
          example = body.find { |node| node.is_a?(Prism::CallNode) && node.name == :it }
          expressions = descendants(example).find { |node| node.is_a?(Prism::LocalVariableWriteNode) && node.name == :expressions }
          line = descendants(example).find { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.location.start_line
          value(expressions.value, {}).each do |expression|
            input = pipeline.build(literal(expression))
            model = pipeline.decode(input, "asciimath", boundary: "math_parse", format_argument: literal("asciimath"))
            output = pipeline.render(model, "to_mathml")
            reparsed = pipeline.decode(output, "mathml", boundary: "math_parse", format_argument: literal("mathml"))
            final = pipeline.render(reparsed, "to_mathml")
            pipeline.check(final, nil, line, comparison: "be_xml_equivalent_to", expected_slot: output)
          end
          program = pipeline.finish(aggregate_failures: true)
        else
          local = {}
          body.each do |node|
            local[arguments(node).first.unescaped] = statements(node).first if node.is_a?(Prism::CallNode) && node.name == :let
          end
          input = pipeline.build(literal(value(local.fetch("string"), local)))
          model = pipeline.decode(input, "mathml")
          pipeline.steps.last["memo"] = { "ids" => ["let:formula"], "dependencies" => [input] }
          output = pipeline.render(model, "to_asciimath")
          expected = value(local.fetch("asciimath"), local)
          pipeline.check(output, expected, original_assertions.first)
          unless local["round_trip"] && value(local.fetch("round_trip"), local) == false
            mathml = pipeline.render(model, "to_mathml")
            reparsed = pipeline.decode(mathml, "mathml")
            final = pipeline.render(reparsed, "to_asciimath")
            pipeline.check(final, expected, original_assertions.last)
          end
          line = original_assertions.first
          program = pipeline.finish
        end
        id = "renderer-pretty-mathml-#{context.location.start_line}"
        rows << program_row(id, line, label, program)
        edits << [context.location.start_offset, context.location.end_offset, "it_behaves_like \"shared renderer fixture\", #{id.inspect}"]
      end
      unused_round_trip = statements(suite).find { |node| node.is_a?(Prism::CallNode) && node.name == :let }
      edits << [unused_round_trip.location.start_offset, unused_round_trip.location.end_offset, ""]
      text = group.location.slice
      edits.sort_by(&:first).reverse_each do |start, finish, replacement|
        start -= group.location.start_offset
        finish -= group.location.start_offset
        text = text.byteslice(0...start) + replacement + text.byteslice(finish..)
      end
      [rows, text.gsub(/^[ \t]+$/, "")]
    end

    def omml_operand_rows(group, bindings)
      table = statements(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :each }.receiver
      lines = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.map { |node| node.location.start_line }
      first_comparisons = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :to && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :expect }.first(2)
      rows = value(table, {}).map do |function, script|
        function_recipe = { "kind" => "constructor", "class" => "Math::Function::#{function}", "args" => [@decoder.emit_ast(Prism.parse('base').value.statements.body.first, bindings: bindings)], "kwargs" => empty_kwargs }
        model_recipe = { "kind" => "constructor", "class" => "Math::Formula", "args" => [{ "kind" => "array", "items" => [function_recipe] }], "kwargs" => empty_kwargs }
        pipeline = Pipeline.new
        output = pipeline.render(pipeline.build(model_recipe), "to_omml")
        %w[accent_base accent_script].each_with_index do |field, index|
          expected = value(arguments(arguments(first_comparisons.fetch(index)).first).first, bindings.merge("script" => literal(script)))
          actual = pipeline.observe(output, "omml_operand_text", { "field" => field })
          pipeline.check(actual, expected, lines.fetch(index))
        end
        program_row("renderer-omml-operand-#{function.downcase}", lines.first, "keeps the expression as the base for #{function}", pipeline)
      end
      examples = statements(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :it }
      examples.each_with_index do |example, index|
        pipeline = Pipeline.new
        if index < 2
          assignment = statements(example).first
          model = pipeline.build(@decoder.emit_ast(assignment.value, bindings: bindings))
          output = pipeline.render(model, "to_omml")
          assertions = statements(example).select { |node| node.is_a?(Prism::CallNode) && node.name == :to }
          assertions.each_with_index do |assertion, field_index|
            actual = pipeline.observe(output, "omml_operand_text", { "field" => %w[lower upper base].fetch(field_index) })
            expected = value(arguments(arguments(assertion).first).first, bindings)
            pipeline.check(actual, expected, assertion.location.start_line)
          end
        else
          constant = descendants(example).find { |node| node.is_a?(Prism::ConstantPathNode) && node.location.slice == "LineBreakValues::LineBreak_019" }
          model = pipeline.build(@decoder.emit_ast(constant, bindings: bindings))
          kwargs = @decoder.emit_ast(Prism.parse('{ split_on_linebreak: true }').value.statements.body.first)
          output = pipeline.render(model, "to_omml", kwargs: kwargs)
          actual = pipeline.observe(output, "omml_operand_text", { "field" => "split_hat_bases" })
          assertion = statements(example).last
          expected = value(arguments(arguments(assertion).first).first, bindings)
          pipeline.check(actual, expected, assertion.location.start_line)
        end
        line = descendants(example).find { |node| node.is_a?(Prism::CallNode) && node.name == :expect }.location.start_line
        rows << program_row("renderer-omml-compound-#{index + 1}", line, arguments(example).first.unescaped, pipeline)
      end
      rows
    end

    def empty_kwargs
      { "kind" => "map", "entries" => [] }
    end

    def row_for(id, line, input, operation, comparison, expected, description)
      { "id" => id, "source" => { "path" => @relative, "line" => line, "assertion_line" => line },
        "description" => description, "input" => input, "operation" => operation,
        "comparison" => comparison, "expected" => expected }
    end

    def correlated(rows, id, description)
      first = rows.first
      operation = first.fetch("operation").reject { |key, _| key == "observation" }
      unless rows.all? { |row| row.fetch("input") == first.fetch("input") && row.fetch("operation").reject { |key, _| key == "observation" } == operation }
        raise Unsupported, "correlated assertions must share one render operation"
      end
      first.merge("id" => id, "description" => description, "operation" => operation,
                  "comparison" => "observations", "expected" => nil,
                  "observations" => rows.map do |row|
                    { "observation" => row.fetch("operation").fetch("observation"),
                      "comparison" => row.fetch("comparison"), "expected" => row.fetch("expected"),
                      "assertion_line" => row.fetch("source").fetch("assertion_line") }
                  end)
    end

    def operand_rows(group, lines, bindings)
      model = @decoder.emit_ast(bindings.fetch("formula"), bindings: bindings)
      input = { "kind" => "model", "recipe" => model, "memo" => ["let:formula"] }
      assertions = descendants(group).select { |node| node.is_a?(Prism::CallNode) && node.name == :expect }
      output_assertions = assertions.first(2)
      kind = File.basename(@relative, "_spec.rb")
      rows = [true, false].map do |display|
        kwargs = { "kind" => "map", "entries" => [{ "key" => { "kind" => "symbol", "value" => "display_style" }, "value" => { "kind" => "literal", "value" => display } }] }
        observations = output_assertions.each_with_index.map do |assertion, index|
          # The expected field text is authored in the source, not rendered.
          enclosing = descendants(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :to && node.receiver == assertion }
          expected = value(arguments(arguments(enclosing).first).first, bindings)
          observation = "#{kind}_#{display ? 'display' : 'inline'}_#{index.zero? ? 'base' : 'script'}"
          row_for("function-#{observation}", assertion.location.start_line, input,
                  { "method" => "to_omml", "args" => [], "kwargs" => kwargs, "normalizations" => [], "observation" => observation },
                  "eq", expected, "#{kind} OMML #{display ? 'display' : 'inline'} #{index.zero? ? 'base' : 'script'}")
        end
        correlated(observations, "function-#{kind}-#{display ? 'display' : 'inline'}", "#{kind} OMML #{display ? 'display' : 'inline'} operand fields")
      end
      rows << row_for("function-#{kind}-omml-roundtrip", lines.last, input,
                      { "method" => "to_omml", "args" => [], "kwargs" => empty_kwargs, "normalizations" => [], "roundtrip" => "omml" },
                      "roundtrip_model_eq", nil, "#{kind} preserves the model through display OMML export and import")
      rows
    end

    def cancel_group(group, inherited, all_lines)
      body = statements(group)
      shared = body.find { |node| node.is_a?(Prism::CallNode) && node.name == :shared_examples }
      shared_it = statements(shared).fetch(0)
      comparisons = statements(shared_it).select { |node| node.is_a?(Prism::CallNode) && %i[to not_to].include?(node.name) }
      raise Unsupported, "unexpected cancellation assertion shape" unless comparisons.length == 7

      identity = comparisons.last
      native = "shared_examples \"a diagonal cancellation\" do\n      it \"preserves its argument identity after rendering\" do\n        document\n        #{identity.location.slice}\n      end\n    end"
      edits = [[shared.location.start_offset, shared.location.end_offset, native]]
      render_call = descendants(group).find { |node| node.is_a?(Prism::CallNode) && node.name == :to_omml_without_math_tag }
      rows = []
      body.select { |node| node.is_a?(Prism::CallNode) && node.name == :context }.each_with_index do |context, context_index|
        bindings = inherited.dup
        statements(context).each do |node|
          if node.is_a?(Prism::CallNode) && node.name == :let && statements(node).length == 1
            bindings[arguments(node).first.unescaped] = statements(node).first
          end
        end
        context_label = arguments(context).first.unescaped
        input, operation = render_expression(render_call, bindings)
        statements(context).each do |node|
          if node.is_a?(Prism::CallNode) && node.name == :it_behaves_like
            observation_names = %w[cancellation_box cancellation_root_child_count cancellation_child_names cancellation_property_names cancellation_property_values cancellation_content_text]
            observations = comparisons.first(6).each_with_index.map do |comparison, index|
              expected = index.zero? ? nil : value(arguments(arguments(comparison).first).first, bindings)
              id = "function-cancel-#{context_index + 1}-#{index + 1}"
              row_for(id, comparison.receiver.location.start_line, input,
                              operation.merge("dump" => "dump_ox_nodes", "observation" => observation_names[index], "memo" => ["let:document"]),
                              index.zero? ? "not_be_nil" : "eq", expected, "cancellation #{context_label}: #{observation_names[index]}")
            end
            id = "function-cancel-#{context_index + 1}"
            rows << correlated(observations, id, "diagonal cancellation #{context_label}")
            replacement = [node.location.slice, "it_behaves_like \"shared renderer fixture\", #{id.inspect}"].join("\n#{' ' * node.location.start_column}")
            edits << [node.location.start_offset, node.location.end_offset, replacement]
          elsif node.is_a?(Prism::CallNode) && EXAMPLES.include?(node.name)
            assertions = statements(node)
            if assertions.length == 1
              row = assertion(node, bindings)
              id = "function-cancel-empty-#{context_index + 1}"
              rows << row_for(id, assertions.first.receiver.location.start_line, row.fetch("input"), row.fetch("operation"), row.fetch("comparison"), row.fetch("expected"), context_label)
              replacement = "it_behaves_like \"shared renderer fixture\", #{id.inspect}"
            else
              raise Unsupported, "unexpected nested cancellation shape" unless assertions.length == 2

              observations = assertions.each_with_index.map do |comparison, index|
                id = "function-cancel-nested-#{index + 1}"
                expected = value(arguments(arguments(comparison).first).first, bindings)
                observation = index.zero? ? "cancellation_nested_box_count" : "cancellation_strike_count"
                row_for(id, comparison.receiver.location.start_line, input,
                                operation.merge("dump" => "dump_ox_nodes", "observation" => observation, "memo" => ["let:document"]), "eq", expected, observation)
              end
              id = "function-cancel-nested"
              rows << correlated(observations, id, "nested cancellation structure and strike counts")
              replacement = "it_behaves_like \"shared renderer fixture\", #{id.inspect}"
            end
            edits << [node.location.start_offset, node.location.end_offset, replacement]
          end
        end
      end
      text = group.location.slice
      edits.sort_by(&:first).reverse_each do |start, finish, replacement|
        start -= group.location.start_offset
        finish -= group.location.start_offset
        text = text.byteslice(0...start) + replacement + text.byteslice(finish..)
      end
      @cases.concat(rows)
      ids = rows.map { |row| row.fetch("id") }
      @replacements << { "start" => group.location.start_offset, "end" => group.location.end_offset,
                         "original" => group.location.slice, "replacement" => text, "case_ids" => ids }
      native_line = identity.receiver.location.start_line
      @ledger << { "path" => @relative, "line" => group.location.start_line, "disposition" => "shared", "case_ids" => ids,
                   "assertion_lines" => all_lines - [native_line], "expansion" => "source-pinned cancellation fragment projections" }
      @ledger << { "path" => @relative, "line" => native_line, "assertion_lines" => [native_line],
                   "disposition" => "retained", "reason" => "Ruby object identity contract; portable output assertions extracted" }
      true
    end

    def unicode_rows(line)
      names = descendants(source_ast("spec/plurimath/fixtures/formula_modules/unicode_math_transform_values.rb")).select { |node| node.is_a?(Prism::ConstantWriteNode) }.map { |node| node.name.to_s }
      raise Unsupported, "unexpected Unicode constant names" unless names.all? { |name| /\AEXAMPLE_\d+\z/.match?(name) }

      names.sort_by { |name| name.delete_prefix("EXAMPLE_").to_i }.each_with_index.each_with_object([]) do |(name, index), rows|
        expression = @constants.resolve("UnicodeMathTransformValues::#{name}")
        # The native loop breaks at its first falsy model; preserve that bound.
        break rows if expression.is_a?(Prism::NilNode) || expression.is_a?(Prism::FalseNode)

        expected = value(@constants.resolve("UnicodeMathStringValues::#{name}"), {})
        rows << { "id" => "formula-unicodemath-#{index + 1}",
          "source" => { "path" => @relative, "line" => line, "assertion_line" => line, "constant" => name },
          "description" => "converts formula to Unicodemath string ##{index + 1}",
          "input" => { "kind" => "model", "recipe" => @decoder.emit_ast(expression), "memo" => ["let:formula"] },
          "operation" => { "method" => "to_unicodemath", "args" => [], "kwargs" => empty_kwargs, "normalizations" => [], "memo" => ["let:string"] },
          "comparison" => "eq", "expected" => expected }
      end
    end

    def intent_rows(line)
      projection = descendants(Prism.parse(@source).value).find { |node| node.is_a?(Prism::DefNode) && node.name == :unicodemath_examples_intents }
      unless projection && Digest::SHA256.hexdigest(projection.location.slice) == "a435184ddf384b8e4133d6a5a11d069177114be31fc3ca20fc9f0a5c25cd00af"
        raise Unsupported, "intent normalization helper changed"
      end
      helper_text = source_text("spec/spec_helper.rb")
      preprocessing = descendants(source_ast("spec/spec_helper.rb")).find { |node| node.is_a?(Prism::DefNode) && node.name == :remove_prefix }
      unless preprocessing && Digest::SHA256.hexdigest(preprocessing.location.slice) == "636794f7119e0bcbdbf0de4da16ccd41531e5cfb589d7ab6046c3b441c58d249"
        raise Unsupported, "Unicode prefix preprocessing helper changed"
      end
      @dependencies << { "path" => "spec/spec_helper.rb", "sha256" => Digest::SHA256.hexdigest(helper_text) }
      path = ENV.fetch("RENDERER_UNICODE_SOURCE", File.join(@root, "submodules/unicodemath-tests/unicodemath_tests.yaml"))
      @dependencies << { "path" => "submodules/unicodemath-tests/unicodemath_tests.yaml", "sha256" => Digest::SHA256.file(path).hexdigest }
      examples = YAML.safe_load(File.read(path, encoding: "UTF-8"), permitted_classes: [Time]).fetch("tests")
      examples.select { |row| row.fetch("mathml").include?('intent="') }.each_with_index.filter_map do |row, index|
        next if index + 1 == 16

        text = row.fetch("unicodemath").to_s.dup
        text.delete_prefix!("1") || text.delete_prefix!("0")
        expected = row.fetch("mathml").scan(/intent="([^"]+)"/).sort.join
        INTENT_REPLACEMENTS.each { |from, to| expected = expected.gsub(from, to) }
        { "id" => "formula-intent-unicode-#{index + 1}",
          "source" => { "path" => @relative, "line" => line, "assertion_line" => line, "upstream_index" => index + 1 },
          "description" => "processing unicode example(#{index + 1})",
          "input" => { "kind" => "parse", "text" => text, "format" => "unicode", "memo" => ["let:formula"] },
          "operation" => { "method" => "to_mathml", "args" => [],
                           "kwargs" => { "kind" => "map", "entries" => [{ "key" => { "kind" => "symbol", "value" => "intent" }, "value" => { "kind" => "literal", "value" => true } }] },
                           "normalizations" => [], "observation" => "normalized_intents", "memo" => ["let:mathml"] },
          "comparison" => "eql", "expected" => expected }
      end
    end

    def spacer_rows(lines, bindings)
      input, operation = render_expression(Prism.parse("mathml").value.statements.body.first, bindings)
      rows = [
        ["identifiers", "unitsml_presentation_spaced_identifiers", "be_empty", [], lines.fetch(0)],
        ["count", "unitsml_presentation_spacer_count", "eq", 3, lines.fetch(1)],
        ["text", "unitsml_presentation_spacer_unique_text", "eq", ["⁢"], lines.fetch(2)]
      ].map do |name, observation, comparator, expected, line|
        { "id" => "formula-unitsml-spacers-#{name}",
          "source" => { "path" => @relative, "line" => line, "assertion_line" => line },
          "description" => "composed unit presentation spacer #{name} (plurimath/plurimath#476)",
          "input" => input,
          "operation" => operation.merge("observation" => observation),
          "comparison" => comparator, "expected" => expected }
      end
      [rows.first, correlated(rows.drop(1), "formula-unitsml-spacers-count", "composed unit presentation spacer count and text (plurimath/plurimath#476)")]
    end
  end

  def self.run(argv)
    root, output, ledger_path, *files = argv
    abort "usage: #{$PROGRAM_NAME} RUBY_ROOT OUTPUT_YAML LEDGER_JSON [--rewrite] [SPEC ...]" unless root && output && ledger_path
    rewrite = files.delete("--rewrite")
    append = files.delete("--append")
    files = %w[latex html mathml omml unicodemath unitsml intent_encoding].map { |name| "spec/plurimath/math/formula/#{name}_spec.rb" } if files.empty?
    extractor = Extractor.new(root)
    manifests = files.map { |file| extractor.extract_file(file) }
    FileUtils.mkdir_p(File.dirname(output))
    revision, status = Open3.capture2("git", "-C", root, "rev-parse", ENV.fetch("RENDERER_SOURCE_REVISION", "HEAD"))
    raise "cannot read Ruby source revision" unless status.success?

    payload = { "schema" => "plurimath-fixtures/renderer-expectations/1",
                "source" => { "revision" => revision.strip,
                              "files" => manifests.map { |file| { "path" => file.fetch("path"), "sha256" => file.fetch("source_sha256") } } + extractor.dependencies.uniq },
                "cases" => extractor.cases, "ledger" => extractor.ledger }
    if append
      previous = YAML.safe_load(File.read(output), aliases: false)
      raise "cannot append a different fixture schema" unless previous.fetch("schema") == payload.fetch("schema")

      payload["source"]["files"] = (previous.fetch("source").fetch("files") + payload.fetch("source").fetch("files")).uniq
      payload["cases"] = previous.fetch("cases") + payload.fetch("cases")
      payload["ledger"] = previous.fetch("ledger") + payload.fetch("ledger")
    end
    raise "no authored renderer expectations; select the pinned original source revision" if extractor.cases.empty?

    ids = payload.fetch("cases").map { |row| row.fetch("id") }
    raise "duplicate renderer case IDs" unless ids.uniq.length == ids.length
    # Reused static recipes must not produce YAML aliases; every consumer can
    # safely load this payload with aliases disabled.
    File.write(output, PortableYaml.dump(payload))
    File.write(ledger_path, JSON.pretty_generate({ "files" => manifests, "contexts" => extractor.ledger }) + "\n")
    if rewrite
      manifests.each do |manifest|
        next if manifest["replacements"].empty?

        path = File.join(root, manifest.fetch("path"))
        actual = File.read(path, encoding: "UTF-8")
        if ENV["RENDERER_SOURCE_REVISION"]
          text, status = Open3.capture2("git", "-C", root, "show", "#{ENV.fetch('RENDERER_SOURCE_REVISION')}:#{manifest.fetch('path')}")
          raise "cannot read original source" unless status.success?
        else
          text = actual
        end
        raise "source changed during extraction" unless Digest::SHA256.hexdigest(text) == manifest.fetch("source_sha256")

        manifest.fetch("replacements").reverse_each do |entry|
          raise "source replacement mismatch: #{path}:#{entry['start']}" unless text.byteslice(entry["start"]...entry["end"]) == entry["original"]

          text = text.byteslice(0...entry["start"]) + entry["replacement"] + text.byteslice(entry["end"]..)
        end
        text = if text.include?('require "spec_helper"')
                 text.sub('require "spec_helper"', "require \"spec_helper\"\nrequire \"support/shared_renderer_examples\"")
               else
                 "require \"spec_helper\"\nrequire \"support/shared_renderer_examples\"\n\n#{text}"
               end
        next if text == actual
        previous = actual.dup
        manifest.fetch("replacements").select { |entry| entry["cleanup"] }.each do |entry|
          previous = previous.sub(entry.fetch("original"), "")
        end
        raise "source differs from original and generated migration: #{path}" unless Digest::SHA256.hexdigest(actual) == manifest.fetch("source_sha256") || previous.gsub(/^[ \t]+$/, "") == text

        File.write(path, text)
      end
    end
    puts "#{extractor.cases.length} authored renderer cases; #{extractor.ledger.count { |row| row['disposition'] == 'retained' }} retained contexts"
  end
end

RendererExpectations.run(ARGV) if $PROGRAM_NAME == __FILE__
