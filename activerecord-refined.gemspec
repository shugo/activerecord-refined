# -*- encoding: utf-8 -*-
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'activerecord-refined/version'

Gem::Specification.new do |gem|
  gem.name          = "activerecord-refined"
  gem.version       = Activerecord::Refined::VERSION
  gem.authors       = ["Shugo Maeda"]
  gem.email         = ["shugo@ruby-lang.org"]
  gem.description   = 'Adding clean and powerful query syntax on AR using refinements'
  gem.summary       = 'ActiveRecord + Ruby 2.0 refinements'
  gem.homepage      = 'https://github.com/shugo/activerecord-refined'

  gem.files         = `git ls-files`.split($/)
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
end
