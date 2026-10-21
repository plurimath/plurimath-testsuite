# frozen_string_literal: true

# Static Ruby syntax -> portable data. Never loads or evaluates input source.
require "prism"

module ModelRecipes
  class Unsupported < StandardError; end

  def self.parse_file(path)
    result = Prism.parse_file(path)
    raise Unsupported, "#{path}: #{result.errors.map(&:message).join('; ')}" unless result.success?

    result.value
  end

  def self.constant_name(node)
    case node
    when Prism::ConstantReadNode then node.name.to_s
    when Prism::ConstantPathNode
      child_name = node.respond_to?(:name) ? node.name : node.child.name
      [node.parent && constant_name(node.parent), child_name.to_s].compact.join("::")
    else raise Unsupported, "not a constant path: #{node.class}"
    end
  end

  def self.unwrap(recipe)
    seen = []
    while recipe.is_a?(Hash) && recipe["kind"] == "memo"
      raise Unsupported, "cyclic memo recipe" if seen.include?(recipe.object_id)

      seen << recipe.object_id
      recipe = recipe.fetch("value")
    end
    recipe
  end

  class Bindings
    def initialize
      @constants = {}
    end

    def add_file(path)
      collect(ModelRecipes.parse_file(path), [])
      self
    end

    def add_source(source)
      result = Prism.parse(source)
      raise Unsupported, "invalid constant source" unless result.success?

      collect(result.value, [])
      self
    end

    def resolve(name)
      @constants.fetch(name) { raise Unsupported, "unresolved constant #{name}" }
    end

    private

    def collect(node, scope)
      return unless node

      case node
      when Prism::ModuleNode
        collect(node.body, scope + [ModelRecipes.constant_name(node.constant_path)])
      when Prism::ConstantWriteNode
        key = (scope + [node.name.to_s]).join("::")
        raise Unsupported, "duplicate constant #{key}" if @constants.key?(key)

        @constants[key] = node.value
      else
        node.compact_child_nodes.each { |child| collect(child, scope) }
      end
    end
  end

  class Decoder
    def initialize(constants: Bindings.new)
      @constants = constants
      @resolving = []
      @resolving_bindings = []
    end

    # bindings maps local/let names to Prism expression nodes or recipe hashes.
    def emit_ast(node, bindings: {})
      case node
      when Prism::StringNode then literal(node.unescaped)
      when Prism::InterpolatedStringNode
        pieces = node.parts.map do |part|
          if part.is_a?(Prism::StringNode)
            part.unescaped
          elsif part.is_a?(Prism::EmbeddedStatementsNode) && part.statements&.body&.length == 1
            value = ModelRecipes.unwrap(emit_ast(part.statements.body.first, bindings: bindings))
            raise Unsupported, "nonliteral string interpolation" unless %w[literal symbol].include?(value["kind"])

            value.fetch("value").to_s
          else
            raise Unsupported, "unsupported string interpolation"
          end
        end
        literal(pieces.join)
      when Prism::SymbolNode then { "kind" => "symbol", "value" => node.unescaped }
      when Prism::IntegerNode, Prism::FloatNode then literal(node.value)
      when Prism::NilNode then literal(nil)
      when Prism::TrueNode then literal(true)
      when Prism::FalseNode then literal(false)
      when Prism::ArrayNode
        { "kind" => "array", "items" => emit_list(node.elements, bindings) }
      when Prism::HashNode, Prism::KeywordHashNode
        { "kind" => "map", "entries" => node.elements.map do |entry|
          raise Unsupported, "hash splat" unless entry.is_a?(Prism::AssocNode)

          { "key" => emit_ast(entry.key, bindings: bindings), "value" => emit_ast(entry.value, bindings: bindings) }
        end }
      when Prism::LocalVariableReadNode
        binding(node.name, bindings)
      when Prism::ConstantReadNode, Prism::ConstantPathNode
        name = ModelRecipes.constant_name(node)
        if name.match?(/\A(?:Plurimath::)?Math(?:::[A-Z]\w*)+\z/)
          { "kind" => "class", "name" => name.delete_prefix("Plurimath::") }
        else
          raise Unsupported, "cyclic constant #{name}" if @resolving.include?(name)

          @resolving << name
          begin
{ "kind" => "memo", "id" => "constant:#{name}", "value" => emit_ast(@constants.resolve(name), bindings: bindings) }
          ensure
            @resolving.pop
          end
        end
      when Prism::CallNode
        call(node, bindings)
      when Prism::ParenthesesNode
        body = node.body&.body
        raise Unsupported, "non-expression parentheses" unless body&.length == 1

        emit_ast(body.first, bindings: bindings)
      else
        raise Unsupported, "unsupported expression #{node.class.name.split('::').last}: #{node&.location&.slice}"
      end
    end

    private

    def literal(value)
      { "kind" => "literal", "value" => value }
    end

    def binding(name, bindings)
      key = name.to_s
      raise Unsupported, "cyclic binding #{key}" if @resolving_bindings.include?(key)

      value = bindings.fetch(key) { bindings.fetch(name.to_sym) { raise Unsupported, "unresolved binding #{name}" } }
      @resolving_bindings << key
      begin
        { "kind" => "memo", "id" => (bindings.fetch("__memo_ids__", {})[key] || "let:#{key}"), "value" => value.is_a?(Hash) ? value : emit_ast(value, bindings: bindings) }
      ensure
        @resolving_bindings.pop
      end
    end

    def emit_list(nodes, bindings)
      nodes.flat_map do |node|
        if node.is_a?(Prism::SplatNode)
          array = ModelRecipes.unwrap(emit_ast(node.expression, bindings: bindings))
          raise Unsupported, "splat is not a static array" unless array["kind"] == "array"

          [{ "kind" => "spread", "value" => emit_ast(node.expression, bindings: bindings) }]
        else
          [emit_ast(node, bindings: bindings)]
        end
      end
    end

    def call(node, bindings)
      args = node.arguments&.arguments || []
      if node.receiver.nil? && args.empty? && node.block.nil?
        return binding(node.name, bindings)
      end
      if node.name == :pack && node.block.nil? && args.length == 1 && args.first.is_a?(Prism::StringNode) && args.first.unescaped == "U*"
        array = ModelRecipes.unwrap(emit_ast(node.receiver, bindings: bindings))
        raise Unsupported, "Unicode pack requires static array" unless array["kind"] == "array"

        points = array.fetch("items").map { |item| ModelRecipes.unwrap(item) }
        unless points.all? { |item| item["kind"] == "literal" && item["value"].is_a?(Integer) && item["value"].between?(0, 0x10ffff) && !item["value"].between?(0xd800, 0xdfff) }
          raise Unsupported, "invalid Unicode scalar list"
        end
        return literal(points.map { |item| item.fetch("value") }.pack("U*"))
      end
      if node.name == :const_get && node.block.nil? && args.length == 1
        namespace = ModelRecipes.constant_name(node.receiver).delete_prefix("Plurimath::")
        name = ModelRecipes.unwrap(emit_ast(args.first, bindings: bindings))
        unless namespace.match?(/\AMath(?:::[A-Z]\w*)*\z/) && %w[literal symbol].include?(name["kind"]) && name["value"].is_a?(String) && name["value"].match?(/\A[A-Z]\w*\z/)
          raise Unsupported, "unrecognized static model class enum"
        end
        return { "kind" => "class", "name" => "#{namespace}::#{name.fetch('value')}" }
      end
      if node.name == :map && args.empty? && node.block
        array = ModelRecipes.unwrap(emit_ast(node.receiver, bindings: bindings))
        parameters = node.block.parameters&.parameters
        required = parameters&.requireds || []
        body = node.block.body
        unless array["kind"] == "array" && required.length == 1 && parameters.compact_child_nodes == required && body.is_a?(Prism::StatementsNode) && body.body.length == 1
          raise Unsupported, "unrecognized bounded literal map"
        end
        name = required.first.name.to_s
        return { "kind" => "array", "items" => array.fetch("items").each_with_index.map do |item, index|
          enclosing = [@resolving.join("/"), @resolving_bindings.join("/"),
                       bindings.fetch("__memo_ids__", {}).sort.map { |key, value| "#{key}=#{value}" }.join("|")].join(";")
          ids = bindings.fetch("__memo_ids__", {}).merge(name => "map:#{node.location.start_offset}:#{enclosing}:#{index}:#{name}")
          emit_ast(body.body.first, bindings: bindings.merge(name => item, "__memo_ids__" => ids))
        end }
      end
      if node.name == :freeze && args.empty? && node.block.nil?
        return emit_ast(node.receiver, bindings: bindings)
      end
      if node.name == :to_formula && args.empty? && node.block.nil? && node.receiver.is_a?(Prism::CallNode)
        receiver = node.receiver
        if receiver.name == :new && receiver.block.nil? &&
            ModelRecipes.constant_name(receiver.receiver) == "Plurimath::Unitsml" &&
            receiver.arguments&.arguments&.length == 1
          text = ModelRecipes.unwrap(emit_ast(receiver.arguments.arguments.first, bindings: bindings))
          raise Unsupported, "UnitsML recipe requires literal text" unless text["kind"] == "literal" && text["value"].is_a?(String)

          return { "kind" => "unitsml_formula", "text" => text.fetch("value") }
        end
      end
      unless node.name == :new && node.block.nil?
        raise Unsupported, "unsupported call #{node.location.slice}"
      end

      raw_name = begin
        ModelRecipes.constant_name(node.receiver).delete_prefix("Plurimath::")
      rescue Unsupported
        nil
      end
      receiver = if %w[Formatter::Standard NumberFormatter].include?(raw_name)
                   { "kind" => "class", "name" => raw_name }
                 else
                   ModelRecipes.unwrap(emit_ast(node.receiver, bindings: bindings))
                 end
      raise Unsupported, "constructor receiver is not a model class" unless receiver["kind"] == "class"

      name = receiver.fetch("name").delete_prefix("Plurimath::")
      formatter_kind = { "Formatter::Standard" => "standard_formatter", "NumberFormatter" => "legacy_number_formatter" }[name]
      unless formatter_kind || name.match?(/\AMath(?:::[A-Z]\w*)+\z/)
        raise Unsupported, "constructor outside Math: #{name}"
      end

      positional = args.dup
      kwargs = if positional.last.is_a?(Prism::KeywordHashNode)
                 emit_ast(positional.pop, bindings: bindings)
               else
                 { "kind" => "map", "entries" => [] }
               end
      positional = emit_list(positional, bindings)
      if formatter_kind
        if formatter_kind == "standard_formatter" && !positional.empty? || positional.length > 1
          raise Unsupported, "unsupported formatter positional arguments"
        end
        return { "kind" => formatter_kind, "args" => positional, "kwargs" => kwargs }
      end
      { "kind" => "constructor", "class" => name,
        "args" => positional, "kwargs" => kwargs }
    end
  end
end
