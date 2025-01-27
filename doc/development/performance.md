# Performance Guidelines

This document describes various guidelines to follow to ensure good and
consistent performance of GitLab.

## Workflow

The process of solving performance problems is roughly as follows:

1. Make sure there's an issue open somewhere (for example, on the GitLab CE issue
   tracker), and create one if there is not. See [#15607](https://gitlab.com/gitlab-org/gitlab-foss/-/issues/15607) for an example.
1. Measure the performance of the code in a production environment such as
   GitLab.com (see the [Tooling](#tooling) section below). Performance should be
   measured over a period of _at least_ 24 hours.
1. Add your findings based on the measurement period (screenshots of graphs,
   timings, etc) to the issue mentioned in step 1.
1. Solve the problem.
1. Create a merge request, assign the "Performance" label and follow the [performance review process](merge_request_performance_guidelines.md).
1. Once a change has been deployed make sure to _again_ measure for at least 24
   hours to see if your changes have any impact on the production environment.
1. Repeat until you're done.

When providing timings make sure to provide:

- The 95th percentile
- The 99th percentile
- The mean

When providing screenshots of graphs, make sure that both the X and Y axes and
the legend are clearly visible. If you happen to have access to GitLab.com's own
monitoring tools you should also provide a link to any relevant
graphs/dashboards.

## Tooling

GitLab provides built-in tools to help improve performance and availability:

- [Profiling](profiling.md).
- [Distributed Tracing](distributed_tracing.md)
- [GitLab Performance Monitoring](../administration/monitoring/performance/index.md).
- [Request Profiling](../administration/monitoring/performance/request_profiling.md).
- [QueryRecoder](query_recorder.md) for preventing `N+1` regressions.
- [Chaos endpoints](chaos_endpoints.md) for testing failure scenarios. Intended mainly for testing availability.
- [Service measurement](service_measurement.md) for measuring and logging service execution.

GitLab team members can use [GitLab.com's performance monitoring systems](https://about.gitlab.com/handbook/engineering/monitoring/) located at
<https://dashboards.gitlab.net>, this requires you to log in using your
`@gitlab.com` email address. Non-GitLab team-members are advised to set up their
own Prometheus and Grafana stack.

## Benchmarks

Benchmarks are almost always useless. Benchmarks usually only test small bits of
code in isolation and often only measure the best case scenario. On top of that,
benchmarks for libraries (such as a Gem) tend to be biased in favour of the
library. After all there's little benefit to an author publishing a benchmark
that shows they perform worse than their competitors.

Benchmarks are only really useful when you need a rough (emphasis on "rough")
understanding of the impact of your changes. For example, if a certain method is
slow a benchmark can be used to see if the changes you're making have any impact
on the method's performance. However, even when a benchmark shows your changes
improve performance there's no guarantee the performance also improves in a
production environment.

When writing benchmarks you should almost always use
[benchmark-ips](https://github.com/evanphx/benchmark-ips). Ruby's `Benchmark`
module that comes with the standard library is rarely useful as it runs either a
single iteration (when using `Benchmark.bm`) or two iterations (when using
`Benchmark.bmbm`). Running this few iterations means external factors, such as a
video streaming in the background, can very easily skew the benchmark
statistics.

Another problem with the `Benchmark` module is that it displays timings, not
iterations. This means that if a piece of code completes in a very short period
of time it can be very difficult to compare the timings before and after a
certain change. This in turn leads to patterns such as the following:

```ruby
Benchmark.bmbm(10) do |bench|
  bench.report 'do something' do
    100.times do
      ... work here ...
    end
  end
end
```

This however leads to the question: how many iterations should we run to get
meaningful statistics?

The benchmark-ips Gem basically takes care of all this and much more, and as a
result of this should be used instead of the `Benchmark` module.

In short:

- Don't trust benchmarks you find on the internet.
- Never make claims based on just benchmarks, always measure in production to
   confirm your findings.
- X being N times faster than Y is meaningless if you don't know what impact it
   will actually have on your production environment.
- A production environment is the _only_ benchmark that always tells the truth
   (unless your performance monitoring systems are not set up correctly).
- If you must write a benchmark use the benchmark-ips Gem instead of Ruby's
   `Benchmark` module.

## Profiling

By collecting snapshots of process state at regular intervals, profiling allows
you to see where time is spent in a process. The
[Stackprof](https://github.com/tmm1/stackprof) gem is included in GitLab,
allowing you to profile which code is running on CPU in detail.

It's important to note that profiling an application *alters its performance*.
Different profiling strategies have different overheads. Stackprof is a sampling
profiler. It will sample stack traces from running threads at a configurable
frequency (e.g. 100hz, that is 100 stacks per second). This type of profiling
has quite a low (albeit non-zero) overhead and is generally considered to be
safe for production.

### Development

A profiler can be a very useful tool during development, even if it does run *in
an unrepresentative environment*. In particular, a method is not necessarily
troublesome just because it's executed many times, or takes a long time to
execute. Profiles are tools you can use to better understand what is happening
in an application - using that information wisely is up to you!

Keeping that in mind, to create a profile, identify (or create) a spec that
exercises the troublesome code path, then run it using the `bin/rspec-stackprof`
helper, for example:

```shell
$ LIMIT=10 bin/rspec-stackprof spec/policies/project_policy_spec.rb

8/8 |====== 100 ======>| Time: 00:00:18

Finished in 18.19 seconds (files took 4.8 seconds to load)
8 examples, 0 failures

==================================
 Mode: wall(1000)
 Samples: 17033 (5.59% miss rate)
 GC: 1901 (11.16%)
==================================
    TOTAL    (pct)     SAMPLES    (pct)     FRAME
     6000  (35.2%)        2566  (15.1%)     Sprockets::Cache::FileStore#get
     2018  (11.8%)         888   (5.2%)     ActiveRecord::ConnectionAdapters::PostgreSQLAdapter#exec_no_cache
     1338   (7.9%)         640   (3.8%)     ActiveRecord::ConnectionAdapters::PostgreSQL::DatabaseStatements#execute
     3125  (18.3%)         394   (2.3%)     Sprockets::Cache::FileStore#safe_open
      913   (5.4%)         301   (1.8%)     ActiveRecord::ConnectionAdapters::PostgreSQLAdapter#exec_cache
      288   (1.7%)         288   (1.7%)     ActiveRecord::Attribute#initialize
      246   (1.4%)         246   (1.4%)     Sprockets::Cache::FileStore#safe_stat
      295   (1.7%)         193   (1.1%)     block (2 levels) in class_attribute
      187   (1.1%)         187   (1.1%)     block (4 levels) in class_attribute
```

You can limit the specs that are run by passing any arguments `rspec` would
normally take.

The output is sorted by the `Samples` column by default. This is the number of
samples taken where the method is the one currently being executed. The `Total`
column shows the number of samples taken where the method, or any of the methods
it calls, were being executed.

To create a graphical view of the call stack:

```shell
stackprof tmp/project_policy_spec.rb.dump --graphviz > project_policy_spec.dot
dot -Tsvg project_policy_spec.dot > project_policy_spec.svg
```

To load the profile in [kcachegrind](https://kcachegrind.github.io/):

```shell
stackprof tmp/project_policy_spec.dump --callgrind > project_policy_spec.callgrind
kcachegrind project_policy_spec.callgrind # Linux
qcachegrind project_policy_spec.callgrind # Mac
```

It may be useful to zoom in on a specific method, for example:

```shell
$ stackprof tmp/project_policy_spec.rb.dump --method warm_asset_cache

TestEnv#warm_asset_cache (/Users/lupine/dev/gitlab.com/gitlab-org/gitlab-development-kit/gitlab/spec/support/test_env.rb:164)
  samples:     0 self (0.0%)  /   6288 total (36.9%)
  callers:
    6288  (  100.0%)  block (2 levels) in <top (required)>
  callees (6288 total):
    6288  (  100.0%)  Capybara::RackTest::Driver#visit
  code:
                                  |   164  |   def warm_asset_cache
                                  |   165  |     return if warm_asset_cache?
                                  |   166  |     return unless defined?(Capybara)
                                  |   167  |
 6288   (36.9%)                   |   168  |     Capybara.current_session.driver.visit '/'
                                  |   169  |   end
$ stackprof tmp/project_policy_spec.rb.dump --method BasePolicy#abilities
BasePolicy#abilities (/Users/lupine/dev/gitlab.com/gitlab-org/gitlab-development-kit/gitlab/app/policies/base_policy.rb:79)
  samples:     0 self (0.0%)  /     50 total (0.3%)
  callers:
      25  (   50.0%)  BasePolicy.abilities
      25  (   50.0%)  BasePolicy#collect_rules
  callees (50 total):
      25  (   50.0%)  ProjectPolicy#rules
      25  (   50.0%)  BasePolicy#collect_rules
  code:
                                  |    79  |   def abilities
                                  |    80  |     return RuleSet.empty if @user && @user.blocked?
                                  |    81  |     return anonymous_abilities if @user.nil?
   50    (0.3%)                   |    82  |     collect_rules { rules }
                                  |    83  |   end
```

Since the profile includes the work done by the test suite as well as the
application code, these profiles can be used to investigate slow tests as well.
However, for smaller runs (like this example), this means that the cost of
setting up the test suite will tend to dominate.

### Production

Stackprof can also be used to profile production workloads.

In order to enable production profiling for Ruby processes, you can set the `STACKPROF_ENABLED` environment variable to `true`.

The following configuration options can be configured:

- `STACKPROF_ENABLED`: Enables stackprof signal handler on SIGUSR2 signal.
  Defaults to `false`.
- `STACKPROF_INTERVAL_US`: Sampling interval in microseconds. Defaults to
  `10000` μs (100hz).
- `STACKPROF_FILE_PREFIX`: File path prefix where profiles are stored. Defaults
  to `$TMPDIR` (often corresponds to `/tmp`).
- `STACKPROF_TIMEOUT_S`: Profiling timeout in seconds. Profiling will
  automatically stop after this time has elapsed. Defaults to `30`.
- `STACKPROF_RAW`: Whether to collect raw samples or only aggregates. Raw
  samples are needed to generate flamegraphs, but they do have a higher memory
  and disk overhead. Defaults to `true`.

Once enabled, profiling can be triggered by sending a `SIGUSR2` signal to the
Ruby process. The process will begin sampling stacks. Profiling can be stopped
by sending another `SIGUSR2`. Alternatively, it will automatically stop after
the timeout.

Once profiling stops, the profile is written out to disk at
`$STACKPROF_FILE_PREFIX/stackprof.$PID.$RAND.profile`. It can then be inspected
further via the `stackprof` command line tool, as described in the previous
section.

Currently supported profiling targets are:

- Puma worker
- Sidekiq

NOTE: **Note:** The Puma master process is not supported. Neither is Unicorn.
Sending SIGUSR2 to either of those will trigger restarts. In the case of Puma,
take care to only send the signal to Puma workers.

This can be done via `pkill -USR2 puma:`. The `:` disambiguates between `puma
4.3.3.gitlab.2 ...` (the master process) from `puma: cluster worker 0: ...` (the
worker processes), selecting the latter.

Production profiles can be especially noisy. It can be helpful to visualize them
as a [flamegraph](https://github.com/brendangregg/FlameGraph). This can be done
via:

```shell
bundle exec stackprof --stackcollapse /tmp/stackprof.55769.c6c3906452.profile | flamegraph.pl > flamegraph.svg
```

## RSpec profiling

GitLab's development environment also includes the
[rspec_profiling](https://github.com/foraker/rspec_profiling) gem, which is used
to collect data on spec execution times. This is useful for analyzing the
performance of the test suite itself, or seeing how the performance of a spec
may have changed over time.

To activate profiling in your local environment, run the following:

```shell
export RSPEC_PROFILING=yes
rake rspec_profiling:install
```

This creates an SQLite3 database in `tmp/rspec_profiling`, into which statistics
are saved every time you run specs with the `RSPEC_PROFILING` environment
variable set.

Ad-hoc investigation of the collected results can be performed in an interactive
shell:

```shell
$ rake rspec_profiling:console

irb(main):001:0> results.count
=> 231
irb(main):002:0> results.last.attributes.keys
=> ["id", "commit", "date", "file", "line_number", "description", "time", "status", "exception", "query_count", "query_time", "request_count", "request_time", "created_at", "updated_at"]
irb(main):003:0> results.where(status: "passed").average(:time).to_s
=> "0.211340155844156"
```

These results can also be placed into a PostgreSQL database by setting the
`RSPEC_PROFILING_POSTGRES_URL` variable. This is used to profile the test suite
when running in the CI environment.

We store these results also when running CI jobs on the default branch on
`gitlab.com`. Statistics of these profiling data are [available
online](https://gitlab-org.gitlab.io/rspec_profiling_stats/). For example,
you can find which tests take longest to run or which execute the most
queries. This can be handy for optimizing our tests or identifying performance
issues in our code.

## Memory profiling

One of the reasons of the increased memory footprint could be Ruby memory fragmentation.

To diagnose it, you can visualize Ruby heap as described in [this post by Aaron Patterson](https://tenderlovemaking.com/2017/09/27/visualizing-your-ruby-heap.html).

To start, you want to dump the heap of the process you're investigating to a JSON file.

You need to run the command inside the process you're exploring, you may do that with `rbtrace`.
`rbtrace` is already present in GitLab `Gemfile`, you just need to require it.
It could be achieved running webserver or Sidekiq with the environment variable set to `ENABLE_RBTRACE=1`.

To get the heap dump:

```ruby
bundle exec rbtrace -p <PID> -e 'File.open("heap.json", "wb") { |t| ObjectSpace.dump_all(output: t) }'
```

Having the JSON, you finally could render a picture using the script [provided by Aaron](https://gist.github.com/tenderlove/f28373d56fdd03d8b514af7191611b88) or similar:

```shell
ruby heapviz.rb heap.json
```

Fragmented Ruby heap snapshot could look like this:

![Ruby heap fragmentation](img/memory_ruby_heap_fragmentation.png)

Memory fragmentation could be reduced by tuning GC parameters as described in [this post by Nate Berkopec](https://www.speedshop.co/2017/12/04/malloc-doubles-ruby-memory.html). This should be considered as a tradeoff, as it may affect overall performance of memory allocation and GC cycles.

## Importance of Changes

When working on performance improvements, it's important to always ask yourself
the question "How important is it to improve the performance of this piece of
code?". Not every piece of code is equally important and it would be a waste to
spend a week trying to improve something that only impacts a tiny fraction of
our users. For example, spending a week trying to squeeze 10 milliseconds out of
a method is a waste of time when you could have spent a week squeezing out 10
seconds elsewhere.

There is no clear set of steps that you can follow to determine if a certain
piece of code is worth optimizing. The only two things you can do are:

1. Think about what the code does, how it's used, how many times it's called and
   how much time is spent in it relative to the total execution time (for example, the
   total time spent in a web request).
1. Ask others (preferably in the form of an issue).

Some examples of changes that are not really important/worth the effort:

- Replacing double quotes with single quotes.
- Replacing usage of Array with Set when the list of values is very small.
- Replacing library A with library B when both only take up 0.1% of the total
  execution time.
- Calling `freeze` on every string (see [String Freezing](#string-freezing)).

## Slow Operations & Sidekiq

Slow operations, like merging branches, or operations that are prone to errors
(using external APIs) should be performed in a Sidekiq worker instead of
directly in a web request as much as possible. This has numerous benefits such
as:

1. An error won't prevent the request from completing.
1. The process being slow won't affect the loading time of a page.
1. In case of a failure it's easy to re-try the process (Sidekiq takes care of
   this automatically).
1. By isolating the code from a web request it will hopefully be easier to test
   and maintain.

It's especially important to use Sidekiq as much as possible when dealing with
Git operations as these operations can take quite some time to complete
depending on the performance of the underlying storage system.

## Git Operations

Care should be taken to not run unnecessary Git operations. For example,
retrieving the list of branch names using `Repository#branch_names` can be done
without an explicit check if a repository exists or not. In other words, instead
of this:

```ruby
if repository.exists?
  repository.branch_names.each do |name|
    ...
  end
end
```

You can just write:

```ruby
repository.branch_names.each do |name|
  ...
end
```

## Caching

Operations that will often return the same result should be cached using Redis,
in particular Git operations. When caching data in Redis, make sure the cache is
flushed whenever needed. For example, a cache for the list of tags should be
flushed whenever a new tag is pushed or a tag is removed.

When adding cache expiration code for repositories, this code should be placed
in one of the before/after hooks residing in the Repository class. For example,
if a cache should be flushed after importing a repository this code should be
added to `Repository#after_import`. This ensures the cache logic stays within
the Repository class instead of leaking into other classes.

When caching data, make sure to also memoize the result in an instance variable.
While retrieving data from Redis is much faster than raw Git operations, it still
has overhead. By caching the result in an instance variable, repeated calls to
the same method won't end up retrieving data from Redis upon every call. When
memoizing cached data in an instance variable, make sure to also reset the
instance variable when flushing the cache. An example:

```ruby
def first_branch
  @first_branch ||= cache.fetch(:first_branch) { branches.first }
end

def expire_first_branch_cache
  cache.expire(:first_branch)
  @first_branch = nil
end
```

## String Freezing

In recent Ruby versions calling `freeze` on a String leads to it being allocated
only once and re-used. For example, on Ruby 2.3 or later this will only allocate the
"foo" String once:

```ruby
10.times do
  'foo'.freeze
end
```

Depending on the size of the String and how frequently it would be allocated
(before the `.freeze` call was added), this _may_ make things faster, but
there's no guarantee it will.

Strings will be frozen by default in Ruby 3.0. To prepare our code base for
this eventuality, we will be adding the following header to all Ruby files:

```ruby
# frozen_string_literal: true
```

This may cause test failures in the code that expects to be able to manipulate
strings. Instead of using `dup`, use the unary plus to get an unfrozen string:

```ruby
test = +"hello"
test += " world"
```

When adding new Ruby files, please check that you can add the above header,
as omitting it may lead to style check failures.

## Reading from files and other data sources

Ruby offers several convenience functions that deal with file contents specifically
or I/O streams in general. Functions such as `IO.read` and `IO.readlines` make
it easy to read data into memory, but they can be inefficient when the
data grows large. Because these functions read the entire contents of a data
source into memory, memory use will grow by _at least_ the size of the data source.
In the case of `readlines`, it will grow even further, due to extra bookkeeping
the Ruby VM has to perform to represent each line.

Consider the following program, which reads a text file that is 750MB on disk:

```ruby
File.readlines('large_file.txt').each do |line|
  puts line
end
```

Here is a process memory reading from while the program was running, showing
how we indeed kept the entire file in memory (RSS reported in kilobytes):

```shell
$ ps -o rss -p <pid>

RSS
783436
```

And here is an excerpt of what the garbage collector was doing:

```ruby
pp GC.stat

{
 :heap_live_slots=>2346848,
 :malloc_increase_bytes=>30895288,
 ...
}
```

We can see that `heap_live_slots` (the number of reachable objects) jumped to ~2.3M,
which is roughly two orders of magnitude more compared to reading the file line by
line instead. It was not just the raw memory usage that increased, but also how the garbage collector (GC)
responded to this change in anticipation of future memory use. We can see that `malloc_increase_bytes` jumped
to ~30MB, which compares to just ~4kB for a "fresh" Ruby program. This figure specifies how
much additional heap space the Ruby GC will claim from the operating system next time it runs out of memory.
Not only did we occupy more memory, we also changed the behavior of the application
to increase memory use at a faster rate.

The `IO.read` function exhibits similar behavior, with the difference that no extra memory will
be allocated for each line object.

### Recommendations

Instead of reading data sources into memory in full, it is better to read them line by line
instead. This is not always an option, for instance when you need to convert a YAML file
into a Ruby `Hash`, but whenever you have data where each row represents some entity that
can be processed and then discarded, you can use the following approaches.

First, replace calls to `readlines.each` with either `each` or `each_line`.
The `each_line` and `each` functions read the data source line by line without keeping
already visited lines in memory:

```ruby
File.new('file').each { |line| puts line }
```

Alternatively, you can read individual lines explicitly using `IO.readline` or `IO.gets` functions:

```ruby
while line = file.readline
   # process line
end
```

This might be preferable if there is a condition that allows exiting the loop early, saving not
just memory but also unnecessary time spent in CPU and I/O for processing lines you're not interested in.

## Anti-Patterns

This is a collection of [anti-patterns](https://en.wikipedia.org/wiki/Anti-pattern) that should be avoided
unless these changes have a measurable, significant, and positive impact on
production environments.

### Moving Allocations to Constants

Storing an object as a constant so you only allocate it once _may_ improve
performance, but there's no guarantee this will. Looking up constants has an
impact on runtime performance, and as such, using a constant instead of
referencing an object directly may even slow code down. For example:

```ruby
SOME_CONSTANT = 'foo'.freeze

9000.times do
  SOME_CONSTANT
end
```

The only reason you should be doing this is to prevent somebody from mutating
the global String. However, since you can just re-assign constants in Ruby
there's nothing stopping somebody from doing this elsewhere in the code:

```ruby
SOME_CONSTANT = 'bar'
```

## How to seed a database with millions of rows

You might want millions of project rows in your local database, for example,
in order to compare relative query performance, or to reproduce a bug. You could
do this by hand with SQL commands or using [Mass Inserting Rails
Models](mass_insert.md) functionality.

Assuming you are working with ActiveRecord models, you might also find these links helpful:

- [Insert records in batches](insert_into_tables_in_batches.md)
- [BulkInsert gem](https://github.com/jamis/bulk_insert)
- [ActiveRecord::PgGenerateSeries gem](https://github.com/ryu39/active_record-pg_generate_series)

### Examples

You may find some useful examples in this snippet:
<https://gitlab.com/gitlab-org/gitlab-foss/snippets/33946>
