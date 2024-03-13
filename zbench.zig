//!zig-autodoc-guide: docs/intro.md
//!zig-autodoc-guide: docs/quickstart.md
//!zig-autodoc-guide: docs/advanced.md

const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.zbench);

const c = @import("./util/color.zig");
const format = @import("./util/format.zig");
const quicksort = @import("./util/quicksort.zig");
const platform = @import("./util/platform.zig");

/// LifecycleHooks containing optional hooks for lifecycle events in benchmarking.
/// Each field in this struct is a nullable function pointer.
const LifecycleHooks = struct {
    beforeAll: ?*const fn () void = null,
    afterAll: ?*const fn () void = null,
    beforeEach: ?*const fn () void = null,
    afterEach: ?*const fn () void = null,
};

/// Configuration for benchmarking.
/// This struct holds settings to control the behavior of benchmark executions.
pub const Config = struct {
    /// Number of iterations the benchmark has been run. Initialized to 0.
    /// If 0 then zBench will calculate an value.
    iterations: u16 = 0,

    /// Maximum number of iterations the benchmark can run. Default is 16384.
    /// This limit helps to avoid excessively long benchmark runs.
    max_iterations: u16 = 16384,

    /// Time budget for the benchmark in nanoseconds. Default is 2e9 (2 seconds).
    /// This value is used to determine how long a single benchmark should be allowed to run
    /// before concluding. Helps in avoiding long-running benchmarks.
    time_budget: u64 = 2e9, // 2 seconds

    /// Configuration for lifecycle hooks in benchmarking.
    /// Provides the ability to define custom actions at different stages of the benchmark process:
    /// - `beforeAll`: A hook that runs once before all benchmarks begin.
    /// - `afterAll`: A hook that runs once after all benchmarks have completed.
    /// - `beforeEach`: A hook that runs before each individual benchmark.
    /// - `afterEach`: A hook that runs after each individual benchmark.
    /// This allows for custom setup and teardown operations, as well as fine-grained control
    /// over the environment in which benchmarks are run.
    hooks: LifecycleHooks = .{},

    /// Flag to indicate whether system information should be displayed. Default is false.
    /// If true, detailed system information (e.g., CPU, memory) will be displayed
    /// along with the benchmark results. Useful for understanding the environment
    /// in which the benchmarks were run.
    display_system_info: bool = false,
};

/// Benchmark is a type representing a single benchmark session.
/// It provides metrics and utilities for performance measurement.
pub const Benchmark = struct {
    /// Used to represent the 75th, 99th and 99.5th percentiles of the recorded durations,
    /// generated by `Benchmark.calculatePercentiles`.
    pub const Percentiles = struct {
        p75: u64,
        p99: u64,
        p995: u64,
    };

    /// Name of the benchmark.
    name: []const u8,
    /// Number of iterations to be performed in the benchmark.
    N: usize = 1,
    /// Timer used to track the duration of the benchmark.
    timer: std.time.Timer,
    /// Total number of operations performed during the benchmark.
    total_operations: usize = 0,
    /// Minimum duration recorded among all runs (initially set to the maximum possible value).
    min_duration: u64 = std.math.maxInt(u64),
    /// Maximum duration recorded among all runs.
    max_duration: u64 = 0,
    /// Total duration accumulated over all runs.
    total_duration: u64 = 0,
    /// A dynamic list storing the duration of each run.
    durations: std.ArrayList(u64),
    /// Memory allocator used by the benchmark.
    allocator: std.mem.Allocator,
    /// Configuration settings
    config: Config,

    /// Initializes a new Benchmark instance.
    /// name: A string representing the benchmark's name.
    /// allocator: Memory allocator to be used.
    pub fn init(name: []const u8, allocator: std.mem.Allocator, config: Config) !Benchmark {
        const bench = Benchmark{
            .name = name,
            .allocator = allocator,
            .config = config,
            .timer = std.time.Timer.start() catch return error.TimerUnsupported,
            .durations = std.ArrayList(u64).init(allocator),
        };

        return bench;
    }

    /// Starts or restarts the benchmark timer.
    pub fn start(self: *Benchmark) void {
        self.timer.reset();
    }

    /// Stop the benchmark and record the duration
    pub fn stop(self: *Benchmark) void {
        const elapsedDuration = self.timer.read();
        self.total_duration += elapsedDuration;

        if (elapsedDuration < self.min_duration) self.min_duration = elapsedDuration;
        if (elapsedDuration > self.max_duration) self.max_duration = elapsedDuration;

        self.durations.append(elapsedDuration) catch unreachable;
    }

    /// Reset the benchmark
    pub fn reset(self: *Benchmark) void {
        self.total_operations = 0;
        self.min_duration = std.math.maxInt(u64);
        self.max_duration = 0;
        self.total_duration = 0;
        self.durations.clearRetainingCapacity();
    }

    /// Returns the elapsed time since the benchmark started.
    pub fn elapsed(self: *Benchmark) u64 {
        var sum: u64 = 0;
        for (self.durations.items) |duration| {
            sum += duration;
        }
        return sum;
    }

    /// Sets the total number of operations performed.
    /// ops: Number of operations.
    pub fn setTotalOperations(self: *Benchmark, ops: usize) void {
        self.total_operations = ops;
    }

    /// Calculate the 75th, 99th and 99.5th percentiles of the durations. They represent the timings below
    /// which 75%, 99% and 99.5% of the other measurments would lie (respectively) when timings are
    /// sorted in increasing order.
    pub fn calculatePercentiles(self: Benchmark) Percentiles {
        // quickSort might fail with an empty input slice, so safety checks first
        if (self.durations.items.len <= 1) {
            std.log.warn("Insufficient data for percentile calculation.", .{});
            return Percentiles{ .p75 = 0, .p99 = 0, .p995 = 0 };
        }

        const len = self.durations.items.len;
        quicksort.sort(u64, self.durations.items, 0, len - 1);

        const p75 = self.durations.items[len * 75 / 100];
        const p99 = self.durations.items[len * 99 / 100];
        const p995 = self.durations.items[len * 995 / 1000];

        std.debug.assert(p75 <= p99);
        std.debug.assert(p99 <= p995);
        return Percentiles{ .p75 = p75, .p99 = p99, .p995 = p995 };
    }

    /// Calculate the average (more precisely arithmetic mean) of the durations
    pub fn calculateAverage(self: Benchmark) u64 {
        if (self.durations.items.len == 0) return 0;

        var sum: u64 = 0;
        for (self.durations.items) |d| sum += d;
        return sum / self.durations.items.len;
    }

    /// Calculate the standard deviation of the durations. An estimate for the average *deviation*
    /// from the average duration.
    pub fn calculateStd(self: Benchmark) u64 {
        if (self.durations.items.len <= 1) return 0;

        // We are using the non-biased estimator for the variance; sum(Xi - μ)^2 / (n - 1)
        const avg = self.calculateAverage();
        var nvar: u64 = 0;
        for (self.durations.items) |dur| {
            const sd = if (dur < avg) avg - dur else dur - avg;
            nvar += sd * sd;
        }
        return std.math.sqrt(nvar / (self.durations.items.len - 1));
    }
};

