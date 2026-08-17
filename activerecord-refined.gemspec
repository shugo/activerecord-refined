# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'activerecord-refined/version'

Gem::Specification.new do |gem|
  gem.name          = "activerecord-refined"
  gem.version       = Activerecord::Refined::VERSION
  gem.authors       = ["Shugo Maeda"]
  gem.email         = ["shugo@ruby-lang.org"]
  gem.description   = 'Adding clean and powerful query syntax on Active Record using refinements'
  gem.summary       = 'Write Active Record queries as Ruby expressions'
  gem.homepage      = 'https://github.com/shugo/activerecord-refined'

  # sandbox/ is a site, not part of the library: its Gemfile.lock and
  # package-lock.json have no business in anyone's bundle.  CLAUDE.md is
  # addressed to whoever is working on the repository, not to anyone using it.
  gem.files         = `git ls-files`.split($/).grep_v(%r{^sandbox/|^CLAUDE\.md$})
  gem.executables   = gem.files.grep(%r{^bin/}).map{ |f| File.basename(f) }
  gem.test_files    = gem.files.grep(%r{^(test|spec|features)/})
  gem.require_paths = ["lib"]

  # Proc#refined is available since Ruby 4.1. 4.1.0.dev is required to allow
  # ruby-master builds, which sort before the 4.1.0 release.
  gem.required_ruby_version = '>= 4.1.0.dev'

  gem.add_dependency 'activerecord', ['>= 7.0']
  gem.add_development_dependency 'sqlite3', ['>= 0']
  gem.add_development_dependency 'minitest', ['>= 0']
  gem.add_development_dependency 'rake', ['>= 0']
  # What cuts a release: `bump patch --tag`, then push with --follow-tags.
  gem.add_development_dependency 'bump', ['>= 0']
  # What benchmark/query_building.rb measures with.
  gem.add_development_dependency 'benchmark-ips', ['>= 0']
  gem.add_development_dependency 'memory_profiler', ['>= 0']
end
