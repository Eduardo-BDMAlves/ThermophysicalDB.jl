# Quality checks over the whole package. Aqua looks for ambiguous methods, stale or unbounded
# dependencies, undefined exports and type piracy; JET follows type inference through the code and
# reports what would raise an error (a value that may be `nothing` or `missing`, a method that does
# not exist for a type that can reach it).

@testitem "Aqua: no ambiguities, stale dependencies, missing compat, unbound arguments or piracy" tags =
    [:quality] begin
    using Aqua
    Aqua.test_all(ThermophysicalDB)
end

@testitem "JET: type inference finds no errors in the package" tags = [:quality] begin
    using JET
    JET.test_package(ThermophysicalDB; target_modules = (ThermophysicalDB,))
end

# Code complexity (CodeComplexity.jl). The limits are the largest values the package has today, so
# no function gets more complex than the worst ones already are; they are meant to be lowered as
# those functions are split (see the list of the worst ones printed when a limit is exceeded).
# The check reads the source files, so it does not depend on the operating system and runs on the
# same runners as the other `:quality` items.
@testsnippet Complexity begin
    using CodeComplexity
    using ThermophysicalDB: ThermophysicalDB

    # Every function of `src` whose measure is above `limit`, worst first, as
    # `(value, name, file, line)`.
    function above_limit(metric, limit)
        found = Tuple{Int,String,String,Int}[]
        for file in measure_directory(
            metric,
            joinpath(pkgdir(ThermophysicalDB), "src");
            max_value = limit,
        )
            for f in file.functions
                f.value > limit &&
                    push!(found, (f.value, string(f.name), file.path, f.line))
            end
        end
        return sort!(found; rev = true)
    end

    describe(found) = join(
        (
            "  $(v) $(name) ($(relpath(path, pkgdir(ThermophysicalDB))):$(line))" for
            (v, name, path, line) in first(found, 10)
        ),
        "\n",
    )
end

@testitem "complexity: cyclomatic complexity of every function is within the limit" setup =
    [Complexity] tags = [:quality] begin
    limit = 84
    found = above_limit(CyclomaticComplexity(), limit)
    @test isempty(found)
    isempty(found) || @info "cyclomatic complexity above $limit" found = describe(found)
end

@testitem "complexity: cognitive complexity of every function is within the limit" setup =
    [Complexity] tags = [:quality] begin
    limit = 131
    found = above_limit(CognitiveComplexity(), limit)
    @test isempty(found)
    isempty(found) || @info "cognitive complexity above $limit" found = describe(found)
end

@testitem "complexity: argument count of every function is within the limit" setup =
    [Complexity] tags = [:quality] begin
    limit = 22
    found = above_limit(ArgumentCountComplexity(), limit)
    @test isempty(found)
    isempty(found) || @info "argument count above $limit" found = describe(found)
end
