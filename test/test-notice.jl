@testitem "the notice is built from one place and says what NIST asked for" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    entries = T.notice_entries()
    fields = first.(entries)
    @test fields == [
        "data origin",
        "archive url",
        "dataset doi",
        "dataset citation",
        "notice",
        "credit",
        "terms",
    ]
    text = T.notice_text()
    # the full citation of the dataset, with its version
    @test occursin("Riccardi, D.", T.ARCHIVE_CITATION)
    @test occursin("Muzny, C. D.", T.ARCHIVE_CITATION)
    @test occursin("version 1.2", T.ARCHIVE_CITATION)
    @test occursin("https://doi.org/10.18434/mds2-2422", T.ARCHIVE_CITATION)
    @test occursin(T.ARCHIVE_CITATION, text)
    # modified, not endorsed, credit the source
    @test occursin("modified data", text)
    @test occursin("not evaluated or endorsed by NIST/TRC", text)
    @test occursin("credit the original article", text)
    @test occursin(T.NOTICE_URL, text)
    @test length(T.notice_lines()) == length(entries)
    @test !occursin('\n', T.notice_line())
    # an HTML comment must not contain `--`
    @test !occursin("--", text)

    message = T.first_download_message()
    @test occursin("version 1.2", message) && occursin("10.18434/mds2-2422", message)
    @test occursin("not evaluated or endorsed by NIST/TRC", message)
    @test occursin(T.NOTICE_URL, message)
end

@testitem "every export format of archive data carries the notice" setup = [Toy] tags =
    [:unit] begin
    using XLSX
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    quiet = (; online = false, cache = false, progress = false)
    has_notice(text) =
        occursin("dataset citation", text) &&
        occursin("version 1.2", text) &&
        occursin("not evaluated or endorsed by NIST/TRC", text) &&
        occursin("credit the original article", text) &&
        occursin(T.NOTICE_URL, text)
    # field names and texts of a record, as one string (the fields are part of the notice)
    flat(record) =
        join((string(replace(k, '_' => ' '), ": ", v) for (k, v) in record), "; ")
    mktempdir() do tmp
        # CSV and LaTeX: a comment on the first line
        _, csv = Toy.export1(joinpath(tmp, "w.csv"), v; quiet...)
        @test startswith(readline(csv), "# data origin: ")
        @test has_notice(readline(csv))
        _, tex = Toy.export1(joinpath(tmp, "w.tex"), v; quiet...)
        @test startswith(readline(tex), "% data origin: ")
        @test has_notice(readline(tex))

        # JSON, in both layouts
        _, json = Toy.export1(joinpath(tmp, "w.json"), v; quiet...)
        origin = T.JSON.parse(read(json, String))["origin"]
        @test has_notice(flat(origin))
        @test haskey(origin, "dataset_citation") && haskey(origin, "credit")
        thermoml =
            only(T.export_points(joinpath(tmp, "t"), v; formats = (:thermoml,)).files)
        @test has_notice(flat(T.JSON.parse(read(thermoml, String))["origin"]))

        # JLD2
        _, jld2 = Toy.export1(joinpath(tmp, "w.jld2"), v; quiet...)
        T.JLD2.jldopen(jld2, "r") do f
            @test has_notice(flat(Dict(k => f["origin/$k"] for k in keys(f["origin"]))))
        end

        # XLSX: the origin sheet
        _, xlsx = Toy.export1(joinpath(tmp, "w.xlsx"), v; quiet...)
        table = XLSX.readtable(xlsx, "origin")
        @test has_notice(join(table.data[1], " ") * " " * join(table.data[2], " "))
        @test "dataset citation" in table.data[1]

        # the references written with a table: CSV, LaTeX and the BibTeX
        @test startswith(
            readline(joinpath(tmp, "w", "w_references.csv")),
            "# data origin: ",
        )
        @test startswith(
            readline(joinpath(tmp, "w", "w_references.tex")),
            "% data origin: ",
        )
        bib = read(joinpath(tmp, "w", "w.bib"), String)
        @test startswith(bib, "@comment{") && has_notice(bib)
        # the comment is closed before the first entry
        @test findfirst("}\n\n@", bib) !== nothing
    end

    # the summary tables, and the choice to leave the notice out
    s = T.reference_summary(ds; quiet...)
    tex = T.latex_table(s)
    @test startswith(tex, "% data origin: ") && has_notice(tex)
    md = T.markdown_table(s)
    @test startswith(md, "<!--\ndata origin: ") && has_notice(md)
    @test occursin("-->\n\n| ", md)
    csv = T.csv_table(s)
    @test startswith(csv, "# data origin: ") && has_notice(csv)
    for text in (
        T.latex_table(s; notice = false),
        T.markdown_table(s; notice = false),
        T.csv_table(s; notice = false),
    )
        @test !occursin("dataset citation", text)
    end
    @test has_notice(T.bibtex(s))

    # write_references writes it in all four files
    mktempdir() do tmp
        T.write_references(joinpath(tmp, "refs"), ds; quiet...)
        for ext in (".bib", ".tex", ".md", ".csv")
            @test has_notice(read(joinpath(tmp, "refs" * ext), String))
        end
    end
