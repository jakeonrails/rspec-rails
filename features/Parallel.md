# Parallel testing

rspec-rails integrates with Rails' built-in parallel testing machinery:
each worker gets its own database, its own log file, and its own Capybara
port. The rspec-facing API lives inside `RSpec.configure` alongside every
other rspec-rails knob — you don't configure behavior on
`ActiveSupport::TestCase`.

## Quick start

Uncomment the parallel block that `rails generate rspec:install` puts in
`spec/rails_helper.rb` (or add it to an existing project):

```ruby
RSpec.configure do |config|
  if config.respond_to?(:default_parallel_workers=) && Process.respond_to?(:fork)
    config.default_parallel_workers = :number_of_processors
  end
end
```

With that set, `bundle exec rspec` forks a worker per CPU, creates a
per-worker database, and runs the suite. Before flipping it on, read
"Known interactions" below — especially the `before(:suite)` note.

## Invocation

```sh
bundle exec rspec                  # parallel when default_parallel_workers is set
bundle exec rspec --parallel 4     # 4 workers
bundle exec rspec --parallel       # default_parallel_workers, or processor count
bundle exec rspec --parallel 1     # force single-process
bundle exec rspec --no-parallel    # force single-process
PARALLEL_WORKERS=8 bundle exec rspec
```

Precedence, highest first: CLI flag, `PARALLEL_WORKERS` env,
`parallel_workers` config, `default_parallel_workers` config. A worker
count of 0 or 1 means single-process. Bare `--parallel` uses
`default_parallel_workers` when set, otherwise the processor count.
On platforms without `fork` (Windows, JRuby), requesting parallel warns
once and runs serially.

Inside a spec, the current worker number (or `nil` outside parallel) is
readable via `RSpec.parallel_worker_number`.

## What rspec-rails wires for you

`require "rspec/rails"` installs the parallel bridge automatically. When a
parallel run forks workers, each worker (numbered from 0):

1. **Gets its own database.** `ActiveRecord::TestDatabases`' after-fork
   hook creates and loads a per-worker copy of every configuration in
   `config/database.yml` — named `<database>_<worker_number>` on
   Rails 8.1+, `<database>-<worker_number>` on Rails 8.0 and earlier.
   Multi-database setups (primary, replica, secondary) all get per-worker
   copies. Rails 8.1's `config.active_support.parallelize_test_databases
   = false` opt-out is respected. If per-worker database setup fails, the
   run fails loudly with the worker number in the error instead of
   degrading into workers that share one database.
2. **Writes to its own log file.** Logging is redirected to
   `log/test-<worker_number>.log`, preserving the parent logger's
   formatter and level. When `Rails.logger` is a `BroadcastLogger` (the
   Rails default), its sinks are swapped in place, so framework
   components that captured the logger at boot reroute too. `log/test.log`
   no longer interleaves; debug with `tail -f log/test-*.log`.
3. **Gets its own Capybara port.** When Capybara is loaded and
   `Capybara.server_port` is nil (its default), each worker is assigned
   `parallel_server_port_base + worker_number` (9000, 9001, ... by
   default; the base is configurable via
   `RSpec.configuration.parallel_server_port_base`). If you have pinned
   `Capybara.server_port` yourself, rspec-rails leaves it alone and warns
   once — a single shared port cannot work across workers, so remove the
   assignment to let each worker get its own.
4. **Sets `TEST_ENV_NUMBER`** using the parallel_tests convention: `""`
   for worker 0, `"2"`, `"3"`, ... for the rest. Tooling keyed off it
   (Redis/Elasticsearch namespacing, `database.yml` suffixes) works
   unchanged. A value already present in the environment — even an empty
   string — is left alone.
5. **Sets `ActiveSupport::TestCase.parallel_worker_id`** (0-indexed) on
   Rails versions that support it, matching Rails' own Minitest workers.

On Rails 8.1+, `ActiveSupport::Testing::Parallelization.before_fork_hooks`
fire in the parent before forking (ActiveRecord uses this to clear
connections for mysql2 fork-safety). Earlier Rails versions have no
before-fork registry and need no pre-fork work.

## Custom per-worker setup

Register per-worker setup on the rspec configuration — the same place you
set every other rspec-rails knob:

```ruby
RSpec.configure do |config|
  config.parallelize_setup do |worker|
    # Redis namespacing, tmpfile dirs, extra service connections, etc.
  end

  config.parallelize_teardown do |worker|
    # per-worker cleanup.
  end
end
```

These blocks run once per worker, post-fork, before any examples in that
worker execute. Rails' own after-fork hooks (including per-worker database
creation) run first, so your setup block sees a live connection to the
worker's database.

### Compatibility with `ActiveSupport::TestCase.parallelize_setup`

Blocks registered against Rails' own parallelization hook registry are
also fired inside each rspec worker:

```ruby
ActiveSupport::TestCase.parallelize_setup do |worker|
  # ...
