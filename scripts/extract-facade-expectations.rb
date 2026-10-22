# frozen_string_literal: true

# Static authored facade/number-format expectations. Never loads specs or parses math.
require_relative "lib/portable_yaml"
require_relative "extract-renderer-expectations"

module FacadeExpectations
  REVISION = "a6bac8dcf76af4347eb93fa2a7289eb278dd3ffa"
  FILES = %w[number_formatter base_prefix_parsing base_number_prefix math unitsml].map { |name| "spec/plurimath/#{name}_spec.rb" }.freeze
  ERROR_CATEGORIES = {
    "Parslet::ParseFailed" => "parse_failure", "Plurimath::ConfigurationError" => "configuration_error",
    "Plurimath::Errors::InvalidNumber" => "invalid_number", "Plurimath::Errors::UnsupportedBase" => "unsupported_base",
    "Plurimath::Errors::UnsupportedLocale" => "unsupported_locale", "Plurimath::Math::ParseOptionError" => "parse_option_error",
    "Plurimath::Math::InvalidTypeError" => "invalid_type", "Plurimath::Math::ParseError" => "parse_error",
  }.freeze
  PROJECTIONS = %w[value base integer_part fraction_part decimal_separator digits_string base_notation prefix to_s].freeze
  KINDS = %w[Math::Number Formatter::Numbers::FormattedNumber Formatter::Numbers::FormattedNotation].freeze
  class Unsupported < RendererExpectations::Unsupported; end

  class Compiler < RendererExpectations::ProgramCompiler
    def compile(example)
      process(@extractor.statements(example))
      raise Unsupported, "empty facade observations" if @assertion_lines.empty?
      { "program" => { "steps" => @steps, "assertion_lines" => @assertion_lines } }
    end

    def compile_region(statements)
      process(statements)
      raise Unsupported, "empty region" if @assertion_lines.empty?
      { "steps" => @steps, "assertion_lines" => @assertion_lines }
    end

    def process(statements)
      statements.each do |statement|
        if statement.is_a?(Prism::LocalVariableWriteNode)
          @variables[statement.name.to_s] = expression(statement.value)
          @bindings[statement.name.to_s] = statement.value
        elsif statement.is_a?(Prism::CallNode) && statement.name == :each && statement.block
          items = @extractor.static_value(statement.receiver, @bindings)
          raise Unsupported, "each operand is not static array" unless items.is_a?(Array)
          array_slot = expression(statement.receiver)
          parameters = statement.block.parameters&.parameters
          names = parameters&.requireds&.map { |node| node.name.to_s } || []
          raise Unsupported, "unsupported literal each parameters" unless names.length == 1 && parameters.compact_child_nodes.length == 1
          name = names.first
          previous_binding, previous_variable = @bindings[name], @variables[name]
          items.each_with_index do |item, index|
            @bindings[name] = @extractor.recipe(item)
            key = emit("build", "recipe" => { "kind" => "literal", "value" => index })
            @variables[name] = emit("facade_index", "source" => array_slot, "key" => key)
            process(@extractor.statements(statement))
          end
          previous_binding ? @bindings[name] = previous_binding : @bindings.delete(name)
          previous_variable ? @variables[name] = previous_variable : @variables.delete(name)
        elsif statement.is_a?(Prism::CallNode) && %i[to not_to].include?(statement.name) && statement.receiver&.name == :expect
          compile_assertion(statement)
        else
          raise Unsupported, "native statement #{statement.location.slice.lines.first.to_s.strip}"
        end
      end
    end

    def compile_assertion(node)
      expect_node = node.receiver
      matcher = args(node).first
      raise Unsupported, "unsupported matcher wrapper" unless matcher.is_a?(Prism::CallNode) && matcher.receiver.nil?
      @assertion_lines << expect_node.location.start_line
      if matcher.name == :raise_error && expect_node.block
        outer_steps = @steps
        @steps = []
        process_block = @extractor.statements(expect_node)
        process_block.each { |expr| expression(expr) }
        nested = @steps
        @steps = outer_steps
        if node.name == :not_to
          raise Unsupported, "negated error with arguments" unless args(matcher).empty?
          @steps << { "kind" => "facade_no_error", "steps" => nested, "assertion_line" => expect_node.location.start_line }
        else
          arguments = args(matcher)
          category = ERROR_CATEGORIES.fetch(ModelRecipes.constant_name(arguments.fetch(0))) { raise Unsupported, "unknown error category" }
          raise Unsupported, "too many error matcher arguments" if arguments.length > 2
          error = { "category" => category }
          error["message"] = @extractor.pattern(arguments.last, @bindings) if arguments.length == 2
          @steps << { "kind" => "facade_error", "steps" => nested, "error" => error, "assertion_line" => expect_node.location.start_line }
        end
        return
      end
      raise Unsupported, "unexpected block matcher" if expect_node.block
      actual = expression(args(expect_node).fetch(0))
      comparison = matcher.name.to_s
      if %i[be_a be_an].include?(matcher.name)
        name = @extractor.class_name(args(matcher).fetch(0), @bindings)
        raise Unsupported, "Ruby object kind API" unless KINDS.include?(name)
        expected = { "expected_kind" => name }
        comparison = "model_kind"
      elsif matcher.name == :be_nil
        expected = {}
      elsif %i[be_base_notation be_negative be_fractional].include?(matcher.name)
        expected = {}
      elsif %i[eq eql be_xml_equivalent_to].include?(matcher.name)
        expected = { "expected_slot" => expression(args(matcher).fetch(0)) }
      else
        raise Unsupported, "native matcher #{matcher.name}"
      end
      raise Unsupported, "unsupported negated matcher" unless node.name == :to
      @steps << { "kind" => "assert", "source" => actual, "comparison" => comparison, "assertion_line" => expect_node.location.start_line }.merge(expected)
    end

    def split_arguments(node)
      positional = args(node).dup
      keyword_node = positional.last.is_a?(Prism::KeywordHashNode) ? positional.pop : nil
      arguments = emit("facade_array", "items" => positional.map { |arg| expression(arg) })
      keywords = keyword_node ? expression(keyword_node) : emit("facade_map", "entries" => [])
      [arguments, keywords]
    end

    def expression(node)
      if (name = binding_name(node))
        return @variables.fetch(name) if @variables.key?(name)
        if @bindings.key?(name) && !@bindings.fetch(name).is_a?(Hash)
          raise Unsupported, "cyclic facade binding #{name}" if @resolving.include?(name)
          @resolving << name
          begin
            return @variables[name] = expression(@bindings.fetch(name))
          ensure
            @resolving.pop
          end
        end
      end
      if node.is_a?(Prism::HashNode) || node.is_a?(Prism::KeywordHashNode)
        entries = node.elements.map do |entry|
          if entry.is_a?(Prism::AssocNode)
            { "key" => expression(entry.key), "value" => expression(entry.value) }
          elsif entry.is_a?(Prism::AssocSplatNode)
            { "spread" => expression(entry.value) }
          else raise Unsupported, "unsupported facade map entry"
          end
        end
        return emit("facade_map", "entries" => entries)
      end
      if node.is_a?(Prism::ArrayNode)
        return emit("facade_array", "items" => node.elements.map { |item| expression(item) })
      end
      if node.is_a?(Prism::CallNode)
        if node.name == :merge && !node.block && args(node).length == 1
          return emit("facade_merge", "source" => expression(node.receiver), "other" => expression(args(node).first))
        end
        if node.name == :to_sym && !node.block && args(node).empty?
          return emit("facade_to_sym", "source" => expression(node.receiver))
        end
        if node.name == :new && !node.block
          class_name = @extractor.class_name(node.receiver, @bindings)
          if %w[NumberFormatter Formatter::Standard Unitsml].include?(class_name)
            positional, keywords = split_arguments(node)
            return emit("facade_construct", "class" => class_name, "args" => positional, "kwargs" => keywords)
          end
        end
        if %i[localized_number twitter_cldr_reader formatted_number].include?(node.name) && !node.block
          source = expression(node.receiver)
          positional, keywords = split_arguments(node)
          return emit("facade_format", "source" => source, "method" => node.name.to_s, "args" => positional, "kwargs" => keywords)
        end
        if node.name == :parse && @extractor.class_name(node.receiver, @bindings) == "Math"
          positional, keywords = split_arguments(node)
          return emit("facade_parse", "args" => positional, "kwargs" => keywords)
        end
        if %i[parse apply].include?(node.name) && node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :new && args(node.receiver).empty?
          receiver = node.receiver.receiver
          if binding_name(receiver) == (node.name == :parse ? "parser_class" : "transform_class")
            positional, keywords = split_arguments(node)
            return emit("facade_base", "operation" => node.name == :parse ? "parse" : "apply", "args" => positional, "kwargs" => keywords)
          end
        end
        if PROJECTIONS.include?(node.name.to_s) && !node.receiver.nil? && args(node).empty? && !node.block
          return emit("facade_project", "source" => expression(node.receiver), "property" => node.name.to_s)
        end
        if node.name == :[] && args(node).length == 1 && !node.block
          return emit("facade_index", "source" => expression(node.receiver), "key" => expression(args(node).first))
        end
      end
      super
    end
  end

  class Extractor < RendererExpectations::Extractor
    attr_reader :rewrites, :sources
    def initialize(root)
      @root = File.expand_path(root)
      @decoder = ModelRecipes::Decoder.new
      @cases, @ledger, @sources, @rewrites = [], [], [], {}
    end

    def source(path)
      text,status = Open3.capture2("git", "-C", @root, "show", "#{REVISION}:#{path}")
      raise Unsupported, "missing pinned source #{path}" unless status.success?
      text
    end

    def recipe(value)
      case value
      when Symbol then { "kind" => "symbol", "value" => value.to_s }
      when Array then { "kind" => "array", "items" => value.map { |v| recipe(v) } }
      when Hash then { "kind" => "map", "entries" => value.map { |key,v| { "key" => recipe(key), "value" => recipe(v) } } }
      when String, Integer, Float, TrueClass, FalseClass, NilClass then { "kind" => "literal", "value" => value }
      else raise Unsupported, "nonportable static literal"
      end
    end

    def static_value(node, bindings)
      if node.is_a?(Hash)
        return literal_value(node)
      end
      name = node.name.to_s if node.is_a?(Prism::LocalVariableReadNode) || node.is_a?(Prism::CallNode) && node.receiver.nil? && arguments(node).empty?
      return static_value(bindings.fetch(name), bindings.reject { |key,_|key==name }) if name && bindings.key?(name)
      if node.is_a?(Prism::CallNode)
        return static_value(node.receiver, bindings).to_sym if node.name == :to_sym && arguments(node).empty?
        return static_value(node.receiver, bindings).inspect if node.name == :inspect && arguments(node).empty?
        return Regexp.escape(static_value(arguments(node).fetch(0), bindings)) if node.name == :escape && node.receiver&.location&.slice == "Regexp" && arguments(node).length == 1
        return static_value(node.receiver, bindings).merge(static_value(arguments(node).fetch(0), bindings)) if node.name == :merge && arguments(node).length == 1
      end
      if node.is_a?(Prism::ArrayNode)
        return node.elements.map { |child| static_value(child, bindings) }
      end
      if node.is_a?(Prism::InterpolatedStringNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)
        return node.parts.map { |part| part.is_a?(Prism::StringNode) ? part.unescaped : static_value(part.statements.body.fetch(0), bindings).to_s }.join
      end
      literal_value(@decoder.emit_ast(node, bindings:bindings))
    end

    def literal_value(data)
      data=ModelRecipes.unwrap(data)
      case data.fetch("kind")
      when "literal" then data.fetch("value")
      when "symbol" then data.fetch("value").to_sym
      when "array" then data.fetch("items").map { |value|literal_value(value) }
      when "map" then data.fetch("entries").to_h { |entry|[literal_value(entry.fetch("key")),literal_value(entry.fetch("value"))] }
      else raise Unsupported,"expected primitive literal"
      end
    end

    def pattern(node,bindings)
      if node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)
        raise Unsupported,"regexp flags not audited" unless node.options==0
        text=node.is_a?(Prism::RegularExpressionNode) ? node.unescaped : static_value(node,bindings)
        return { "kind"=>"regex", "source"=>text, "options"=>0 }
      end
      if node.is_a?(Prism::CallNode) && node.name==:compile && node.receiver&.location&.slice=="Regexp" && arguments(node).length==1
        return { "kind"=>"regex", "source"=>static_value(arguments(node).first,bindings), "options"=>0 }
      end
      value=static_value(node,bindings)
      raise Unsupported,"error message must be text" unless value.is_a?(String)
      { "kind"=>"string", "value"=>value }
    end

    def nodes(node)
      return [] unless node
      [node,*node.compact_child_nodes.flat_map { |child|nodes(child) }]
    end

    def statements(node)
      raise Unsupported, "native ensure scaffold" unless node.block&.body.is_a?(Prism::StatementsNode)
      node.block.body.body
    end

    def container_statements(node)
      body=node.block&.body
      body.is_a?(Prism::StatementsNode) ? body.body : []
    end

    def scoped_bindings(node,inherited)
      bindings=inherited.dup
      container_statements(node).each do |child|
        if child.is_a?(Prism::CallNode) && %i[let subject].include?(child.name) && child.block
          body=container_statements(child)
          next unless body.length==1
          name=arguments(child).first
          key=name.is_a?(Prism::SymbolNode) ? name.unescaped : child.name==:subject ? "subject" : nil
          bindings[key]=body.first if key
        elsif child.is_a?(Prism::LocalVariableWriteNode)
          bindings[child.name.to_s]=child.value
        end
      end
      bindings
    end

    def record(node,path,status,reason:nil,ids:[])
      checks=nodes(node).grep(Prism::CallNode).select { |call|%i[to not_to].include?(call.name) && call.receiver.is_a?(Prism::CallNode) && call.receiver.name==:expect }
      row={ "file"=>path,"line"=>node.location.start_line,"sha256"=>Digest::SHA256.hexdigest(node.location.slice),
        "status"=>status,"case_ids"=>ids,"assertions"=>checks.map { |check| { "line"=>check.receiver.location.start_line,"sha256"=>Digest::SHA256.hexdigest(check.location.slice) } } }
      row["reason"]=reason if reason
      row["native_assertions"] = checks.map { |check| check.location.slice } if status == "native"
      @ledger << row
    end

    def add_replacement(node,text)
      @rewrites.fetch(@relative).fetch(:replacements) << [node.location.start_offset,node.location.length,text]
    end

    def case_text(ids)
      ids.map { |id|"it_behaves_like \"shared facade expectation\", #{id.inspect}" }.join("\n")
    end

    def export_mixed_configuration(node, bindings, labels, suffix, rewrite)
      body = node.block.body
      raise Unsupported, "unknown native ensure body" unless body.is_a?(Prism::BeginNode) && body.rescue_clause.nil? && body.else_clause.nil? && body.ensure_clause
      statements = body.statements.body
      setup, setter, *rest = statements
      native_check = rest.pop
      raise Unsupported, "configuration save changed" unless setup.location.slice == "previous_locale = Plurimath.configuration.locale"
      locale = setter.arguments&.arguments&.first
      raise Unsupported, "configuration setter changed" unless setter.is_a?(Prism::CallNode) && setter.name == :locale= && setter.receiver.location.slice == "Plurimath.configuration" && locale.is_a?(Prism::SymbolNode) && %w[en fr].include?(locale.unescaped)
      raise Unsupported, "configuration ensure changed" unless body.ensure_clause.statements.body.length == 1 && body.ensure_clause.statements.body.first.location.slice == "Plurimath.configuration.locale = previous_locale"
      expected_check = "expect(Plurimath.configuration.locale).to be(:#{locale.unescaped})"
      raise Unsupported, "configuration observation changed" unless native_check.location.slice == expected_check
      program = Compiler.new(self, bindings).compile_region(rest)
      id = "facade-math-#{node.location.start_line}#{suffix}"
      @cases << { "id"=>id, "label"=>labels.join(' / '), "configuration"=>{ "locale"=>locale.unescaped }, "program"=>program,
        "source"=>{ "file"=>@relative,"line"=>node.location.start_line,"sha256"=>Digest::SHA256.hexdigest(node.location.slice) } }
      record(node,@relative,"mixed",reason:"Ruby shared configuration accessor API retained",ids:[id])
      @ledger.last["native_assertion_lines"] = [native_check.receiver.location.start_line]
      @ledger.last["native_assertions"] = [native_check.location.slice]
      if rewrite
        start=rest.first.location.start_offset
        length=rest.last.location.end_offset-start
        @rewrites.fetch(@relative).fetch(:replacements) << [start,length,"shared_facade_expectations(#{id.inspect})"]
      end
      [id]
    end

    def export_example(node,bindings,labels,suffix,rewrite)
      if @relative.end_with?("math_spec.rb") && node.block.body.is_a?(Prism::BeginNode)
        return export_mixed_configuration(node,bindings,labels,suffix,rewrite)
      end
      reason=if @relative.end_with?("number_formatter_spec.rb") && labels.include?(".initialize")
               "Ruby formatter construction and accessor API"
             elsif @relative.end_with?("number_formatter_spec.rb") && labels.include?("with post-construction writers")
               "Ruby formatter writer validation API"
             elsif @relative.end_with?("unitsml_spec.rb") && node.location.slice.include?("expect(unitsml).to be_a(described_class)")
               "Ruby Unitsml wrapper class and text accessor API"
             end
      if reason
        record(node,@relative,"native",reason:reason)
        return []
      end
      begin
        compiled=Compiler.new(self,bindings).compile(node)
        id="facade-#{File.basename(@relative,'_spec.rb').tr('_','-')}-#{node.location.start_line}#{suffix}"
        configuration={}
        labels.each { |label|configuration['locale']='fr' if label=='when persistent configuration sets a locale' }
        @cases << { "id"=>id,"label"=>labels.join(' / '),"configuration"=>configuration,"program"=>compiled.fetch("program"),
          "source"=>{ "file"=>@relative,"line"=>node.location.start_line,"sha256"=>Digest::SHA256.hexdigest(node.location.slice) } }
        record(node,@relative,"exported",ids:[id])
        add_replacement(node,case_text([id])) if rewrite
        [id]
      rescue RendererExpectations::Unsupported,ModelRecipes::Unsupported,KeyError => error
        record(node,@relative,"unclassified",reason:error.message)
        []
      end
    end

    def loop_iterations(node,bindings)
      if node.name==:with_index && node.receiver.is_a?(Prism::CallNode) && node.receiver.name==:each
        values=static_value(node.receiver.receiver,bindings)
        start=static_value(arguments(node).fetch(0),bindings)
        tuples=values.each_with_index.map { |value,index|[value,index+start] }
      elsif node.name==:each
        tuples=static_value(node.receiver,bindings)
      else raise Unsupported,"unrecognized bounded outer loop"
      end
      parameters=node.block.parameters&.parameters
      names=parameters&.requireds&.map { |parameter|parameter.name.to_s }||[]
      raise Unsupported,"unsupported outer loop parameters" unless parameters && parameters.compact_child_nodes.length==names.length
      tuples.map do |tuple|
        values=names.length==1 ? [tuple] : tuple
        raise Unsupported,"outer loop tuple arity" unless values.is_a?(Array)&&values.length==names.length
        bindings.merge(names.zip(values.map { |value|recipe(value) }).to_h)
      end
    end

    def visit_container(node,inherited,labels=[],suffix="",rewrite=true)
      bindings=scoped_bindings(node,inherited)
      container_statements(node).each do |child|
        next unless child.is_a?(Prism::CallNode)
        if %i[it specify].include?(child.name)&&child.block
          export_example(child,bindings,labels,suffix,rewrite)
        elsif %i[describe context].include?(child.name)&&child.block
          label=arguments(child).first
          text=label.is_a?(Prism::StringNode) ? label.unescaped : label&.location&.slice.to_s
          visit_container(child,bindings,labels+[text],suffix,rewrite)
        elsif %i[each with_index].include?(child.name)&&child.block
          before=@cases.length
          before_ledger=@ledger.length
          iterations=loop_iterations(child,bindings)
          iterations.each_with_index { |scope,index|visit_container(child,scope,labels,"#{suffix}-iteration-#{index+1}",false) }
          raise Unsupported,"outer loop contains unclassified/native examples" unless @ledger[before_ledger..].all? { |row|row['status']=='exported' }
          ids=@cases[before..].map { |row|row.fetch('id') }
          add_replacement(child,case_text(ids)) if rewrite
        elsif child.name==:it_behaves_like && arguments(child).first.is_a?(Prism::StringNode) && @shared.key?(arguments(child).first.unescaped)
          definition=@shared.fetch(arguments(child).first.unescaped)
          names=definition.block.parameters.parameters.requireds.map { |parameter|parameter.name.to_s }
          values=arguments(child).drop(1).map { |argument|@decoder.emit_ast(argument,bindings:bindings) }
          raise Unsupported,"shared example arity" unless names.length==values.length
          before=@cases.length
          visit_container(definition,bindings.merge(names.zip(values).to_h),labels,"#{suffix}-variant-#{child.location.start_line}",false)
          ids=@cases[before..].map { |row|row.fetch('id') }
          add_replacement(child,case_text(ids)) if rewrite
        end
      end
    end

    def extract
      FILES.each do |path|
        @relative=path
        original=source(path)
        parsed=Prism.parse(original)
        raise Unsupported,"invalid pinned source" unless parsed.success?
        @sources << { "path"=>path,"sha256"=>Digest::SHA256.hexdigest(original) }
        @rewrites[path]={source:original,replacements:[]}
        all=nodes(parsed.value).grep(Prism::CallNode)
        @shared=all.select { |node|node.name==:shared_examples }.to_h { |node|[arguments(node).first.unescaped,node] }
        roots=all.select { |node|node.name==:describe&&node.receiver&.location&.slice=='RSpec' }
        raise Unsupported,"expected one RSpec root" unless roots.length==1
        root=roots.first
        class_name=arguments(root).first.location.slice.delete_prefix('Plurimath::')
        visit_container(root,{ 'described_class'=>{ 'kind'=>'class','name'=>class_name } },[class_name])
        @shared.each_value { |definition|add_replacement(definition,'# Shared portable cases are declared at their original call sites below.') }
      end
      ids=@cases.map { |row|row.fetch('id') }
      raise Unsupported,"empty/duplicate cases" if ids.empty?||ids.uniq.length!=ids.length
      { 'schema'=>'plurimath-fixtures/facade-expectations/1','source'=>{ 'revision'=>REVISION,'files'=>@sources },'cases'=>@cases,'ledger'=>@ledger }
    end

    def rewritten_sources
      @rewrites.to_h do |path,data|
        original=data.fetch(:source)
        output=original.b.dup
        data.fetch(:replacements).sort_by(&:first).reverse_each do |start,length,text|
          indent=original.byteslice(0,start).split("\n").last.to_s[/\A */].to_s
          output[start,length]=text.gsub("\n","\n#{indent}").b
        end
        output=output.sub('require "spec_helper"',"require \"spec_helper\"\nrequire_relative \"../support/shared_facade_examples\"")
        [path,output]
      end
    end

    def rewrite!
      outputs=rewritten_sources
      outputs.each do |path,output|
        current=File.binread(File.join(@root,path))
        raise Unsupported,"#{path}: refusing unrelated edits" unless [@rewrites.fetch(path).fetch(:source).b,output].include?(current)
      end
      outputs.each { |path,output|File.binwrite(File.join(@root,path),output) }
    end
  end
end

if $PROGRAM_NAME==__FILE__
  root,output=ARGV.shift(2)
  abort 'usage: extract-facade-expectations.rb GEM_ROOT OUTPUT [--rewrite]' unless root&&output
  rewrite=ARGV.delete('--rewrite')
  abort 'unexpected arguments' unless ARGV.empty?
  extractor=FacadeExpectations::Extractor.new(root)
  data=extractor.extract
  File.write(output,PortableYaml.dump(data, line_width: -1))
  extractor.rewrite! if rewrite
  puts JSON.generate(cases:data.fetch('cases').length,source_examples:data.fetch('ledger').length,statuses:data.fetch('ledger').map { |row|row.fetch('status') }.tally)
end