/// BenchFunc is a function type that represents a benchmark function.
/// It takes a pointer to a Benchmark object.
pub const BenchFunc = fn (*Benchmark) void;

/// BenchmarkResult stores the resulting computed metrics/statistics from a benchmark
pub const BenchmarkResult = struct {
    const Self = @This();
    const Color = c.Color;

    /// Name of the benchmark
    name: []const u8,
    /// 75th, 99th and 99.5th percentiles of the recorded durations. They represent the timings below
    /// which 75%, 99% and 99.5% of the other measurments would lie, respectively, when timings
    /// are sorted in increasing order.
    percentiles: Benchmark.Percentiles,
    /// The average (more precisely arithmetic mean) of the recorded durations
    avg_duration: usize,
    /// The standard-deviation of the recorded durations (an estimate for the average *deviation* from
    /// the average duration).
    std_duration: usize,
    /// The minimum among the recorded durations
    min_duration: usize,
    /// The maximum among the recorded durations
    max_duration: usize,
    /// The total amount of operations (or runs) performed of the benchmark
    total_operations: usize,
    /// Total time for all the operations (or runs) of the benchmark combined
    total_time: usize,

    /// Formats and prints the benchmark-result in a readable format.
    /// writer: Type that has the associated method print (for example std.io.getStdOut.writer())
    /// header: Whether to pretty-print the header or not
    pub fn prettyPrint(self: Self, writer: anytype) !void {
        const colors = true;
        const pc = self.percentiles;
        try format.prettyPrintName(self.name, writer);
        try setColor(colors, writer, Color.cyan);
        try format.prettyPrintTotalOperations(self.total_operations, writer);
        try format.prettyPrintTotalTime(self.total_time, writer);
        try setColor(colors, writer, Color.green);
        try format.prettyPrintAvgStd(self.avg_duration, self.std_duration, writer);
        try setColor(colors, writer, Color.blue);
        try format.prettyPrintMinMax(self.min_duration, self.max_duration, writer);
        try setColor(colors, writer, Color.cyan);
        try format.prettyPrintPercentiles(pc.p75, pc.p99, pc.p995, writer);
        try setColor(colors, writer, Color.reset);
        try writer.writeAll("\n");
    }

    fn setColor(colors: bool, writer: anytype, color: Color) !void {
        if (colors) try writer.writeAll(color.code());
    }
};

