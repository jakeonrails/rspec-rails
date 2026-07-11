require "rspec/rails/parallel"

begin
  require "rspec/core/parallel/runner"
rescue LoadError
  # rspec-core without the parallel runner -- the real-fork describe block below
  # is :if-guarded to skip in that case.
end

RSpec.describe RSpec::Rails::ParallelConfiguration do
  let(:fake_config) { instance_double("RSpec::Core::Configuration") }

  describe ".parallel_api_available?" do
    it "is true when config responds to both parallelize_setup and parallelize_teardown" do
      allow(fake_config).to receive(:respond_to?).with(:parallelize_setup).and_return(true)
      allow(fake_config).to receive(:respond_to?).with(:parallelize_teardown).and_return(true)
      expect(described_class.parallel_api_available?(fake_config)).to be true
    end

    it "is false when teardown is missing" do
      allow(fake_config).to receive(:respond_to?).with(:parallelize_setup).and_return(true)
      allow(fake_config).to receive(:respond_to?).with(:parallelize_teardown).and_return(false)
      expect(described_class.parallel_api_available?(fake_config)).to be false
    end

    it "is false when none are present (pre-parallel rspec-core)" do
      allow(fake_config).to receive(:respond_to?).with(:parallelize_setup).and_return(false)
      allow(fake_config).to receive(:respond_to?).with(:parallelize_teardown).and_return(false)
      expect(described_class.parallel_api_available?(fake_config)).to be false
    end
  end

  describe ".initialize_parallel_configuration" do
    context "when rspec-core lacks the parallel API" do
      it "is a silent no-op" do
        allow(described_class).to receive(:parallel_api_available?).and_return(false)
        expect { described_class.initialize_parallel_configuration(fake_config) }.not_to raise_error
      end
    end

    context "when rspec-core exposes the parallel API" do
      let(:fake_parallel_config) do
        Class.new do
          attr_reader :before_fork_block, :setup_block, :teardown_block

          def parallelize_before_fork(&blk) = @before_fork_block = blk
          def parallelize_setup(&blk) = @setup_block = blk
          def parallelize_teardown(&blk) = @teardown_block = blk
        end.new
      end

      before do
        allow(described_class).to receive(:ensure_active_record_hooks_loaded)
      end

      # Prevents in-process ENV / Capybara / logger mutation when specs
      # invoke the captured setup block directly.
      def stub_per_worker_assignments
        allow(described_class).to receive(:assign_test_env_number)
        allow(described_class).to receive(:assign_parallel_worker_id)
        allow(described_class).to receive(:redirect_rails_logger)
        allow(described_class).to receive(:assign_capybara_port)
      end

      it "registers blocks for all three lifecycle points" do
        described_class.initialize_parallel_configuration(fake_parallel_config)

        expect(fake_parallel_config.before_fork_block).to be_a(Proc)
        expect(fake_parallel_config.setup_block).to be_a(Proc)
        expect(fake_parallel_config.teardown_block).to be_a(Proc)
      end

      it "tolerates a config without parallelize_before_fork (older parallel API)" do
        config = Class.new do
          attr_reader :setup_block, :teardown_block

          def parallelize_setup(&blk) = @setup_block = blk
          def parallelize_teardown(&blk) = @teardown_block = blk
        end.new

        expect { described_class.initialize_parallel_configuration(config) }.not_to raise_error
        expect(config.setup_block).to be_a(Proc)
      end

      it "the before_fork block fans out to Rails' before_fork hooks" do
        described_class.initialize_parallel_configuration(fake_parallel_config)
        expect(described_class).to receive(:fire_before_fork_hooks)
        fake_parallel_config.before_fork_block.call
      end

      it "the setup block fans out with the worker number" do
        described_class.initialize_parallel_configuration(fake_parallel_config)
        stub_per_worker_assignments
        expect(described_class).to receive(:fire_after_fork_hooks).with(3)
        fake_parallel_config.setup_block.call(3)
      end

      it "the setup block re-checks ActiveRecord hook registration (load-order safety)" do
        described_class.initialize_parallel_configuration(fake_parallel_config)
        stub_per_worker_assignments
        allow(described_class).to receive(:fire_after_fork_hooks)

        fake_parallel_config.setup_block.call(0)

        # Once at initialization time, once inside the worker setup hook.
        expect(described_class).to have_received(:ensure_active_record_hooks_loaded).twice
      end

      # User code registered via `ActiveSupport::TestCase.parallelize_setup`
      # fans out through `fire_after_fork_hooks`. The per-worker logger and
      # Capybara port therefore must be assigned *before* those hooks run, or
      # user hooks observe the shared parent-process state the branch
      # advertises away.
      it "assigns per-worker state before firing user after_fork_hooks" do
        described_class.initialize_parallel_configuration(fake_parallel_config)

        call_order = []
        allow(described_class).to receive(:assign_test_env_number) { call_order << :test_env_number }
        allow(described_class).to receive(:assign_parallel_worker_id) { call_order << :worker_id }
        allow(described_class).to receive(:redirect_rails_logger) { call_order << :logger }
        allow(described_class).to receive(:assign_capybara_port) { call_order << :port }
        allow(described_class).to receive(:fire_after_fork_hooks) { call_order << :user_hooks }

        fake_parallel_config.setup_block.call(0)

        expect(call_order.last).to eq(:user_hooks)
        expect(call_order).to include(:test_env_number, :worker_id, :logger, :port)
      end

      it "the teardown block fans out with the worker number" do
        described_class.initialize_parallel_configuration(fake_parallel_config)
        expect(described_class).to receive(:fire_cleanup_hooks).with(7)
        fake_parallel_config.teardown_block.call(7)
      end

      it "forces ActiveRecord hook registration" do
        expect(described_class).to receive(:ensure_active_record_hooks_loaded)
        described_class.initialize_parallel_configuration(fake_parallel_config)
      end
    end
  end

  # Runtime skip rather than `:if:` metadata: on rspec-core 4.x, `:if:` no longer
  # filters example groups, so the tests inside would run and fail when the
  # parallel API is absent. The integration describe block below uses the same
  # pattern.
  describe "hook registration is idempotent" do
    let(:real_config) { RSpec::Core::Configuration.new }
    let(:fake_parallelization) { Module.new }

    before do
      unless described_class.parallel_api_available?(real_config) &&
             real_config.respond_to?(:fire_parallelize_setup_hooks) &&
             real_config.respond_to?(:fire_parallelize_teardown_hooks)
        skip "rspec-core parallel API unavailable"
      end
      described_class.reset_initialized_configs!
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)
      allow(described_class).to receive(:ensure_active_record_hooks_loaded)
      # Firing the setup hooks in-process must not leak per-worker state
      # (ENV, Capybara port, logger) into the host suite.
      allow(described_class).to receive(:assign_test_env_number)
      allow(described_class).to receive(:assign_parallel_worker_id)
      allow(described_class).to receive(:redirect_rails_logger)
      allow(described_class).to receive(:assign_capybara_port)
    end

    after { described_class.reset_initialized_configs! }

    it "calling initialize_parallel_configuration twice does not double-fire rails hooks" do
      call_log = []
      fake_parallelization.define_singleton_method(:after_fork_hooks) do
        [proc { |n| call_log << [:rails, n] }]
      end
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [] }

      described_class.initialize_parallel_configuration(real_config)
      described_class.initialize_parallel_configuration(real_config)
      real_config.fire_parallelize_setup_hooks(42)

      expect(call_log).to eq([[:rails, 42]])
    end

    it "does not register duplicate teardown delegators on repeat initialization" do
      call_log = []
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [] }
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) do
        [proc { |n| call_log << [:cleanup, n] }]
      end

      described_class.initialize_parallel_configuration(real_config)
      described_class.initialize_parallel_configuration(real_config)
      real_config.fire_parallelize_teardown_hooks(5)

      expect(call_log).to eq([[:cleanup, 5]])
    end

    it "does not re-require active_record/test_databases on repeat initialization" do
      expect(described_class).to receive(:ensure_active_record_hooks_loaded).once
      described_class.initialize_parallel_configuration(real_config)
      described_class.initialize_parallel_configuration(real_config)
    end
  end

  describe "hook fan-out" do
    let(:fake_parallelization) { Module.new }

    before do
      # Simulate ActiveSupport::Testing::Parallelization being loaded without
      # actually requiring Rails (keeps this spec isolated). We stub the
      # constant lookup used inside ParallelConfiguration.
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)
    end

    describe ".fire_before_fork_hooks" do
      it "invokes each registered before_fork_hook (no arguments, parent side)" do
        call_log = []
        fake_parallelization.define_singleton_method(:before_fork_hooks) do
          [proc { call_log << :a }, proc { call_log << :b }]
        end

        described_class.fire_before_fork_hooks

        expect(call_log).to eq([:a, :b])
      end

      it "is a no-op when Rails has no before_fork registry (pre-8.1)" do
        # fake_parallelization deliberately lacks .before_fork_hooks, mirroring
        # Rails 7.2/8.0 -- whose own Minitest parallelization performs no
        # pre-fork work either, so there is genuinely nothing to fire.
        expect { described_class.fire_before_fork_hooks }.not_to raise_error
      end

      it "is a no-op when Parallelization is not defined" do
        hide_const("ActiveSupport::Testing::Parallelization")
        expect { described_class.fire_before_fork_hooks }.not_to raise_error
      end
    end

    describe ".fire_after_fork_hooks" do
      it "invokes each registered after_fork_hook with the worker number" do
        call_log = []
        fake_parallelization.define_singleton_method(:after_fork_hooks) do
          [proc { |n| call_log << [:a, n] }, proc { |n| call_log << [:b, n] }]
        end

        described_class.fire_after_fork_hooks(3)

        expect(call_log).to eq([[:a, 3], [:b, 3]])
      end

      it "is a no-op when Parallelization is not defined" do
        hide_const("ActiveSupport::Testing::Parallelization")
        expect { described_class.fire_after_fork_hooks(0) }.not_to raise_error
      end

      context "when a hook fails (e.g. per-worker database creation)" do
        before do
          fake_parallelization.define_singleton_method(:after_fork_hooks) do
            [proc { |_n| raise ArgumentError, "could not create app_test-3" }]
          end
        end

        it "re-raises with worker attribution so the run fails loudly" do
          expect { described_class.fire_after_fork_hooks(3) }.to raise_error(
            RuntimeError,
            /rspec-rails parallel: worker 3 failed to prepare test database.*ArgumentError: could not create app_test-3/
          )
        end

        it "preserves the original exception as the cause" do
          described_class.fire_after_fork_hooks(3)
          raise "expected fire_after_fork_hooks to raise"
        rescue RuntimeError => e
          expect(e.cause).to be_an(ArgumentError)
          expect(e.cause.message).to eq("could not create app_test-3")
        end
      end
    end

    describe ".fire_cleanup_hooks" do
      it "invokes each registered run_cleanup_hook with the worker number" do
        call_log = []
        fake_parallelization.define_singleton_method(:run_cleanup_hooks) do
          [proc { |n| call_log << [:cleanup, n] }]
        end

        described_class.fire_cleanup_hooks(7)

        expect(call_log).to eq([[:cleanup, 7]])
      end

      it "is a no-op when Parallelization is not defined" do
        hide_const("ActiveSupport::Testing::Parallelization")
        expect { described_class.fire_cleanup_hooks(0) }.not_to raise_error
      end
    end
  end

  describe ".assign_test_env_number" do
    around do |example|
      had_value = ENV.key?("TEST_ENV_NUMBER")
      original  = ENV["TEST_ENV_NUMBER"]
      ENV.delete("TEST_ENV_NUMBER")
      example.run
    ensure
      had_value ? ENV["TEST_ENV_NUMBER"] = original : ENV.delete("TEST_ENV_NUMBER")
    end

    # parallel_tests default convention: first worker gets the empty string,
    # subsequent workers get "2", "3", ... so ecosystem tooling keyed off
    # TEST_ENV_NUMBER (SimpleCov, Redis namespacing, database.yml suffixes)
    # works unchanged.
    it "sets the empty string for worker 0" do
      described_class.assign_test_env_number(0)
      expect(ENV.fetch("TEST_ENV_NUMBER", :unset)).to eq("")
    end

    it "sets worker_number + 1 for later workers" do
      described_class.assign_test_env_number(1)
      expect(ENV["TEST_ENV_NUMBER"]).to eq("2")

      ENV.delete("TEST_ENV_NUMBER")
      described_class.assign_test_env_number(6)
      expect(ENV["TEST_ENV_NUMBER"]).to eq("7")
    end

    it "leaves a value already present in the environment alone" do
      ENV["TEST_ENV_NUMBER"] = "42"
      described_class.assign_test_env_number(0)
      expect(ENV["TEST_ENV_NUMBER"]).to eq("42")
    end

    it "treats a pre-existing empty string as already set" do
      ENV["TEST_ENV_NUMBER"] = ""
      described_class.assign_test_env_number(3)
      expect(ENV["TEST_ENV_NUMBER"]).to eq("")
    end
  end

  describe ".assign_parallel_worker_id" do
    it "sets ActiveSupport::TestCase.parallel_worker_id when the writer exists (Rails 8.1+)" do
      fake_test_case = Class.new do
        class << self
          attr_accessor :parallel_worker_id
        end
      end
      stub_const("ActiveSupport::TestCase", fake_test_case)

      described_class.assign_parallel_worker_id(5)

      expect(fake_test_case.parallel_worker_id).to eq(5)
    end

    it "is a no-op when the writer is absent (pre-8.1)" do
      stub_const("ActiveSupport::TestCase", Class.new)
      expect { described_class.assign_parallel_worker_id(5) }.not_to raise_error
    end

    it "is a no-op when ActiveSupport::TestCase is not defined" do
      hide_const("ActiveSupport::TestCase") if defined?(::ActiveSupport::TestCase)
      expect { described_class.assign_parallel_worker_id(5) }.not_to raise_error
    end
  end

  describe ".assign_capybara_port" do
    context "when Capybara is not loaded" do
      before { allow(described_class).to receive(:capybara_defined?).and_return(false) }

      it "is a silent no-op (does not touch Capybara)" do
        # We don't even try to look up the Capybara constant, since rspec-rails
        # apps without system/feature specs may not have it loaded at all.
        expect(::Capybara).not_to receive(:server_port=)
        expect { described_class.assign_capybara_port(0) }.not_to raise_error
      end
    end

    context "when Capybara is loaded" do
      let(:original_port) { ::Capybara.server_port }

      before do
        original_port # capture before any assignment
        ::Capybara.server_port = nil
      end

      after { ::Capybara.server_port = original_port }

      it "assigns dense per-worker ports: base + worker_number" do
        # Each assignment happens once per freshly forked worker, where
        # Capybara.server_port is still nil; reset between calls to mirror
        # that (a non-nil port at hook time means the user pinned it).
        described_class.assign_capybara_port(0)
        expect(::Capybara.server_port).to eq(9000)

        ::Capybara.server_port = nil
        described_class.assign_capybara_port(1)
        expect(::Capybara.server_port).to eq(9001)

        # Stays valid even on very wide CI boxes (worker 57 used to
        # overflow the old band scheme past 65535).
        ::Capybara.server_port = nil
        described_class.assign_capybara_port(57)
        expect(::Capybara.server_port).to eq(9057)
      end

      it "honors RSpec.configuration.parallel_server_port_base" do
        allow(RSpec.configuration).to receive(:parallel_server_port_base).and_return(20_000)
        described_class.assign_capybara_port(2)
        expect(::Capybara.server_port).to eq(20_002)
      end

      it "raises when the computed port would exceed the maximum TCP port" do
        allow(RSpec.configuration).to receive(:parallel_server_port_base).and_return(65_530)

        expect { described_class.assign_capybara_port(6) }.to raise_error(
          ArgumentError, /port 65536.*exceeds the maximum TCP port/m
        )
        expect(::Capybara.server_port).to be_nil
      end

      context "when the user has pinned Capybara.server_port" do
        before { ::Capybara.server_port = 4321 }

        it "leaves the user's port untouched" do
          allow(RSpec).to receive(:warn_with)
          described_class.assign_capybara_port(1)
          expect(::Capybara.server_port).to eq(4321)
        end

        it "warns once (from worker 0 only) about the cross-worker collision" do
          expect(RSpec).to receive(:warn_with).with(/Capybara\.server_port is explicitly set to 4321/).once

          described_class.assign_capybara_port(0)
          described_class.assign_capybara_port(1)
          described_class.assign_capybara_port(2)
        end
      end
    end
  end

  describe ".redirect_rails_logger" do
    context "when Rails is not loaded" do
      before { allow(described_class).to receive(:rails_logger_available?).and_return(false) }

      it "is a silent no-op" do
        expect { described_class.send(:redirect_rails_logger, 0) }.not_to raise_error
      end
    end

    context "when Rails is loaded" do
      let(:tmpdir) { Dir.mktmpdir("rspec-rails-parallel-log-") }
      let(:rails_double) { double("Rails", root: Pathname.new(tmpdir), logger: original_logger) }
      let(:original_logger) do
        ActiveSupport::TaggedLogging.new(
          ActiveSupport::Logger.new(File::NULL).tap do |l|
            l.level = ::Logger::WARN
            l.formatter = ->(_, _, _, msg) { "fmt:#{msg}\n" }
          end
        )
      end

      before do
        stub_const("Rails", rails_double)
        allow(rails_double).to receive(:logger=) { |new| allow(rails_double).to receive(:logger).and_return(new) }
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "writes the worker's log to log/test-<worker>.log under Rails.root" do
        described_class.send(:redirect_rails_logger, 3)
        ::Rails.logger.warn("hello from worker 3")
        ::Rails.logger.close if ::Rails.logger.respond_to?(:close)

        expected = File.join(tmpdir, "log", "test-3.log")
        expect(File.exist?(expected)).to be true
        expect(File.read(expected)).to include("hello from worker 3")
      end

      it "creates log/ under Rails.root if it does not already exist" do
        expect(Dir.exist?(File.join(tmpdir, "log"))).to be false
        described_class.send(:redirect_rails_logger, 0)
        expect(Dir.exist?(File.join(tmpdir, "log"))).to be true
      end

      it "preserves the formatter and level from the previous logger" do
        described_class.send(:redirect_rails_logger, 1)
        # TaggedLogging wraps, so reach through to the wrapped logger:
        wrapped = ::Rails.logger.instance_variable_get(:@logger) || ::Rails.logger
        expect(wrapped.level).to eq(::Logger::WARN)
        expect(wrapped.formatter.call(nil, nil, nil, "x")).to eq("fmt:x\n")
      end

      # Framework components (ActiveRecord::Base & co.) capture the boot-time
      # logger by reference (`self.logger ||= ::Rails.logger` in railtie
      # on_load hooks). With a non-broadcast logger the only way to reroute
      # their output is to reassign each component that still points at the
      # old instance.
      it "reassigns framework component loggers that pointed at the old Rails.logger" do
        component = Class.new do
          class << self
            attr_accessor :logger
          end
        end
        component.logger = original_logger
        stub_const("ActiveRecord::Base", component)

        described_class.send(:redirect_rails_logger, 2)

        expect(component.logger).to equal(::Rails.logger)
        component.logger.warn("sql from worker 2")
        component.logger.close if component.logger.respond_to?(:close)
        expect(File.read(File.join(tmpdir, "log", "test-2.log"))).to include("sql from worker 2")
      end

      it "leaves a component's dedicated custom logger alone" do
        custom = ::ActiveSupport::Logger.new(File::NULL)
        component = Class.new do
          class << self
            attr_accessor :logger
          end
        end
        component.logger = custom
        stub_const("ActiveRecord::Base", component)

        described_class.send(:redirect_rails_logger, 2)

        expect(component.logger).to equal(custom)
      end
    end

    context "when Rails.logger is an ActiveSupport::BroadcastLogger" do
      let(:tmpdir) { Dir.mktmpdir("rspec-rails-parallel-log-") }
      let(:shared_log_path) { File.join(tmpdir, "log", "test.log") }
      let(:original_sink) do
        FileUtils.mkdir_p(File.dirname(shared_log_path))
        ::ActiveSupport::Logger.new(shared_log_path).tap { |l| l.level = ::Logger::INFO }
      end
      let(:original_logger) { ::ActiveSupport::BroadcastLogger.new(original_sink) }
      let(:rails_double) { double("Rails", root: Pathname.new(tmpdir), logger: original_logger) }

      before do
        stub_const("Rails", rails_double)
        allow(rails_double).to receive(:logger=) { |new| allow(rails_double).to receive(:logger).and_return(new) }
      end

      after { FileUtils.remove_entry(tmpdir) }

      it "swaps the sinks in place so every captured reference reroutes at once" do
        # AR/AC/AJ captured this exact object at boot; identity must survive.
        described_class.send(:redirect_rails_logger, 4)

        expect(::Rails.logger).to equal(original_logger)
        expect(original_logger.broadcasts).not_to include(original_sink)
        expect(original_logger.broadcasts.size).to eq(1)
      end

      it "routes writes through a boot-captured reference into the per-worker file only" do
        captured_by_component_at_boot = original_logger

        described_class.send(:redirect_rails_logger, 4)
        captured_by_component_at_boot.info("select * from posts")
        original_logger.broadcasts.each { |sink| sink.close if sink.respond_to?(:close) }

        worker_log = File.join(tmpdir, "log", "test-4.log")
        expect(File.read(worker_log)).to include("select * from posts")
        expect(File.read(shared_log_path)).not_to include("select * from posts")
      end

      it "inherits level from the original sink" do
        described_class.send(:redirect_rails_logger, 4)
        expect(original_logger.broadcasts.first.level).to eq(::Logger::INFO)
      end
    end
  end

  # Round-trip against the real rspec-core parallel API (only present on
  # rspec-core versions that ship the parallel runner — runtime skip so this
  # works on both rspec-core 3.x (where `:if` metadata still filters) and
  # rspec-core 4.x (where it does not).
  describe "integration with real RSpec::Core::Configuration" do
    let(:real_config) { RSpec::Core::Configuration.new }
    let(:fake_parallelization) { Module.new }

    before do
      unless described_class.parallel_api_available?(real_config) &&
             real_config.respond_to?(:fire_parallelize_setup_hooks) &&
             real_config.respond_to?(:fire_parallelize_teardown_hooks)
        skip "rspec-core parallel API unavailable"
      end
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)
      allow(described_class).to receive(:ensure_active_record_hooks_loaded)
      # Firing the setup hooks in-process must not leak per-worker state
      # (ENV, Capybara port, logger) into the host suite.
      allow(described_class).to receive(:assign_test_env_number)
      allow(described_class).to receive(:assign_parallel_worker_id)
      allow(described_class).to receive(:redirect_rails_logger)
      allow(described_class).to receive(:assign_capybara_port)
    end

    it "fires registered before_fork hooks on the parent via the real config surface" do
      unless real_config.respond_to?(:parallelize_before_fork) &&
             real_config.respond_to?(:fire_parallelize_before_fork_hooks)
        skip "rspec-core parallelize_before_fork API unavailable"
      end

      call_log = []
      fake_parallelization.define_singleton_method(:before_fork_hooks) { [proc { call_log << :before_fork }] }

      described_class.initialize_parallel_configuration(real_config)
      real_config.fire_parallelize_before_fork_hooks

      expect(call_log).to eq([:before_fork])
    end

    it "fires registered setup hooks with the worker number via the real config surface" do
      call_log = []
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [proc { |n| call_log << [:setup, n] }] }

      described_class.initialize_parallel_configuration(real_config)
      real_config.fire_parallelize_setup_hooks(2)

      expect(call_log).to eq([[:setup, 2]])
    end

    it "fires registered teardown hooks with the worker number via the real config surface" do
      call_log = []
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [proc { |n| call_log << [:teardown, n] }] }

      described_class.initialize_parallel_configuration(real_config)
      real_config.fire_parallelize_teardown_hooks(4)

      expect(call_log).to eq([[:teardown, 4]])
    end

    it "accumulates with user-registered parallelize_setup blocks (does not stomp)" do
      call_log = []
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [proc { |n| call_log << [:rails_hook, n] }] }

      described_class.initialize_parallel_configuration(real_config)
      real_config.parallelize_setup { |n| call_log << [:user_hook, n] }
      real_config.fire_parallelize_setup_hooks(1)

      expect(call_log).to contain_exactly([:rails_hook, 1], [:user_hook, 1])
    end

    it "fires Rails after_fork_hooks before any user-registered parallelize_setup block" do
      call_log = []
      fake_parallelization.define_singleton_method(:after_fork_hooks) do
        [proc { |n| call_log << [:rails, n] }]
      end
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [] }

      described_class.initialize_parallel_configuration(real_config)
      real_config.parallelize_setup { |n| call_log << [:user, n] }
      real_config.fire_parallelize_setup_hooks(0)

      expect(call_log).to eq([[:rails, 0], [:user, 0]])
    end

    it "fires Rails run_cleanup_hooks before any user-registered parallelize_teardown block" do
      call_log = []
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) do
        [proc { |n| call_log << [:rails, n] }]
      end

      described_class.initialize_parallel_configuration(real_config)
      real_config.parallelize_teardown { |n| call_log << [:user, n] }
      real_config.fire_parallelize_teardown_hooks(0)

      expect(call_log).to eq([[:rails, 0], [:user, 0]])
    end
  end

  describe ".ensure_active_record_hooks_loaded",
           if: defined?(::ActiveRecord) do
    it "loads ActiveRecord::TestDatabases so its fork hooks register" do
      described_class.send(:ensure_active_record_hooks_loaded)
      expect(defined?(::ActiveRecord::TestDatabases)).to be_truthy
    end

    # Rails 8.1+ gates ActiveRecord::TestDatabases' fork hooks on
    # `ActiveSupport.parallelize_test_databases`, which already defaults to
    # `true`. Assigning it here would clobber the documented app-level
    # opt-out (`config.active_support.parallelize_test_databases = false`)
    # and mutate global state even for serial runs, so we must never write
    # to it.
    it "never assigns ActiveSupport.parallelize_test_databases" do
      captured = []
      if ::ActiveSupport.respond_to?(:parallelize_test_databases=)
        # Rails 8.1+: rspec-mocks avoids the "method redefined" warning that
        # `define_method` would emit on the real singleton method.
        allow(::ActiveSupport).to receive(:parallelize_test_databases=) { |v| captured << v }
        described_class.send(:ensure_active_record_hooks_loaded)
      else
        # Pre-Rails 8.1: install a shim so an (unwanted) assignment would be
        # captured, then strip it.
        ::ActiveSupport.singleton_class.send(:define_method, :parallelize_test_databases=) { |v| captured << v }
        begin
          described_class.send(:ensure_active_record_hooks_loaded)
        ensure
          ::ActiveSupport.singleton_class.send(:remove_method, :parallelize_test_databases=)
        end
      end
      expect(captured).to be_empty
    end

    it "preserves an app-level opt-out of parallelize_test_databases" do
      unless ::ActiveSupport.respond_to?(:parallelize_test_databases=)
        skip "Rails < 8.1 has no parallelize_test_databases accessor"
      end

      original = ::ActiveSupport.parallelize_test_databases
      begin
        ::ActiveSupport.parallelize_test_databases = false
        described_class.send(:ensure_active_record_hooks_loaded)
        expect(::ActiveSupport.parallelize_test_databases).to be(false)
      ensure
        ::ActiveSupport.parallelize_test_databases = original
      end
    end
  end

  # Locks in the contract we rely on from ActiveRecord::TestDatabases: when
  # fired with a worker_number, its create_and_load_schema iterates over every
  # configuration returned by `configs_for(env_name: ...)` and suffixes the
  # database name per worker. If Rails ever changes shape here, our
  # per-worker multi-DB behavior would silently regress.
  describe "ActiveRecord multi-database per-worker suffixing",
           if: defined?(::ActiveRecord) do
    before { require "active_record/test_databases" }

    let(:primary)   { double("HashConfig-primary",   database: "app_test") }
    let(:secondary) { double("HashConfig-secondary", database: "app_analytics_test") }
    let(:configs)   { instance_double("ActiveRecord::DatabaseConfigurations") }

    before do
      [primary, secondary].each do |c|
        allow(c).to receive(:_database=)
        # Rails 8.1+ gates the schema reconstruction on `database_tasks?`.
        # Older Rails versions don't call it; the stub is harmless there.
        allow(c).to receive(:database_tasks?).and_return(true)
      end
      # Rails 8.1+ passes `include_hidden: true`; earlier Rails does not.
      allow(configs).to receive(:configs_for).with(hash_including(env_name: "test")).and_return([primary, secondary])
      allow(ActiveRecord::Base).to receive(:configurations).and_return(configs)
      allow(ActiveRecord::Base).to receive(:establish_connection)
      allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:reconstruct_from_schema)
    end

    it "suffixes each configured database with the worker number" do
      ActiveRecord::TestDatabases.create_and_load_schema(1, env_name: "test")

      expect(primary).to have_received(:_database=).with(a_string_matching(/app_test[-_]1/))
      expect(secondary).to have_received(:_database=).with(a_string_matching(/app_analytics_test[-_]1/))
    end

    it "reconstructs the schema for every configured database" do
      # Rails signature has varied: 7.2 passes (config, format, spec_name),
      # 8.0+ drops `format`. We only care that each configured DB was seen.
      seen_configs = []
      allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:reconstruct_from_schema) do |cfg, *|
        seen_configs << cfg
      end

      ActiveRecord::TestDatabases.create_and_load_schema(2, env_name: "test")

      expect(seen_configs).to contain_exactly(primary, secondary)
    end
  end

  # Real-fork end-to-end: drive rspec-core's Parallel::Runner with two
  # workers, with a Rails-style after_fork_hook registered. Each worker
  # writes a file from inside its parallelize_setup callback; the parent
  # asserts the files exist with the right worker_number. Runtime skip
  # handles platforms without fork() and rspec-core versions without the
  # parallel runner, on both rspec-core 3.x and 4.x (`:if` metadata does
  # not filter groups on 4.x).
  describe "real-fork run with Parallel::Runner" do
    require 'tmpdir'
    require 'fileutils'
    require 'timeout'

    before do
      skip "Process.fork unavailable"                unless Process.respond_to?(:fork)
      skip "rspec-core parallel runner unavailable"  unless defined?(RSpec::Core::Parallel::Runner)

      # Other specs in this suite may leak a Capybara.server_port (e.g.
      # system spec `served_by` examples). Forked workers would then treat
      # it as a user-pinned port and emit the collision warning, which
      # rspec-support's spec harness escalates into a failure inside the
      # worker. Fork from a clean slate; restored below.
      if defined?(::Capybara)
        @saved_capybara_server_port = ::Capybara.server_port
        ::Capybara.server_port = nil
      end
    end

    after do
      ::Capybara.server_port = @saved_capybara_server_port if defined?(::Capybara)
    end

    let(:tmpdir)    { Dir.mktmpdir("rspec-rails-parallel") }
    let(:setup_log) { File.join(tmpdir, "setup.log") }

    after { FileUtils.rm_rf(tmpdir) }

    def with_isolated_rspec_state
      saved_config = RSpec.configuration
      saved_world  = RSpec.instance_variable_get(:@world)
      yield
    ensure
      RSpec.instance_variable_set(:@configuration, saved_config)
      RSpec.instance_variable_set(:@world, saved_world)
    end

    def build_quiet_configuration
      config = RSpec::Core::Configuration.new
      config.output_stream = StringIO.new
      config.error_stream  = StringIO.new
      config.color_mode    = :off
      config.formatter     = 'progress'
      config
    end

    it "fires Rails-registered after_fork_hooks inside each worker with the right worker_number" do
      log = setup_log
      before_fork_log = File.join(tmpdir, "before_fork.log")
      fake_parallelization = Module.new
      fake_parallelization.define_singleton_method(:after_fork_hooks) do
        [proc { |n| File.open(log, "a") { |f| f.puts "rails-hook:worker:#{n}:#{Process.pid}" } }]
      end
      fake_parallelization.define_singleton_method(:before_fork_hooks) do
        [proc { File.open(before_fork_log, "a") { |f| f.puts "before-fork:#{Process.pid}" } }]
      end
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [] }
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)

      with_isolated_rspec_state do
        config = build_quiet_configuration
        world  = RSpec::Core::World.new(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        allow(described_class).to receive(:ensure_active_record_hooks_loaded)
        described_class.reset_initialized_configs!
        described_class.initialize_parallel_configuration(config)

        group_a = RSpec::Core::ExampleGroup.describe("A") { it("a") {} }
        group_b = RSpec::Core::ExampleGroup.describe("B") { it("b") {} }
        [group_a, group_b].each { |g| world.record(g) }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = RSpec::Core::Parallel::Runner.new(config, world, 2)
        exit_code = runner.run_specs([group_a, group_b])

        expect(exit_code).to eq(0)

        lines = File.readlines(setup_log)
        expect(lines.size).to eq(2)
        expect(lines.map { |l| l[/worker:(\d)/, 1] }.sort).to eq(%w[0 1])

        # before_fork hooks fire exactly once, on the parent process,
        # before any worker forks (Rails 8.1 registry bridged via
        # rspec-core's parallelize_before_fork).
        if RSpec.configuration.respond_to?(:parallelize_before_fork)
          before_fork_lines = File.readlines(before_fork_log).map(&:strip)
          expect(before_fork_lines).to eq(["before-fork:#{Process.pid}"])
        end
      end
    end

    it "lets two workers assigned distinct Capybara ports each bind a TCP server" do
      skip "capybara not loaded" unless defined?(::Capybara)
      require "socket"

      log = File.join(tmpdir, "ports.log")
      fake_parallelization = Module.new
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [] }
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [] }
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)

      with_isolated_rspec_state do
        config = build_quiet_configuration
        world  = RSpec::Core::World.new(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        allow(described_class).to receive(:ensure_active_record_hooks_loaded)
        described_class.reset_initialized_configs!
        described_class.initialize_parallel_configuration(config)

        config.parallelize_setup do |n|
          port = ::Capybara.server_port
          begin
            server = TCPServer.new("127.0.0.1", port)
            server.close
          rescue Errno::EADDRINUSE
            # The deterministic port happened to be in use on the host;
            # the rspec-rails assignment still succeeded, which is what
            # this spec cares about. Log the port unconditionally.
          end
          File.open(log, "a") { |f| f.puts "worker:#{n}:port:#{port}" }
        end

        group_a = RSpec::Core::ExampleGroup.describe("A") { it("a") {} }
        group_b = RSpec::Core::ExampleGroup.describe("B") { it("b") {} }
        [group_a, group_b].each { |g| world.record(g) }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = RSpec::Core::Parallel::Runner.new(config, world, 2)
        exit_code = runner.run_specs([group_a, group_b])

        expect(exit_code).to eq(0)

        lines = File.readlines(log).map(&:strip)
        expect(lines.size).to eq(2)

        ports_by_worker = lines.each_with_object({}) do |line, acc|
          acc[line[/worker:(\d)/, 1]] = line[/port:(\d+)/, 1].to_i
        end

        expect(ports_by_worker.values.uniq.size).to eq(2)
        expect(ports_by_worker["0"]).to eq(9000)
        expect(ports_by_worker["1"]).to eq(9001)
      end
    end

    it "fires parallelize_teardown hooks even when a worker's example fails" do
      log = File.join(tmpdir, "cleanup.log")
      fake_parallelization = Module.new
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [] }
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) do
        [proc { |n| File.open(log, "a") { |f| f.puts "cleanup:#{n}" } }]
      end
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)

      with_isolated_rspec_state do
        config = build_quiet_configuration
        world  = RSpec::Core::World.new(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        allow(described_class).to receive(:ensure_active_record_hooks_loaded)
        described_class.reset_initialized_configs!
        described_class.initialize_parallel_configuration(config)

        failing = RSpec::Core::ExampleGroup.describe("boom") { it("fails") { raise "nope" } }
        world.record(failing)
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = RSpec::Core::Parallel::Runner.new(config, world, 1)
        exit_code = runner.run_specs([failing])

        expect(exit_code).not_to eq(0)
        expect(File.read(log)).to match(/cleanup:0/)
      end
    end

    it "returns non-zero exit when a worker's example group raises in before(:all)" do
      fake_parallelization = Module.new
      fake_parallelization.define_singleton_method(:after_fork_hooks) { [] }
      fake_parallelization.define_singleton_method(:run_cleanup_hooks) { [] }
      stub_const("ActiveSupport::Testing::Parallelization", fake_parallelization)

      with_isolated_rspec_state do
        config = build_quiet_configuration
        world  = RSpec::Core::World.new(config)
        RSpec.instance_variable_set(:@configuration, config)
        RSpec.instance_variable_set(:@world, world)

        allow(described_class).to receive(:ensure_active_record_hooks_loaded)
        described_class.reset_initialized_configs!
        described_class.initialize_parallel_configuration(config)

        boom = RSpec::Core::ExampleGroup.describe("boom") do
          before(:all) { raise "top-level boom" }
          it("is never reached") {}
        end
        okay = RSpec::Core::ExampleGroup.describe("okay") { it("passes") {} }
        [boom, okay].each { |g| world.record(g) }
        world.instance_variable_set(:@example_groups_and_filters_loaded, true)

        runner = RSpec::Core::Parallel::Runner.new(config, world, 2)
        exit_code = Timeout.timeout(30) { runner.run_specs([boom, okay]) }

        expect(exit_code).not_to eq(0)
      end
    end
  end
end
