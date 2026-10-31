# Timing of the build of the documentation.
#
#   DocsTiming.timed() do
#       makedocs(...)
#   end
#
# runs the build under a logger that stamps the phases of Documenter (SetupBuildDirectory,
# Doctest, ExpandTemplates, ... and the VitePress build) and the start of every page with
# the time of day, the time since the previous mark and the time since the start, and ends
# with a table of where the time went. Documenter runs the examples of a page while it
# expands the templates, so the time between two page marks is the time of that page. Every
# code block (`@example`, `@setup`, `@eval`, `@repl`) is timed too, and the slowest ones are
# listed with the page and the first line of their code; they are not logged one by one.
#
# Besides the time, every phase, page and block reports how much of it was garbage collection
# and compilation (so the rest is running code and loading packages), pages and phases the
# live heap at their end, and a small fixed computation (the probe) is timed at the start of
# each phase and page: its time against the fastest one of the build says how slow the
# machine was at that moment, which makes runs of different days comparable.
#
# Documenter announces the start of each page and of each block with a `@debug` message,
# which a logger does not see unless it asks for it: this one asks for those messages only
# and does not pass on the others, so nothing else changes in the output.

module DocsTiming

using Logging
using Printf

# What the process has done so far: seconds of garbage collection, seconds of compilation
# and the live heap in bytes.
struct Sample
    gc::Float64
    compile::Float64
    heap::Float64
end

function process_sample()
    gc = Base.gc_num().total_time / 1.0e9
    compile = sum(Base.cumulative_compile_time_ns()) / 1.0e9
    heap = try
        Float64(Base.gc_live_bytes())
    catch
        NaN
    end
    return Sample(gc, compile, heap)
end

# A fixed piece of arithmetic, timed: the best of two runs, in seconds. It always does the
# same work, so a longer time means a slower machine (a busy or throttled CPU).
const SINK = Ref(0.0)

function probe_loop()
    s = 0.0
    for i = 1:2_000_000
        s += sin(i * 1.0e-3)
    end
    return s
end

function cpu_probe()
    best = Inf
    for _ = 1:2
        t = time_ns()
        SINK[] = probe_loop()
        best = min(best, (time_ns() - t) / 1.0e9)
    end
    return best
end

# One mark: what began at `at` seconds (`kind` is `:phase`, `:page` or `:block`), with the
# state of the process then and the probe (NaN for a block, which is not probed).
struct Mark
    kind::Symbol
    label::String
    at::Float64
    sample::Sample
    probe::Float64
end

mutable struct Clock
    now::Function                 # seconds; replaceable to test with a fixed sequence
    start::Float64
    marks::Vector{Mark}
    finish::Float64
    sample::Function              # replaceable too
    probe::Function
    final::Sample                 # the state of the process at the end
end

function Clock(
    now::Function = time;
    sample::Function = process_sample,
    probe::Function = cpu_probe,
)
    return Clock(now, now(), Mark[], NaN, sample, probe, sample())
end

struct TimingLogger{L<:AbstractLogger} <: AbstractLogger
    inner::L
    clock::Clock
end

const PAGE_PREFIX = "Running ExpanderPipeline on "
const BLOCK_PREFIX = r"^Evaluating @(example|setup|eval|repl) block:\n?"
const BLOCK_PREFIX_TEXT = "Evaluating @"
const LABEL_WIDTH = 56
const BLOCK_ROWS = 15
const PHASE_MODULES = (:Documenter, :DocumenterCitations, :DocumenterVitepress)

# Documenter's own announcements of a page and of a block: the debug messages that are kept.
is_page_announcement(level, _module, group) =
    level == Logging.Debug &&
    _module isa Module &&
    nameof(_module) === :Documenter &&
    group === :expander_pipeline

# The label of a block: its kind, its place in the page and the first line of its code that
# is not a comment, shortened.
function block_label(page::AbstractString, index::Integer, text::AbstractString)
    m = match(BLOCK_PREFIX, text)
    m === nothing && return nothing
    code = text[(m.match.ncodeunits+1):end]
    lines = [strip(l) for l in split(code, '\n') if !isempty(strip(l))]
    i = findfirst(l -> !startswith(l, "#"), lines)
    first_line = i === nothing ? (isempty(lines) ? "" : lines[1]) : lines[i]
    if length(first_line) > LABEL_WIDTH
        first_line = string(first(first_line, LABEL_WIDTH), "…")
    end
    return string(page, " #", index, " @", m.captures[1], ": ", first_line)
