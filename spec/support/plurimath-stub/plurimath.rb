# frozen_string_literal: true

# Stand-in for the plurimath gem, so spec/support/generator.rb can load
# scripts/generate-corpus.rb without the oracle bundle. Only the generator's
# gem-free helpers are specced; nothing in this stub is ever called.
module Plurimath
end
