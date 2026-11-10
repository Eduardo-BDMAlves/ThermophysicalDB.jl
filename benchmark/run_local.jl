# Runs the benchmarks on this machine: the working copy ("dirty") against a base revision, and
# prints the table of the times and of the allocated memory.
#
#     julia benchmark/run_local.jl [base revision = main] [size = small]
#
# The size is `small`, `medium` or `full` (see `data.jl`). It needs AirspeedVelocity.jl in the
# default environment: `julia -e 'using Pkg; Pkg.add("AirspeedVelocity")'`.

using AirspeedVelocity: benchpkg, benchpkgtable

base = length(ARGS) >= 1 ? ARGS[1] : "main"
ENV["TDB_BENCH_SCALE"] = length(ARGS) >= 2 ? ARGS[2] : "small"

root = dirname(@__DIR__)
results = joinpath(root, "benchmark", "results")
mkpath(results)
revisions = string(base, ",dirty")

benchpkg("ThermophysicalDB"; rev = revisions, path = root, output_dir = results)
benchpkgtable(
    "ThermophysicalDB";
    rev = revisions,
    path = root,
    input_dir = results,
    mode = "time,memory",
    ratio = true,
)
