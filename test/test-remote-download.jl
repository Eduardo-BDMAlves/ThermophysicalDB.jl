@testitem "download_file stops at the first strategy that works" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    calls = String[]
    ok(name) = T.DownloadStrategy(
        name,
        () -> true,
        (url, dest; progress, timeout) ->
            (push!(calls, name); write(dest, "data"); dest),
    )
    mktempdir() do dir
        dest = joinpath(dir, "f.bin")
        @test T.download_file(
            "https://example.invalid/f",
            dest;
            strategies = [ok("a"), ok("b")],
        ) == dest
        @test read(dest, String) == "data"
        @test calls == ["a"]
    end
end

@testitem "download_file falls back to the next strategy and then retries" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    state = Ref(0)
    pauses = Float64[]
    broken = T.DownloadStrategy(
        "broken",
        () -> true,
        (url, dest; progress, timeout) ->
            (write(dest, "partial"); error("empty reply")),
    )
    # Works only from the third round on.
    late = T.DownloadStrategy(
        "late",
        () -> true,
        function (url, dest; progress, timeout)
            state[] += 1
            state[] < 3 && error("refused $(state[])")
            write(dest, "full")
            return dest
        end,
    )
    unavailable =
        T.DownloadStrategy("absent", () -> false, (a, b; kw...) -> error("must not run"))
    mktempdir() do dir
        dest = joinpath(dir, "f.bin")
        result =
            @test_logs (:warn, r"attempt 1 of 4") (:warn, r"attempt 2 of 4") match_mode =
                :any T.download_file(
                "https://example.invalid/f",
                dest;
                strategies = [broken, unavailable, late],
                pause = s -> push!(pauses, s),
            )
        @test result == dest && read(dest, String) == "full"
        @test pauses == [2.0, 5.0]
    end
end

@testitem "download_file gives up with an explanation after every attempt" tags =
    [:unit, :fast] begin
    using Base.CoreLogging: NullLogger, with_logger
    T = ThermophysicalDB
    pauses = Float64[]
    broken = T.DownloadStrategy(
        "broken",
        () -> true,
        (url, dest; progress, timeout) ->
            (write(dest, "partial"); error("empty reply")),
    )
    mktempdir() do dir
        dest = joinpath(dir, "f.bin")
        err = try
            with_logger(NullLogger()) do
                T.download_file(
                    "https://example.invalid/f",
                    dest;
                    strategies = [broken, broken],
                    pause = s -> push!(pauses, s),
                )
            end
            nothing
        catch e
            e
        end
        @test err isa T.DownloadError
        @test length(err.failures) == 8            # 4 attempts x 2 strategies
        @test occursin("attempt 4, broken: empty reply", err.failures[end])
        @test pauses == [2.0, 5.0, 10.0]           # no pause after the last attempt
        @test !isfile(dest)                         # the partial file is removed
        message = sprint(showerror, err)
        @test occursin("https://example.invalid/f", message)
        @test occursin("install_archive!", message)
        @test occursin("HTTPS_PROXY", message)
    end
end

@testitem "the default strategies are the three expected ways" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test [s.name for s in T.DOWNLOAD_STRATEGIES] == [
        "Julia Downloads",
        "Julia Downloads with a browser-style User-Agent",
        "system curl",
    ]
    @test T.DOWNLOAD_STRATEGIES[3].available() == (T.curl_executable() !== nothing)
end
