module RSpec
  module Rails
    # Bridges rspec-core's parallel runner lifecycle with Rails' existing
    # parallel testing hooks (`ActiveSupport::Testing::Parallelization`).
    # Opt-in via `config.use_rails_parallel!` from `rails_helper.rb`; once
    # enabled, user code written against
    # `ActiveSupport::TestCase.parallelize_setup { |worker| ... }` executes
    # during RSpec's parallel runs exactly as it would under Minitest.
    #
    # Bridged lifecycle points:
    #
    # * `parallelize_before_fork` (parent, once) fires Rails'
    #   `Parallelization.before_fork_hooks` where the registry exists
    #   (Rails 8.1+; ActiveRecord uses it to `clear_all_connections!` for
    #   mysql2 fork-safety, rails#54376). Rails 7.2/8.0 have no before-fork
    #   registry and their own Minitest parallelization performs no
    #   pre-fork work, so on those versions this is intentionally a no-op.
    # * `parallelize_setup` (each worker, post-fork) fires Rails'
    #   `after_fork_hooks` after assigning per-worker state (logger,
    #   Capybara port, `TEST_ENV_NUMBER`, `parallel_worker_id`).
    # * `parallelize_teardown` (each worker, pre-exit) fires Rails'
    #   `run_cleanup_hooks`.
    #
    # When rspec-core does not yet expose the parallel API, initialization
    # is a no-op. Require-order safe: works whether or not Rails is loaded.
    class ParallelConfiguration # rubocop:disable Metrics/ClassLength
      # Highest valid TCP port; per-worker Capybara ports must not pass it.
      MAX_TCP_PORT = 65_535

      class << self
        # @api private
        # Wires rspec-core's parallel lifecycle into the Rails parallel hooks
        # registered on the given `RSpec.configuration`. Idempotent per config.
        def initialize_parallel_configuration(config)
          return unless parallel_api_available?(config)
          return unless initialized_configs.add?(config.object_id)

          ensure_active_record_hooks_loaded

          if config.respond_to?(:parallelize_before_fork)
            config.parallelize_before_fork { fire_before_fork_hooks }
          end

          config.parallelize_setup do |worker_number|
            # Defensive re-check: unusual load orders (rspec/rails required
            # before active_record) could otherwise silently skip per-worker
            # database creation. The underlying `require` is idempotent.
            ensure_active_record_hooks_loaded

            # Per-worker state first, so user hooks registered via
            # ActiveSupport::TestCase.parallelize_setup { |w| ... } see the
            # redirected logger, the per-worker Capybara port and
            # TEST_ENV_NUMBER, not the shared parent state. ActiveRecord's
            # TestDatabases hook (which creates the per-worker DB) runs
            # inside fire_after_fork_hooks; any logging it emits therefore
            # lands in the per-worker file.
            assign_test_env_number(worker_number)
            assign_parallel_worker_id(worker_number)
            redirect_rails_logger(worker_number)
            assign_capybara_port(worker_number)
            fire_after_fork_hooks(worker_number)
          end

          config.parallelize_teardown do |worker_number|
            fire_cleanup_hooks(worker_number)
          end
        end

        # @api private
        # Used in specs to exercise re-initialization against a fresh config.
        def reset_initialized_configs!
          @initialized_configs = nil
        end

        def parallel_api_available?(config)
          config.respond_to?(:parallelize_setup) &&
            config.respond_to?(:parallelize_teardown)
        end

        # @api private
        # Invokes every `ActiveSupport::Testing::Parallelization.before_fork_hook`
        # on the parent process, matching Rails' Minitest behavior. The
        # registry only exists on Rails 8.1+ (rails#54376); older Rails
        # performs no pre-fork work under Minitest either, so absence of the
        # registry means there is genuinely nothing to fire.
        def fire_before_fork_hooks
          return unless parallelization_defined?
          return unless ::ActiveSupport::Testing::Parallelization.respond_to?(:before_fork_hooks)

          ::ActiveSupport::Testing::Parallelization.before_fork_hooks.each(&:call)
        end

        # @api private
        # Invokes every `ActiveSupport::Testing::Parallelization.after_fork_hook`
        # with the worker number, matching Rails' Minitest behavior.
        #
        # A failure here means the worker could not prepare its environment
        # (most commonly: ActiveRecord::TestDatabases failing to create the
        # per-worker database). Re-raise with worker attribution so the
        # run fails loudly instead of degrading into workers that share the
        # parent's database. The original exception is preserved as `#cause`.
        def fire_after_fork_hooks(worker_number)
          return unless parallelization_defined?

          ::ActiveSupport::Testing::Parallelization.after_fork_hooks.each do |hook|
            hook.call(worker_number)
          end
        rescue StandardError => e
          raise RuntimeError,
                "rspec-rails parallel: worker #{worker_number} failed to prepare " \
                "test database / after-fork state: #{e.class}: #{e.message}",
                e.backtrace
        end

        # @api private
        # Invokes every `ActiveSupport::Testing::Parallelization.run_cleanup_hook`
        # with the worker number, matching Rails' Minitest behavior.
        def fire_cleanup_hooks(worker_number)
          return unless parallelization_defined?

          ::ActiveSupport::Testing::Parallelization.run_cleanup_hooks.each do |hook|
            hook.call(worker_number)
          end
        end

        # @api private
        # Mirrors Rails 8.1's Minitest worker, which sets
        # `ActiveSupport::TestCase.parallel_worker_id` (0-indexed) after
        # fork so app code can key per-worker resources off the public
        # reader. Older Rails has no such attribute; skip silently.
        def assign_parallel_worker_id(worker_number)
          return unless defined?(::ActiveSupport::TestCase)
          return unless ::ActiveSupport::TestCase.respond_to?(:parallel_worker_id=)

          ::ActiveSupport::TestCase.parallel_worker_id = worker_number
        end

        # @api private
        # Sets `ENV["TEST_ENV_NUMBER"]` using the parallel_tests default
        # convention -- `""` for the first worker, `"2"`, `"3"`, ... for the
        # rest -- so ecosystem tooling keyed off it (SimpleCov, Redis / ES
        # namespacing, database.yml suffixes) works unchanged. A value
        # already present in the environment (e.g. the suite itself runs
        # under parallel_tests) is left alone.
        def assign_test_env_number(worker_number)
          return if ::ENV.key?("TEST_ENV_NUMBER")

          ::ENV["TEST_ENV_NUMBER"] = worker_number.zero? ? "" : (worker_number + 1).to_s
        end

        # Capybara binds its test server to a single port when
        # `Capybara.server_port` is set, which collides across forked
        # workers. Assign each worker a dense, deterministic port:
        # `parallel_server_port_base + worker_number` (9000, 9001, ... by
        # default), so even 64+ worker CI boxes stay comfortably inside the
        # valid TCP range.
        #
        # When the user has already pinned `Capybara.server_port`
        # (Capybara's own default is nil), we leave it untouched -- their
        # explicit configuration wins -- and warn once, since a single
        # shared port cannot work across workers.
        def assign_capybara_port(worker_number)
          return unless capybara_defined?

          if ::Capybara.server_port
            if worker_number.zero?
              RSpec.warn_with(
                "WARNING: Capybara.server_port is explicitly set to " \
                "#{::Capybara.server_port}; rspec-rails will not assign " \
                "per-worker ports. Parallel workers will collide on this " \
                "port -- remove the explicit assignment (or use " \
                "`config.parallel_server_port_base`) to let each worker " \
                "get its own port."
              )
            end
            return
          end

          port = parallel_server_port_base + worker_number
          if port > MAX_TCP_PORT
            raise ArgumentError,
                  "rspec-rails parallel: worker #{worker_number} would get Capybara " \
                  "port #{port}, which exceeds the maximum TCP port (#{MAX_TCP_PORT}). " \
                  "Lower `config.parallel_server_port_base` (currently " \
                  "#{parallel_server_port_base}) or run fewer workers."
          end

          ::Capybara.server_port = port
        end

        # All workers inherit the parent's logging setup, so without
        # intervention every worker appends to `log/test.log` and
        # interleaves output. Redirect each worker to its own
        # `log/test-<worker>.log` so users can `tail -f log/test-*.log`
        # (or grep a specific worker) during debugging.
        #
        # Reassigning `Rails.logger` alone is not enough: framework
        # components (ActiveRecord::Base, ActionController::Base, ...)
        # capture the boot-time logger by reference in their railtie
        # `on_load` hooks (`self.logger ||= ::Rails.logger`), so they would
        # keep writing to the shared file. Two cases:
        #
        # * `Rails.logger` is an `ActiveSupport::BroadcastLogger` (the
        #   Rails 7.1+ default when no custom logger is configured): every
        #   component holds a reference to the same broadcaster, so we swap
        #   its sinks in place and all of them reroute at once.
        # * Plain logger (custom `config.logger` setups): reassign
        #   `Rails.logger` and every framework component logger that still
        #   pointed at the old instance.
        def redirect_rails_logger(worker_number)
          return unless rails_logger_available?

          require "fileutils"
          log_path = ::Rails.root.join("log", "test-#{worker_number}.log")
          FileUtils.mkdir_p(File.dirname(log_path))
          old_logger = ::Rails.logger
          new_logger = build_worker_logger(log_path, old_logger)

          if broadcast_logger?(old_logger)
            old_logger.broadcasts.dup.each { |sink| old_logger.stop_broadcasting_to(sink) }
            old_logger.broadcast_to(new_logger)
          else
            ::Rails.logger = new_logger
            reassign_component_loggers(old_logger, new_logger)
          end
        end

        private

        # Tracks config object_ids (not refs) to avoid pinning instances.
        def initialized_configs
          require "set"
          @initialized_configs ||= Set.new
        end

        def parallelization_defined?
          defined?(::ActiveSupport::Testing::Parallelization)
        end

        def capybara_defined?
          defined?(::Capybara)
        end

        def rails_logger_available?
          defined?(::Rails) &&
            ::Rails.respond_to?(:root) && ::Rails.root &&
            ::Rails.respond_to?(:logger) && ::Rails.logger &&
            defined?(::ActiveSupport::Logger) &&
            defined?(::ActiveSupport::TaggedLogging)
        end

        def broadcast_logger?(logger)
          defined?(::ActiveSupport::BroadcastLogger) &&
            logger.is_a?(::ActiveSupport::BroadcastLogger)
        end

        # Resilient against a Configuration instance that hasn't had
        # rspec-rails' initialize_configuration called on it (e.g. a fresh
        # RSpec::Core::Configuration.new in tests). 9000 matches the RFC
        # default and Capybara's own default port.
        def parallel_server_port_base
          if RSpec.configuration.respond_to?(:parallel_server_port_base)
            RSpec.configuration.parallel_server_port_base || 9000
          else
            9000
          end
        end

        # Builds the per-worker file logger, inheriting formatter and level
        # from the logger the app booted with. For a BroadcastLogger the
        # first sink is the representative source of both.
        def build_worker_logger(log_path, old_logger)
          template = broadcast_logger?(old_logger) ? old_logger.broadcasts.first : old_logger

          logger = ::ActiveSupport::Logger.new(log_path)
          if template
            logger.formatter = template.formatter if template.respond_to?(:formatter) && template.formatter
            logger.level     = template.level     if template.respond_to?(:level)
          end
          ::ActiveSupport::TaggedLogging.new(logger)
        end

        # Framework classes that capture `Rails.logger` by reference at
        # boot (railtie `on_load` hooks). Only reassigned when they still
        # point at the pre-redirect logger, so a component with its own
        # dedicated logger keeps it.
        COMPONENT_LOGGER_OWNERS = %w[
          ActiveRecord::Base
          ActionController::Base
          ActionView::Base
          ActionMailer::Base
          ActiveJob::Base
        ].freeze

        def reassign_component_loggers(old_logger, new_logger)
          COMPONENT_LOGGER_OWNERS.each do |name|
            next unless Object.const_defined?(name)

            component = Object.const_get(name)
            next unless component.respond_to?(:logger) && component.respond_to?(:logger=)

            component.logger = new_logger if component.logger.equal?(old_logger)
          end
        end

        # `ActiveRecord::TestDatabases` registers the before/after-fork
        # hooks that create and load per-worker test databases. It is
        # autoloaded but only *referenced* from `rails/test_help.rb`, which
        # rspec-rails apps do not require. Force the reference so the hooks
        # register.
        #
        # Rails 8.1+ additionally gates those hooks on
        # `ActiveSupport.parallelize_test_databases`, whose default is
        # `true`. We deliberately do NOT assign it: doing so would clobber
        # the documented app-level opt-out
        # (`config.active_support.parallelize_test_databases = false`) and
        # mutate global state even for serial runs.
        def ensure_active_record_hooks_loaded
          return unless defined?(::ActiveRecord)

          require "active_record/test_databases"
        rescue LoadError
          # Older Rails or unusual setups may not ship this file; the
          # integration still works for user-defined hooks, we just lose
          # automatic per-worker DB creation.
        end
      end
    end
  end
end

# Auto-wire the bridge on `require "rspec/rails"`. Installs the
# `parallelize_setup` / `parallelize_teardown` delegators against the
# current RSpec configuration so users don't need to call
# `config.use_rails_parallel!` themselves. When rspec-core hasn't shipped
# the parallel API yet, this is a no-op. When `--parallel` isn't in play,
# the hooks never fire. Users who want to disable the bridge can still
# keep their suite serial (`--no-parallel` or simply not setting
# `default_parallel_workers`). The public `use_rails_parallel!` method
# remains available and is idempotent -- it's a no-op on already-wired
# configs -- so older `rails_helper.rb` files that still call it
# continue to work unchanged.
RSpec::Rails::ParallelConfiguration.initialize_parallel_configuration(RSpec.configuration)
