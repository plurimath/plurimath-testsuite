# frozen_string_literal: true

# CI entry point: `ruby spec/all.rb` runs the whole suite (minitest autoruns
# at process exit and sets a nonzero status on any failure).
Dir.glob(File.join(__dir__, "*_spec.rb")).sort.each { |file| require file }
