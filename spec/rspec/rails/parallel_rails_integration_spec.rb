require "fileutils"
require "shellwords"

# End-to-end integration: boot a real Rails app, run it under
# `rspec --parallel 2`, and assert per-worker SQLite databases were
# created and per-worker logs received the SQL. Opted in via
# RSPEC_RAILS_FULL_INTEGRATION=1 because the `bundle install` +
# two-worker run is slow relative to the rest of the suite.
RSpec.describe "rspec-rails parallel end-to-end with a real Rails app" do
  let(:app_path) { File.expand_path("../../fixtures/parallel_app", __dir__) }

  # The fixture app must resolve rspec-core & friends from the exact same
  # monorepo checkout this suite runs against -- never from a default
  # sibling path that may point at a different (or stale) checkout.
  let(:monorepo_path) do
    core_path = Gem.loaded_specs["rspec-core"]&.full_gem_path
    raise "cannot locate the rspec-core this suite is running against" unless core_path

    File.expand_path("..", core_path)
  end

  before do
    skip "set RSPEC_RAILS_FULL_INTEGRATION=1 to run" unless ENV["RSPEC_RAILS_FULL_INTEGRATION"]
    skip "fork() unavailable on this platform"       unless Process.respond_to?(:fork)

    FileUtils.rm_f(Dir[File.join(app_path, "db", "*.sqlite3*")])
    FileUtils.rm_f(Dir[File.join(app_path, "log", "*.log")])
    FileUtils.rm_f(File.join(app_path, "Gemfile.lock"))
  end

  def env_prefix
    "RSPEC_MONOREPO_PATH=#{Shellwords.escape(monorepo_path)}"
  end

  def run!(cmd)
    output = `#{env_prefix} #{cmd} 2>&1`
    raise "command failed (#{$?.exitstatus}): #{cmd}\n#{output}" unless $?.success?

    output
  end

  it "creates a per-worker SQLite database, redirects SQL to per-worker logs, and both workers succeed" do
    Bundler.with_unbundled_env do
      Dir.chdir(app_path) do
        run!("bundle install --quiet")
        output = `#{env_prefix} bundle exec rspec --parallel=2 2>&1`
        expect($?.exitstatus).to eq(0), "rspec --parallel=2 failed:\n#{output}"

        sqlite_files = Dir["db/test*.sqlite3*"].grep(/[-_]\d+(\.sqlite3)?\z/)
        expect(sqlite_files.size).to eq(2), "expected 2 per-worker DBs, got #{Dir['db/*'].inspect}"

        # The logger redirect must reroute component loggers too:
        # ActiveRecord captured the boot logger by reference, so SQL landing
        # in log/test-N.log (and NOT in the shared log/test.log) proves the
        # per-worker redirect actually took effect for AR.
        worker_logs = Dir["log/test-[0-9]*.log"]
        expect(worker_logs.size).to eq(2), "expected 2 per-worker logs, got #{Dir['log/*'].inspect}"

        worker_log_contents = worker_logs.map { |f| File.read(f) }.join
        expect(worker_log_contents).to match(/SELECT COUNT/i),
                                       "expected per-worker logs to contain the Post.count SQL"

        shared_log = "log/test.log"
        if File.exist?(shared_log)
          expect(File.read(shared_log)).not_to match(/SELECT COUNT/i),
                                               "Post.count SQL leaked into the shared log/test.log"
        end
      end
    end
  end
end
