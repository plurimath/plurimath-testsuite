# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "Portable model recipe schemas" do
  %w[parser-expectations renderer-expectations xml-parser-expectations].each do |family|
    context family do
      def recipe_schema(family)
        original = JSON.parse(File.read(File.join(REPO_ROOT, "schema", "#{family}.json")))
        build_schema({ "$defs" => original.fetch("$defs") },
                     properties: { "model" => { "$ref" => "#/$defs/recipe" } })
      end

      let(:schema) { recipe_schema(family) }
      let(:literal) { { "kind" => "literal", "value" => "x" } }
      let(:empty_map) { { "kind" => "map", "entries" => [] } }

      it "rejects unknown kinds, undeclared fields and standalone spread" do
        [{ "kind" => "unknown" }, literal.merge("eval" => "x"),
         { "kind" => "spread", "value" => literal }].each do |invalid|
          expect(errors_for(schema, { "model" => invalid })).not_to be_empty
        end
      end

      it "checks typed kwargs, formatter arity and list-only spread" do
        constructor = { "kind" => "constructor", "class" => "Math::Number",
                        "args" => [literal], "kwargs" => empty_map }
        expect(errors_for(schema, { "model" => constructor })).to be_empty
        expect(errors_for(schema, { "model" => constructor.merge("kwargs" => literal) })).not_to be_empty
        formatter = { "kind" => "standard_formatter", "args" => [], "kwargs" => empty_map }
        expect(errors_for(schema, { "model" => formatter })).to be_empty
        expect(errors_for(schema, { "model" => formatter.merge("args" => [literal]) })).not_to be_empty
        array = { "kind" => "array", "items" => [{ "kind" => "spread",
                  "value" => { "kind" => "array", "items" => [literal] } }] }
        expect(errors_for(schema, { "model" => array })).to be_empty
      end

      it "does not revisit recursive children through incompatible recipe kinds" do
        recipe = literal
        20.times do
          recipe = { "kind" => "constructor", "class" => "Math::Formula",
                     "args" => [recipe], "kwargs" => empty_map }
        end
        visits = 0
        schema.define_singleton_method(:check) do |*arguments|
          visits += 1
          raise "recursive schema traversal exceeded bounded visits" if visits > 50_000

          super(*arguments)
        end
        expect(errors_for(schema, { "model" => recipe })).to be_empty
      end
    end
  end
end