end

# The label of a message that opens a phase, or `nothing` for any other message. Documenter
# starts its phases with "Name: what it does"; DocumenterCitations with the name alone; the
# VitePress site is built by `npm` between two messages of DocumenterVitepress.
function phase_label(_module, text::AbstractString)
    _module isa Module || return nothing
    name = nameof(_module)
    name in PHASE_MODULES || return nothing
    if name === :Documenter || name === :DocumenterCitations
        m = match(r"^([A-Z][A-Za-z]+)(: |$)", text)
        return m === nothing ? nothing : String(m.captures[1])
    else
        occursin("rendering MarkdownVitepress pages", text) && return "VitePress: pages"
        occursin("building Vitepress site", text) && return "VitePress build (npm)"
        return nothing
    end
end

Logging.min_enabled_level(l::TimingLogger) =
    min(Logging.min_enabled_level(l.inner), Logging.Debug)
Logging.catch_exceptions(l::TimingLogger) = Logging.catch_exceptions(l.inner)

# The minimum level of this logger is lowered to Debug so that the announcements of the pages
# arrive, which also lets the level of every other message through the global filter; the
# level the inner logger asks for is checked here.
function Logging.shouldlog(l::TimingLogger, level, _module, group, id)
    is_page_announcement(level, _module, group) && return true
    level >= Logging.min_enabled_level(l.inner) || return false
    return Logging.shouldlog(l.inner, level, _module, group, id)
end

seconds(x::Real) = x < 10 ? @sprintf("%.2f s", x) : @sprintf("%.1f s", x)

# "[12:34:56 | +3.2 s | 120.4 s]": time of day, since the previous mark, since the start.
function stamp(clock::Clock, at::Float64)
    last_mark = findlast(m -> m.kind != :block, clock.marks)
    previous = last_mark === nothing ? clock.start : clock.marks[last_mark].at
    clock_time = Libc.strftime("%H:%M:%S", at)
    return string(
        "[",
        clock_time,
        " | +",
        seconds(at - previous),
        " | ",
        seconds(at - clock.start),
        "]",
    )
end

function mark!(clock::Clock, kind::Symbol, label::AbstractString)
    probe = kind == :block ? NaN : clock.probe()
    at = clock.now()
    text = stamp(clock, at)
    push!(clock.marks, Mark(kind, String(label), at, clock.sample(), probe))
    return text
end

