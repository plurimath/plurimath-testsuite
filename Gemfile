# frozen_string_literal: true

# Development only: the spec/lint tools and static source exporters.
# scripts/validate.rb and scripts/generate-corpus.rb stay gem-free — CI runs
# the validator with plain `ruby` and no bundle, and that must keep working.
source "https://rubygems.org"

gem "rspec", "~> 3.13"
# Static migration exporters parse Ruby source without loading it.
gem "prism", ">= 0.19", "< 2"
gem "rubocop-performance"
gem "rubocop-rake"
gem "rubocop-rspec"