end
```

This is useful when you share setup code with a Minitest suite, or are
migrating from one. In new rspec-only code, prefer
`config.parallelize_setup`.

## Skipping the boot-time truncate

When a worker boots and its per-worker database already exists with an
up-to-date schema, Rails truncates every table in it so the run starts
from a clean slate. With `config.use_transactional_fixtures = true` (the
rspec-rails default), every example already rolls back its own
transaction, so that boot-time truncation is redundant — and slow on
large schemas. Opt out with:

```ruby
ENV['SKIP_TEST_DATABASE_TRUNCATE'] ||= '1'
```

The generated `rails_helper.rb` includes a commented-out line for this.
Caveat: skipping the truncate means rows committed outside a transaction
by a *previous* run — one that aborted mid-suite, or examples that
deliberately commit — survive into the next run. Leave truncation on if
you're not using transactional fixtures or your suite commits data.

## Known interactions

### `before(:suite)` seeding does not reach workers

This is the most common silent trap. `before(:suite)` runs once, in the
parent process, before workers fork — but each worker creates (or
truncates) its own database *after* forking, so anything the parent
seeded is not in any worker's database. Move suite-level seeding into
`parallelize_setup`:

```ruby
RSpec.configure do |config|
  # Before: runs in the parent; workers never see this data.
  # config.before(:suite) { Rails.application.load_seed }

  # After: runs once per worker, against that worker's database.
  config.parallelize_setup do |worker|
    Rails.application.load_seed
  end
end
```

### SimpleCov

Forked workers that exit with the same `command_name` overwrite each
other's results instead of merging. Note that SimpleCov's automatic
parallel detection requires *both* `TEST_ENV_NUMBER` and
`PARALLEL_TEST_GROUPS` in the environment; rspec-rails sets only
`TEST_ENV_NUMBER`, so don't rely on it. Two working recipes:

```ruby
# Option 1: let SimpleCov hook Process.fork itself (SimpleCov >= 0.21).
SimpleCov.enable_for_subprocesses true
SimpleCov.start "rails"
```

```ruby
# Option 2: give each worker a unique command_name.
RSpec.configure do |config|
  config.parallelize_setup do |worker|
    SimpleCov.command_name "rspec-worker-#{worker}"
  end
end
```

### Formatters, JUnit XML, and CI reports

Formatters run in the parent process only: workers stream their results
back, and the parent replays them through your configured formatters as
each group finishes. You get *one* merged output — one JUnit XML file, one
JSON document, one progress bar — with no interleaving and no post-run
merge step, unlike shell-out parallelizers that produce N files per run.
Custom formatters see serialized copies of examples rather than the
original objects, which is transparent for typical formatters.

### Spring and bootsnap

Untested in combination with parallel runs. bootsnap is expected to work
(it only caches load paths and compiled ISeq). Spring preloads the app in
a long-lived process with its own fork model; if you see stale code or
hook weirdness, run with `DISABLE_SPRING=1` before reporting bugs.

### VCR / WebMock

Replaying existing cassettes is safe — workers only read them. Recording
(`record: :new_episodes` / `:all`, or a first run with `:once`) can race:
multiple workers writing the same cassette file corrupt or clobber it.
Record cassettes in a single-process run (`--no-parallel`), then run
parallel against the recorded set.

### Migrating from parallel_tests

`TEST_ENV_NUMBER` follows the parallel_tests default convention
(`""`/`"2"`/`"3"`...), so per-worker resource naming keyed off it carries
over unchanged. Things to remove when cutting over:

1. `bundle remove parallel_tests`; delete `.rspec_parallel` and
   `bin/parallel_rspec`.
2. Drop `#{ENV['TEST_ENV_NUMBER']}` suffixes from `database.yml` — Rails
   creates the per-worker databases itself under a different naming
   scheme (`<database>_<worker_number>` on 8.1+).
3. Remove manual `Capybara.server_port` assignments; rspec-rails assigns
   per-worker ports (and will warn rather than clobber if you keep one).
4. Set `config.default_parallel_workers` in `rails_helper.rb`, or pass
   `--parallel` explicitly.

## When parallelism is a no-op

- `--no-parallel` / `--parallel 1` / no configured workers: no hooks
  fire, no per-worker resources are allocated, nothing changes.
- Platforms without `fork` (Windows, JRuby): a requested parallel run
  warns once and runs serially.
- rspec-core versions without the parallel runner: the bridge is a no-op
  at load time; `--parallel` is unrecognized.