/// BenchmarkResults acts as a container for multiple benchmark results.
/// It provides functionality to format and print these results.
pub const BenchmarkResults = struct {
    const Color = c.Color;
    const BufferedStdoutWriter = std.io.BufferedWriter(1024, @TypeOf(std.io.getStdOut().writer()));

    /// A dynamic list of BenchmarkResult objects.
    results: std.ArrayList(BenchmarkResult),
    /// A handle to a buffered stdout-writer. Used for printing-operations
    out_stream: BufferedStdoutWriter,

    // NOTE: This init function is technically not needed however it was added to circumvent a (most likely) bug
    // in the 0.11.0 compiler (see issue #49). In the future we may want to remove this.
    pub fn init(results: std.ArrayList(BenchmarkResult)) BenchmarkResults {
        return BenchmarkResults{
            .results = results,
            .out_stream = .{ .unbuffered_writer = std.io.getStdOut().writer() },
        };
    }

    pub fn deinit(self: *BenchmarkResults) void {
        // self.out_stream.flush();
        self.results.deinit();
    }

    /// Formats and prints the benchmark results in a readable format.
    pub fn prettyPrint(self: *BenchmarkResults) !void {
        const writer = self.out_stream.writer();
        try format.prettyPrintHeader(writer);
        for (self.results.items) |r| try r.prettyPrint(writer);
        try self.out_stream.flush();
    }
};

/// Executes a benchmark function within the context of a given Benchmark object.
/// func: The benchmark function to be executed.
/// bench: A pointer to a Benchmark object for tracking the benchmark.
/// benchResult: A pointer to BenchmarkResults to store the results.
pub fn run(comptime func: BenchFunc, bench: *Benchmark, benchResult: *BenchmarkResults) !void {
    defer bench.durations.deinit();
    const MIN_DURATION = bench.config.time_budget; // minimum benchmark time in nanoseconds (1 second)
    const MAX_N = 65536; // maximum number of executions for the final benchmark run
    const MAX_ITERATIONS = bench.config.max_iterations; // Define a maximum number of iterations

    if (bench.config.display_system_info) {
        const allocator = std.heap.page_allocator;
        const info = try platform.getSystemInfo(allocator);

        std.debug.print(
            \\
            \\  Operating System: {s}
            \\  CPU:              {s}
            \\  CPU Cores:        {d}
            \\  Total Memory:     {s}
            \\
        , .{ info.platform, info.cpu, info.cpu_cores, info.memory_total });
    }

    // Call beforeAll hook if defined
    if (bench.config.hooks.beforeAll) |hook| {
        hook();
    }

    defer {
        // Call afterAll hook if defined
        if (bench.config.hooks.afterAll) |hook| {
            hook();
        }
    }

    if (bench.config.iterations != 0) {
        // If user-defined iterations are specified, use them directly
        bench.N = bench.config.iterations;
    } else {
        bench.N = 1; // initial value; will be updated...
        var duration: u64 = 0;
        var iterations: usize = 0; // Add an iterations counter

        // increase N until we've run for a sufficiently long time or exceeded max_iterations
        while (duration < MIN_DURATION and iterations < MAX_ITERATIONS) {
            bench.reset();

            bench.start();
            var j: usize = 0;
            while (j < bench.N) : (j += 1) {
                func(bench);
            }

            bench.stop();
            // double N for next iteration
            if (bench.N < MAX_N / 2) {
                bench.N *= 2;
            } else {
                bench.N = MAX_N;
            }

            iterations += 1; // Increase the iteration counter
            duration += bench.elapsed(); // ...and duration
        }

        // Safety first: make sure the recorded durations aren't all-zero
        if (duration == 0) duration = 1;

        // Adjust N based on the actual duration achieved
        bench.N = @intCast((bench.N * MIN_DURATION) / duration);
        // check that N doesn't go out of bounds
        if (bench.N == 0) bench.N = 1;
        if (bench.N > MAX_N) bench.N = MAX_N;
    }

    // Now run the benchmark with the adjusted N value
    bench.reset();
    var j: usize = 0;
    while (j < bench.N) : (j += 1) {
        // Call beforeEach hook if defined
        if (bench.config.hooks.beforeEach) |hook| {
            hook();
        }

        bench.start();
        func(bench);
        bench.stop();

        // Call afterEach hook if defined
        if (bench.config.hooks.afterEach) |hook| {
            hook();
        }
    }

    bench.setTotalOperations(bench.N);

    const elapsed = bench.elapsed();
    try benchResult.results.append(BenchmarkResult{
        .name = bench.name,
        .percentiles = bench.calculatePercentiles(),
        .avg_duration = bench.calculateAverage(),
        .std_duration = bench.calculateStd(),
        .min_duration = bench.min_duration,
        .max_duration = bench.max_duration,
        .total_time = elapsed,
        .total_operations = bench.total_operations,
    });
}
