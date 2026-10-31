# What is compiled ahead of time, so that the first call of each function after
# `using ThermophysicalDB` does not wait for the compiler (PrecompileTools.jl).
#
# The rules of this file:
#
# * Only work that needs nothing from outside the process: no network, no files of the
#   user, no prompt. In particular `database`, `ensure_archive`, `update_database!` and
#   `install_release` are never called here: downloading can fail and ask the user what to
#   do, and a precompilation has nobody to ask. (`test/test-precompile.jl` checks that.)
# * Data are built in memory from literals, inside `@setup_workload`, which is run during
#   precompilation but is not itself compiled into the package.
# * Everything inside `@compile_workload` is run once at precompilation and the methods it
#   reaches are stored in the package's cache.
#
# To add a workload, put the calls inside `@compile_workload`, with the data it needs
# built in `@setup_workload` above it. Set the preference `precompile_workload` of
# PrecompileTools to `false` (see its documentation) to skip all of this while developing.

using PrecompileTools: @compile_workload, @setup_workload

@setup_workload begin
    # Data for the workloads go here, built from literals only.
    entries = [
        BibEntry(
            "article",
            "",
            [
                "author" => "Doe, Jane and Roe, Richard",
                "title" => "A fictitious article",
                "year" => "2000",
                "doi" => "10.5555/precompile",
            ],
        ),
    ]
    @compile_workload begin
        # the notice and the references that every export writes
        notice_text()
        first_download_message()
        # citation keys, and the entries as they are written
        assign_keys!(entries, Set{String}())
        io = IOBuffer()
        render_entry(io, only(entries))
        render_entry(io, first(source_entries()))
        parse_bibtex(String(take!(io)))
        # TODO: workloads for `points`, `table`, `export_points` and `find_outliers` on a
        # small Dataset built in memory.
    end
end