end

@testitem "data that are not from the archive carry no notice" setup = [Toy] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    mine = T.points(ds; source = "user")
    @test !T.from_archive(mine) && T.from_archive(T.points(ds; source = "thermoml"))
    mktempdir() do tmp
        for ext in (".csv", ".tex", ".md", ".json", ".jld2")
            _, file = Toy.export1(
                joinpath(tmp, "mine" * ext),
                mine;
                references = false,
                reference = :doi,
                online = false,
                cache = false,
                progress = false,
            )
            @test !occursin("dataset citation", read(file, String))
        end
    end
    s = T.reference_summary(mine; online = false, cache = false, progress = false)
    @test !occursin("dataset citation", T.csv_table(s))
    @test !occursin("dataset citation", T.latex_table(s))
    @test !occursin("dataset citation", T.markdown_table(s))
    @test !startswith(
        T.bibtex(mine; online = false, cache = false, progress = false),
        "@comment",
    )
end

@testitem "references = false with reference = :key warns, because the DOIs are lost" setup =
    [Toy] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = Toy.build()
    v = T.points(ds; property = "Mass density")
    quiet = (; online = false, cache = false, progress = false)
    mktempdir() do tmp
        warns = (:warn, r"references = false with reference = :key.*DOI")
        one(name, formats; kwargs...) =
            T.export_points(joinpath(tmp, name), v; formats, quiet..., kwargs...)
        @test_logs warns one("a", (:csv,); references = false)
        @test_logs warns one("b", (:tex,); references = false)
        @test_logs warns one("c", (:md,); references = false)
        @test_logs warns one("d", (:csv, :json); references = false)

        # no warning when the DOI stays reachable
        @test_logs one("e", (:csv,); references = false, reference = :doi)
        @test_logs one("f", (:csv,); references = false, reference = :text)
        @test_logs one("g", (:csv,))
        # these formats hold their references table
        @test_logs one("h", (:json,); references = false)
        @test_logs one("i", (:jld2,); references = false)
        @test_logs T.export_points(
            joinpath(tmp, "j"),
            v;
            formats = (:thermoml,),
            references = false,
        )
    end
end

@testitem "the first download shows the notice, an update does not" setup = [Fixtures] tags =
    [:unit] begin
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(joinpath(tmp, "payload.tgz"), Dict("a.json" => "{}"))
        download = Fixtures.fake_download(tgz, ThermophysicalDB.file_sha256(tgz))
        dir = joinpath(tmp, "cache")
        old = Fixtures.make_release("2024-01-01")
        new = Fixtures.make_release("2025-06-01")

        # nothing installed: the download and then the notice
        manifest = @test_logs (:info, r"Downloading") (
            :info,
            r"Data from the NIST/TRC ThermoML Archive.*version 1\.2.*not evaluated or endorsed.*NOTICE\.md",
        ) ThermophysicalDB.install_release(old; dir, download)
        @test manifest.version == "2024-01-01"

        # an archive is installed: the download only
        manifest = @test_logs (:info, r"Downloading") ThermophysicalDB.install_release(
            new;
            dir,
            download,
        )
        @test manifest.version == "2025-06-01"
    end
end
