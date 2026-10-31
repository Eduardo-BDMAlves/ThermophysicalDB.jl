@testitem "documentation timing: marks, durations and report" tags = [:unit, :fast] begin
    using Logging, Test
    include(joinpath(pkgdir(ThermophysicalDB), "docs", "DocsTiming.jl"))
    D = DocsTiming

    # modules with the names Documenter and its plugins send the messages that open the phases
    Doc = Module(:Documenter)
    Cit = Module(:DocumenterCitations)
    Vit = Module(:DocumenterVitepress)
    Other = Module(:Other)

    @testset "which messages open a phase" begin
        @test D.phase_label(Doc, "Doctest: running doctests.") == "Doctest"
        @test D.phase_label(Doc, "SetupBuildDirectory: setting up build directory.") ==
              "SetupBuildDirectory"
        @test D.phase_label(Cit, "CollectCitations") == "CollectCitations"
        @test D.phase_label(Cit, "ExpandBibliography: expanding blocks.") ==
              "ExpandBibliography"
        @test D.phase_label(Vit, "DocumenterVitepress: building Vitepress site 1 of 1") ==
              "VitePress build (npm)"
        @test D.phase_label(Vit, "Copied: components/Authors.vue") === nothing
        @test D.phase_label(Doc, "Automatic `version=\"0.1.0\"` for inventory") === nothing
        @test D.phase_label(Other, "Doctest: running doctests.") === nothing
        @test D.phase_label(nothing, "Doctest: x") === nothing
    end

    # a fake clock: the test sets the time before each message
    now_time = Ref(0.0)
    clock = D.Clock(() -> now_time[])
    inner = ConsoleLogger(IOBuffer(), Logging.Info)
    logs = Test.TestLogger()
    logger = D.TimingLogger(logs, clock)

    send(level, mod, text; group = :g) =
        Logging.handle_message(logger, level, text, mod, group, :id, "file.jl", 1)

    @testset "the logger asks for the page announcements and nothing else at debug level" begin
        quiet = D.TimingLogger(inner, D.Clock(() -> 0.0))
        @test Logging.shouldlog(quiet, Logging.Debug, Doc, :expander_pipeline, :x)
        @test !Logging.shouldlog(quiet, Logging.Debug, Doc, :other_file, :x)
        @test !Logging.shouldlog(quiet, Logging.Debug, Other, :expander_pipeline, :x)
        @test Logging.shouldlog(quiet, Logging.Info, Other, :g, :x)
        @test Logging.min_enabled_level(quiet) == Logging.Debug
    end

    now_time[] = 1.0
    send(Logging.Info, Doc, "SetupBuildDirectory: setting up build directory.")
    now_time[] = 2.0
    send(Logging.Info, Doc, "ExpandTemplates: expanding markdown templates.")
    send(Logging.Debug, Doc, "Running ExpanderPipeline on a.md"; group = :expander_pipeline)
    send(Logging.Debug, Doc, "pages"; group = :expander_pipeline)      # not an announcement
    now_time[] = 6.0
    send(Logging.Debug, Doc, "Running ExpanderPipeline on b.md"; group = :expander_pipeline)
    now_time[] = 9.0
    send(Logging.Info, Cit, "CollectCitations")
    send(Logging.Info, Other, "an unrelated message")
    now_time[] = 10.0
    send(Logging.Info, Doc, "RenderDocument: rendering document.")
    clock.finish = 14.0

    @testset "messages are passed on, stamped when they open a phase" begin
        texts = [string(l.message) for l in logs.logs]
        # the page announcements become Info lines; the unrelated debug message is dropped
        @test length(texts) == 7
        @test startswith(texts[1], "SetupBuildDirectory: setting up build directory. [")
        @test occursin("| +1.00 s | 1.00 s]", texts[1])
        @test startswith(texts[3], "Page a.md [")
        @test startswith(texts[4], "Page b.md [")
        @test occursin("| +4.00 s | 6.00 s]", texts[4])      # b.md begins 4 s after a.md
        @test startswith(texts[5], "CollectCitations [")
        @test texts[6] == "an unrelated message"
        @test startswith(texts[7], "RenderDocument: rendering document. [")
        @test logs.logs[3].level == Logging.Info
    end

    @testset "blocks are timed and left out of the log" begin
        blocks = D.Clock(() -> now_time[])
        bl = D.TimingLogger(Test.TestLogger(), blocks)
        sendb(text) = Logging.handle_message(
            bl,
            Logging.Debug,
            text,
            Doc,
            :expander_pipeline,
            :id,
            "f.jl",
            1,
        )
        now_time[] = 0.0
        sendb("Running ExpanderPipeline on p.md")
        now_time[] = 1.0
        sendb("Evaluating @example block:\n# a comment\nusing Foo\nx = 1")
        now_time[] = 4.0
        sendb("Evaluating @setup block:\n" * repeat("y", 100))
        now_time[] = 10.0
        Logging.handle_message(
            bl,
            Logging.Info,
            "RenderDocument: x",
            Doc,
            :g,
            :id,
            "f.jl",
            1,
        )
        blocks.finish = 12.0
        d = D.durations(blocks, :block)
        @test d == [
            ("p.md #1 @example: using Foo", 3.0),
            ("p.md #2 @setup: " * repeat("y", 56) * "…", 6.0),
        ]
        # only the page is logged
        @test length(bl.inner.logs) == 2
        # the stamp of a page or phase ignores the blocks between them
        @test occursin("| +10.0 s |", string(bl.inner.logs[2].message))
        @test occursin("Slowest code blocks", D.report(blocks))
        @test D.block_label("p.md", 1, "Running ExpanderPipeline on p.md") === nothing
    end

    @testset "durations" begin
        @test D.durations(clock, :phase) == [
            ("SetupBuildDirectory", 1.0),
            ("ExpandTemplates", 7.0),
            ("CollectCitations", 1.0),
            ("RenderDocument", 4.0),
        ]
        # the last page ends when the next phase begins
        @test D.durations(clock, :page) == [("a.md", 4.0), ("b.md", 3.0)]
    end

    @testset "report" begin
        text = D.report(clock)
        @test startswith(text, "Build timing: 14.0 s in total")
        @test occursin("ExpandTemplates", text) && occursin("50%", text)
        # pages are listed in the order they ran
        @test findfirst("a.md", text).start < findfirst("b.md", text).start
    end

    @testset "garbage collection, compilation, heap and speed of the machine" begin
        t = Ref(0.0)
        gc = Ref(0.0)
        comp = Ref(0.0)
        probe = Ref(0.5)
        sample() = D.Sample(gc[], comp[], 2.0^30)
        c = D.Clock(() -> t[]; sample, probe = () -> probe[])
        lg = D.TimingLogger(Test.TestLogger(), c)
        send2(level, mod, text; group = :g) =
            Logging.handle_message(lg, level, text, mod, group, :id, "f.jl", 1)
        t[] = 1.0
        send2(Logging.Info, Doc, "ExpandTemplates: expanding markdown templates.")
        send2(
            Logging.Debug,
            Doc,
            "Running ExpanderPipeline on a.md";
            group = :expander_pipeline,
        )
        t[] = 11.0
        gc[] = 2.0
        comp[] = 6.0
        probe[] = 1.0                  # the machine is twice as slow from here
        send2(
            Logging.Debug,
            Doc,
            "Running ExpanderPipeline on b.md";
            group = :expander_pipeline,
        )
        t[] = 21.0
        gc[] = 5.0
        comp[] = 6.5
        c.finish = 25.0
        c.final = sample()
        pages = D.rows(c, :page)
        @test [r.label for r in pages] == ["a.md", "b.md"]
        @test pages[1].seconds == 10.0 && pages[1].gc == 2.0 && pages[1].compile == 6.0
        @test pages[2].seconds == 14.0 && pages[2].gc == 3.0 && pages[2].compile == 0.5
        @test pages[2].heap == 2.0^30
        @test D.fastest_probe(c) == 0.5
        text = D.report(c)
        @test occursin("cpu x1.00", text)
        @test occursin("cpu x2.00", text)
        @test occursin("heap   1.00 GiB", text) || occursin("1.00 GiB", text)
        @test occursin("Peak memory of the process", text)
        # the real sample and probe work and cost little
        s0 = D.process_sample()
        @test s0.gc >= 0 && s0.compile >= 0
        @test 0 < D.cpu_probe() < 5
    end

    @testset "timed" begin
        @test D.timed(() -> 42; enabled = false) == 42
        @test_logs (:info, r"Build timing") @test D.timed(() -> 42) == 42
        # the table is logged also when the build fails
        @test_logs (:info, r"Build timing") @test_throws ErrorException D.timed(
            () -> error("failed"),
        )
    end
end