function Logging.handle_message(
    l::TimingLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    if is_page_announcement(level, _module, group)
        text = string(message)
        if startswith(text, BLOCK_PREFIX_TEXT)
            page_marks = [m for m in l.clock.marks if m.kind == :page]
            page = isempty(page_marks) ? "" : page_marks[end].label
            index =
                count(
                    m -> m.kind == :block && startswith(m.label, page * " #"),
                    l.clock.marks,
                ) + 1
            label = block_label(page, index, text)
            label === nothing || mark!(l.clock, :block, label)
            return nothing
        end
        startswith(text, PAGE_PREFIX) || return nothing
        page = text[(length(PAGE_PREFIX)+1):end]
        stamped = mark!(l.clock, :page, page)
        Logging.handle_message(
            l.inner,
            Logging.Info,
            string("Page ", page, " ", stamped),
            _module,
            group,
            id,
            file,
            line,
        )
        return nothing
    end
    if level == Logging.Info
        label = phase_label(_module, string(message))
        if label !== nothing
            message = string(message, " ", mark!(l.clock, :phase, label))
        end
    end
    return Logging.handle_message(
        l.inner,
        level,
        message,
        _module,
        group,
        id,
        file,
        line;
        kwargs...,
    )
end

# For the marks of a kind, the index of the mark that ends each one (`nothing`: the end of
# the build). A phase lasts until the next phase, so "ExpandTemplates" includes all of its
# pages; a page until the next page or, for the last, the phase that follows; a block until
# the next mark of any kind.
function _end_indices(clock::Clock, kind::Symbol)
    idx = [i for (i, m) in enumerate(clock.marks) if m.kind == kind]
    ends = Union{Int,Nothing}[]
    for (k, i) in enumerate(idx)
        if kind == :block
            push!(ends, i < length(clock.marks) ? i + 1 : nothing)
        elseif kind == :phase || k < length(idx)
            push!(ends, k < length(idx) ? idx[k+1] : nothing)
        else
            push!(ends, findnext(m -> m.kind == :phase, clock.marks, i + 1))
        end
    end
    return idx, ends
end

# One line of the report.
struct Row
    label::String
    seconds::Float64
    gc::Float64
    compile::Float64
    heap::Float64                 # live heap at the end of the item, bytes
    probe::Float64                # the probe when the item began
end

function rows(clock::Clock, kind::Symbol)
    idx, ends = _end_indices(clock, kind)
    out = Row[]
    for (i, e) in zip(idx, ends)
        a = clock.marks[i]
        at, after =
            e === nothing ? (clock.finish, clock.final) :
            (clock.marks[e].at, clock.marks[e].sample)
        push!(
            out,
            Row(
                a.label,
                at - a.at,
                max(0.0, after.gc - a.sample.gc),
                max(0.0, after.compile - a.sample.compile),
                after.heap,
                a.probe,
            ),
        )
    end
    return out
end

# Seconds of each mark.
durations(clock::Clock, kind::Symbol) = [(r.label, r.seconds) for r in rows(clock, kind)]

# The fastest probe of the build, the yardstick of the speed of the machine.
function fastest_probe(clock::Clock)
    probes = [m.probe for m in clock.marks if isfinite(m.probe)]
    return isempty(probes) ? NaN : minimum(probes)
end

gib(x::Real) = isfinite(x) ? @sprintf("%.2f GiB", x / 2^30) : "-"

"The table of where the time went, as text."
function report(clock::Clock)
    total = clock.finish - clock.start
    reference = fastest_probe(clock)
    io = IOBuffer()
    println(io, "Build timing: ", seconds(total), " in total")
    println(
        io,
        "(gc and compile are parts of the time; the rest is running code and loading packages. ",
        "heap: live memory at the end of the item. cpu: how many times slower than the ",
        "fastest moment of this build the machine was when the item began)",
    )
    function section(title, items; extras::Bool)
        isempty(items) && return nothing
        println(io, title)
        width = maximum(length(r.label) for r in items)
        for r in items
            line = string(
                "  ",
                rpad(r.label, width),
                "  ",
                lpad(seconds(r.seconds), 9),
                "  ",
                lpad(@sprintf("%.0f%%", 100r.seconds / total), 4),
                "  gc ",
                lpad(seconds(r.gc), 8),
                "  compile ",
                lpad(seconds(r.compile), 8),
            )
            if extras
                speed = isfinite(r.probe) && isfinite(reference) ? r.probe / reference : NaN
                line = string(
                    line,
                    "  heap ",
                    lpad(gib(r.heap), 9),
                    "  cpu ",
                    isfinite(speed) ? @sprintf("x%.2f", speed) : "-",
                )
            end
            println(io, line)
        end
    end
    section("Phases of the build:", rows(clock, :phase); extras = true)
    section(
        "Pages (their examples run inside ExpandTemplates), in the order they ran:",
        rows(clock, :page);
        extras = true,
    )
    section(
        "Slowest code blocks (page, place in the page, first line of the code):",
        first(sort(rows(clock, :block); by = r -> r.seconds, rev = true), BLOCK_ROWS);
        extras = false,
    )
    println(io, "Peak memory of the process: ", gib(Sys.maxrss()))
    return String(take!(io))
end

"""
    timed(f; enabled = true)

Run `f()` under a logger that marks the phases and the pages of the build with the time,
and log the table of where the time went when it ends (also when `f` throws).
`enabled = false` runs `f()` as it is.
"""
function timed(f::Function; enabled::Bool = true)
    enabled || return f()
    cpu_probe()                           # compiled before it is timed
    Base.cumulative_compile_timing(true)
    clock = Clock()
    logger = TimingLogger(Logging.current_logger(), clock)
    try
        return Logging.with_logger(f, logger)
    finally
        clock.finish = clock.now()
        clock.final = clock.sample()
        Base.cumulative_compile_timing(false)
        @info report(clock)
    end
end

end # module
