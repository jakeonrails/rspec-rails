# This file is copied to spec/ when you run 'rails generate rspec:install'
require 'spec_helper'
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
# Prevent database truncation if the environment is production
abort("The Rails environment is running in production mode!") if Rails.env.production?
<% if RSpec::Rails::FeatureCheck.has_active_record_migration? -%>
# Uncomment the line below in case you have `--require rails_helper` in the `.rspec` file
# that will avoid rails generators crashing because migrations haven't been run yet
# return unless Rails.env.test?
<% end -%>
require 'rspec/rails'
# Add additional requires below this line. Rails is not loaded until this point!

# Requires supporting ruby files with custom matchers and macros, etc, in
# spec/support/ and its subdirectories. Files matching `spec/**/*_spec.rb` are
# run as spec files by default. This means that files in spec/support that end
# in _spec.rb will both be required and run as specs, causing the specs to be
# run twice. It is recommended that you do not name files matching this glob to
# end with _spec.rb. You can configure this pattern with the --pattern
# option on the command line or in ~/.rspec, .rspec or `.rspec-local`.
#
# The following line is provided for convenience purposes. It has the downside
# of increasing the boot-up time by auto-requiring all files in the support
# directory. Alternatively, in the individual `*_spec.rb` files, manually
# require only the support files necessary.
#
# Rails.root.glob('spec/support/**/*.rb').sort_by(&:to_s).each { |f| require f }

<% if RSpec::Rails::FeatureCheck.has_active_record_migration? -%>
# Ensures that the test database schema matches the current schema file.
# If there are pending migrations it will invoke `db:test:prepare` to
# recreate the test database by loading the schema.
# If you are not using ActiveRecord, you can remove these lines.
begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end
<% end -%>
RSpec.configure do |config|
<% if RSpec::Rails::FeatureCheck.has_active_record? -%>
  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_paths = [
    Rails.root.join('spec/fixtures')
  ]

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # You can uncomment this line to turn off ActiveRecord support entirely.
  # config.use_active_record = false

  # Uncomment to run specs in parallel across CPU cores when `fork` is
  # available. Each worker gets its own database
  # (<database>_<worker_number>, or <database>-<worker_number> on Rails
  # <= 8.0), its own log/test-<worker_number>.log, and its own Capybara
  # port. Set the value to an integer instead of :number_of_processors to
  # cap the worker count.
  #
  # Biggest gotcha: a `before(:suite)` block in this file runs only in
  # this parent process and never reaches forked workers, so seeding done
  # there is invisible to every worker's database. Move that seeding into
  # `config.parallelize_setup { |worker| ... }` instead, which runs once
  # per worker after its database exists.
  #
  # See features/Parallel.md for the full write-up (CLI flags, known
  # interactions with SimpleCov/JUnit/VCR/parallel_tests, etc).
  #
  # if config.respond_to?(:default_parallel_workers=) && Process.respond_to?(:fork)
  #   config.default_parallel_workers = :number_of_processors
  # end

  # Rails truncates each per-worker database at worker BOOT (not after the
  # run) when its schema is already up to date. With
  # `use_transactional_fixtures` on, every example already rolls back its
  # own transaction, so that boot-time truncation is redundant -- and slow
  # on large schemas. Uncomment to skip it:
  #   ENV['SKIP_TEST_DATABASE_TRUNCATE'] ||= '1'
  # Caveat: skipping it means data committed outside a transaction by a
  # previous run (aborted mid-suite, or written by non-transactional
  # examples) persists into the next run instead of being wiped.

<% else -%>
  # Remove this line to enable support for ActiveRecord
  config.use_active_record = false

  # If you enable ActiveRecord support you should uncomment these lines,
  # note if you'd prefer not to run each example within a transaction, you
  # should set use_transactional_fixtures to false.
  #
  # config.fixture_paths = [
  #   Rails.root.join('spec/fixtures')
  # ]
  # config.use_transactional_fixtures = true

<% end -%>
  # RSpec Rails uses metadata to mix in different behaviours to your tests,
  # for example enabling you to call `get` and `post` in request specs. e.g.:
  #
  #     RSpec.describe UsersController, type: :request do
  #       # ...
  #     end
  #
  # The different available types are documented in the features, such as in
  # https://rspec.info/features/8-0/rspec-rails
  #
  # You can also infer these behaviours automatically by location, e.g.
  # /spec/models would pull in the same behaviour as `type: :model` but this
  # behaviour is considered legacy and will be removed in a future version.
  #
  # To enable this behaviour uncomment the line below.
  # config.infer_spec_type_from_file_location!

  # Filter lines from Rails gems in backtraces.
  config.filter_rails_from_backtrace!
  # arbitrary gems may also be filtered via:
  # config.filter_gems_from_backtrace("gem name")
end
