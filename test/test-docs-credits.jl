@testitem "documentation credits: registry, page block and files" setup = [Toy] tags =
    [:unit, :fast] begin
    using Logging, TOML
    T = ThermophysicalDB
    include(joinpath(pkgdir(T), "docs", "DocsCredits.jl"))
    C = DocsCredits
    # the page logs one line about its sources; the tests do not need to show it
    quiet(f) = Logging.with_logger(f, Logging.NullLogger())

    ds = Toy.build()
    all_rows = T.DataView(ds).rows
    first_part = T.DataView(ds, all_rows[1:3])
    last_part = T.DataView(ds, all_rows[3:end])
    html(x) = repr(MIME"text/html"(), x)

    @testset "escaping" begin
        @test C.esc("a\\b<c>") == "a&#92;b&lt;c&gt;"
        @test C.plural(1, "point") == "1 point"
        @test C.plural(3, "article") == "3 articles"
    end

    @testset "block of a page" begin
        C.reset!()
        text = html(C.credits(first_part))
        @test occursin("<strong>3 points</strong>", text)
        @test occursin("<table>", text)
        @test !occursin("\n\n", text)                 # a blank line would end the HTML block
        s = T.reference_summary(
            first_part;
            online = false,
            cache = false,
            include_source = false,
            include_package = false,
            progress = false,
        )
        @test occursin(C.plural(length(unique(s.key)), "article"), text)
        # the table of a page has no citation key column
        @test !occursin("<th>Key</th>", text)
        # an empty selection says so
        @test occursin("no points", html(C.credits(T.DataView(ds, Int32[]))))
    end

    @testset "registry joins the selections of all pages" begin
        C.reset!()
        @test C.registered_view() === nothing
        C.credits(first_part)
        C.credits(last_part)
        joined = C.registered_view()
        @test joined.rows == all_rows
        @test C.union_view([first_part, last_part]).rows == all_rows
        @test_throws ArgumentError C.credits(first_part, T.DataView(Toy.build(), all_rows))
        @test_throws ArgumentError C.union_view(T.DataView[])
    end

    @testset "page of credits and the file for download" begin
        C.reset!()
        @test occursin("No page", html(quiet(() -> C.credits_page())))
        C.credits(T.DataView(ds))
        dir = mktempdir()
        path = joinpath(dir, "public", "data-credits.bib")
        text = html(quiet(() -> C.credits_page(; path, online = false, cache = false)))
        @test isfile(path)
        bib = read(path, String)
        s = T.reference_summary(
            T.DataView(ds);
            online = false,
            cache = false,
            include_package = false,
            progress = false,
        )
        for key in unique(s.key)
            @test occursin(key, text)                  # the table lists the key
            @test occursin("{" * key * ",", bib)       # and the file has the entry
        end
        @test occursin("<th>Key</th>", text)
        @test !occursin("\n\n", text)
    end

    @testset "the resolver is contacted only when the build asks for it" begin
        name = "THERMOPHYSICALDB_DOCS_ONLINE"
        withenv(name => nothing) do
            @test !C.docs_online()
        end
        withenv(name => "true") do
            @test C.docs_online()
        end
        withenv(name => "TRUE") do
            @test C.docs_online()
        end
        withenv(name => "false") do
            @test !C.docs_online()
        end
    end

    @testset "versions" begin
        @test C.install_snippet(
            ["Alpha" => "1.2.3", "Stats" => nothing],
            (; commit = "abc123", dirty = false),
            "https://example.org/repo.jl",
        ) == """
        using Pkg
        Pkg.activate(; temp = true)
        Pkg.add([
            PackageSpec(name = "Alpha", version = "=1.2.3"),
        ])
        Pkg.add(url = "https://example.org/repo.jl", rev = "abc123")
        """
        @test !occursin(
            "rev",
            C.install_snippet(
                Pair{String,Union{Nothing,String}}[],
                nothing,
                "https://example.org/r",
            ),
        )

        path = joinpath(mktempdir(), "public", "versions.toml")
        text = html(C.environment(; path))
        data = TOML.parsefile(path)
        @test data["julia"] == string(VERSION)
        @test data["thermophysicaldb"]["version"] == string(pkgversion(T))
        @test data["packages"] isa Dict
        @test haskey(data, "documentation_tooling")
        @test occursin("<code>$(VERSION)</code>", text)
        @test occursin("Pkg.add", text)
        @test !occursin("\n\n", text)
    end
end
