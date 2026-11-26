@testmodule WorkData begin
    using ThermophysicalDB: ThermophysicalDB
    using ..TwoDatabases: TwoDatabases
    using ..OwnData: OwnData
    const T = ThermophysicalDB

    # The archive (5 points of a mass density of water), a database of literature (3 points) and
    # one of the user (3 points), both of water.
    function database(dir)
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        root = joinpath(dir, "databases")
        T.add_database!(db, "papers"; kind = :literature, dir = root)
        T.add_database!(db, "my_lab"; dir = root)
        for (name, doi, base) in
            (("papers", "10.5555/lit-1", 1000.0), ("my_lab", "10.5555/mine-1", 1002.0))
            ref = T.add_reference!(db; database = name, doi, year = 2020)
            exp = T.add_experiment!(ref; components = [TwoDatabases.WATER])
            for (k, temperature) in enumerate((290.0, 300.0, 310.0))
                T.add_measurement!(
                    exp;
                    property = "Mass density",
                    unit = "kg/m3",
                    value = base - k,
                    temperature,
                    pressure = 101.325,
                )
            end
        end
        return db, root
    end
end

@testitem "a publication is checked and described" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    p = T.Publication()
    @test p.label == "This work" && p.note == "in preparation" && p.year == 0
    q = T.Publication(;
        label = " Present study ",
        title = "A new rig",
        authors = ["Alves, E.", " "],
        year = 2026,
    )
    @test q.label == "Present study" && q.authors == ["Alves, E."]
    @test_throws ArgumentError T.Publication(; label = " ")
    @test_throws ArgumentError T.Publication(; label = "Literature")
    @test_throws ArgumentError T.Publication(; year = 12)
    @test T.Publication() == T.Publication()
    @test T.Publication() != q
    @test hash(T.Publication()) == hash(T.Publication())
    @test sprint(show, q) == "Publication(\"Present study\", \"A new rig\", 2026)"
    # The description in the file of a database gives the same publication back.
    @test T.publication_from_toml(T.publication_toml(q)) == q
    @test T.publication_from_toml(T.publication_toml(p)) == p
    @test haskey(T.publication_toml(q), "authors")
    @test !haskey(T.publication_toml(p), "doi")
end

@testitem "the data of the user are called by the publication in the table" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        @test T.publication(db) === nothing
        v = T.points(db; property = "Mass density")
        @test length(v) == 5 + 3 + 3
        # Nothing changes in the table until the publication is set.
        @test !haskey(T.table(v), :work)
        pub = T.Publication(;
            label = "Present study",
            title = "A new rig",
            authors = ["Alves, E."],
            year = 2026,
        )
        @test T.set_publication!(db, pub) === db
        @test T.publication(db) == pub
        t = T.table(v)
        @test haskey(t, :work) && length(t.work) == 11
        @test t.work[t.database .== "my_lab"] == fill("Present study", 3)
        @test all(==("Literature"), t.work[t.database .!= "my_lab"])
        # The column `source` of the table is still the one of the references.
        @test haskey(t, :source)
        # One database only.
        mine = T.table(T.points(db; doi = "10.5555/mine-1"))
        @test mine.work == fill("Present study", 3)
        # Asked for or refused by the call.
        @test !haskey(T.table(v; this_work = false), :work)
        @test !haskey(T.table(v; this_work = nothing), :work)
        other = T.Publication(; label = "Our rig")
        @test unique(T.table(v; this_work = other).work) == ["Literature", "Our rig"] ||
              sort(unique(T.table(v; this_work = other).work)) == ["Literature", "Our rig"]
        @test_throws ArgumentError T.table(v; this_work = :yes)
        # It is a key to sort by.
        s = T.table(v; sortby = [:work])
        @test issorted(s.work) && s.work[end] == "Present study"
        r = T.table(v; sortby = [:work], rev = true)
        @test r.work[1] == "Present study"
        # Without a publication in the database, one can be asked for.
        T.set_publication!(db, nothing)
        @test T.publication(db) === nothing
        @test !haskey(T.table(v), :work)
        @test sort(unique(T.table(v; this_work = true).work)) == ["Literature", "This work"]
        # It belongs to the databases of the user.
        @test_throws ArgumentError T.set_publication!(db, pub; database = "papers")
        @test_throws ArgumentError T.set_publication!(db, pub; database = "thermoml")
        @test_throws ArgumentError T.set_publication!(db, pub; database = "nope")
    end
    # With no database of the user there is nothing to give it to.
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        @test_throws ArgumentError T.set_publication!(db, T.Publication())
    end
end

@testitem "the publication is kept with the database of the user" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, root = WorkData.database(dir)
        pub = T.Publication(; label = "Present study", year = 2026, doi = "10.5555/new")
        # Before the first save the publication lives in memory and goes to the file with it.
        T.set_publication!(db, pub)
        @test T.save_database(db, "my_lab") |> isfile
        found = T.discover_members(root)
        @test length(found) == 1 && found[1].name == "my_lab"
        @test only(found[1].publications) == pub
        # Changing it afterwards rewrites the description of the saved database.
        newer = T.Publication(; label = "Present study", year = 2027, doi = "10.5555/final")
        T.set_publication!(db, newer)
        @test only(only(T.discover_members(root)).publications) == newer
        T.set_publication!(db, nothing)
        @test isempty(only(T.discover_members(root)).publications)
        # The literature and the archive have none.
        @test all(m -> isempty(m.publications), filter(m -> m.kind !== :user, db.members))
        # Priority changes keep it.
        T.set_publication!(db, pub)
        T.set_priority!(db, "my_lab", 5)
        @test only(only(T.discover_members(root)).publications) == pub
    end
end

@testitem "the figures call the data of the user one group of their own" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        # Without a publication nothing is highlighted, and `:work` asks for what is not there.
        d0 = T.plotdata(db; property = "Mass density")
        @test !any(g -> g.highlight, T.point_groups(d0, :reference))
        @test_throws ArgumentError T.point_groups(d0, :work)
        T.set_publication!(db, T.Publication())
        d = T.plotdata(db; property = "Mass density")
        for by in (:reference, :work, nothing, :method, :year_group)
            groups = T.point_groups(d, by)
            @test last(groups).highlight && last(groups).label == "This work"
            @test length(last(groups).rows) == 3
            @test count(g -> g.highlight, groups) == 1
            @test sum(g -> length(g.rows), groups) == 11
        end
        @test [g.label for g in T.point_groups(d, :work)] == ["Literature", "This work"]
        @test T.point_groups(d, nothing)[1].label == "Literature"
        # The user's points are never put together with the others.
        few = T.point_groups(d, :reference; maxgroups = 2)
        @test "others" in [g.label for g in few] && last(few).label == "This work"
        # A selection without points of the user keeps the groups as they were.
        lit = T.plotdata(db; property = "Mass density", doi = "10.5555/lit-1")
        @test !any(g -> g.highlight, T.point_groups(lit, :reference))
        # The figure: a layer of its own, last, with the marker and the colour of the style.
        style = T.plot_style()
        spec = T.figure_comparison(d; model = (p, t) -> 1000.0)
        for panel in spec.panels
            scatters = [l for l in panel.layers if l.kind === :scatter]
            mine = scatters[end]
            @test mine.label == "This work" && mine.marker === style.highlight_marker
            @test mine.color == style.highlight && mine.size > style.markersize
            @test all(l -> l.marker !== style.highlight_marker, scatters[1:(end-1)])
        end
        neon = T.figure_comparison(d; model = (p, t) -> 1000.0, style = :neon)
        @test last([l for l in neon.panels[1].layers if l.kind === :scatter]).color == T.plot_style(:neon).highlight
        # A label of its own.
        T.set_publication!(db, T.Publication(; label = "Present study"))
        d2 = T.plotdata(db; property = "Mass density")
        @test last(T.point_groups(d2, :reference)).label == "Present study"
        # The panels of a faceted figure and the violins take it too.
        facets = T.figure_facets(d; by = :property)
        @test any(l -> l.label == "This work", facets.panels[1].layers)
        @test T.plot_defaults(; marker_by = :work).marker_by === :work
        empty!(T.PLOT_DEFAULTS)
    end
end

@testitem "cite is checked, kept and shown" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.Publication().cite === :label
    @test T.Publication(; cite = :unpublished).cite === :unpublished
    @test T.Publication(; doi = "10.5555/x", cite = :published).cite === :published
    @test_throws ArgumentError T.Publication(; cite = :published)
    @test_throws ArgumentError T.Publication(; cite = :nothing)
    a = T.Publication(; cite = :unpublished)
    @test a != T.Publication()
    @test T.publication_from_toml(T.publication_toml(a)) == a
    @test T.publication_from_toml(T.publication_toml(T.Publication())).cite === :label
end

@testitem "several databases are exported one after the other" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        v = T.points(db; property = "Mass density")
        @test length(T.parts(v)) == 3
        fetch = _ -> nothing
        opts = (;
            online = false,
            include_package = false,
            include_source = false,
            progress = false,
        )
        # No publication: the references are the ones of the data.
        out = joinpath(dir, "plain")
        r = T.export_points(out, v; formats = (:csv,), opts...)
        lines = readlines(joinpath(out, "plain.csv"))
        @test length(lines) == 1 + length(v)
        @test count(startswith("reference"), lines) == 1
        @test_throws ArgumentError T.export_points(
            joinpath(dir, "xml"),
            v;
            formats = (:thermoml,),
            opts...,
        )

        # `:label`: the data of the user are "This work" and have no entry in the .bib.
        T.set_publication!(
            db,
            T.Publication(; authors = ["Alves, E."], title = "A rig", year = 2026),
        )
        out = joinpath(dir, "label")
        T.export_points(out, v; formats = (:csv, :tex), opts...)
        csv = readlines(joinpath(out, "label.csv"))
        @test count(contains("This work"), csv) == 3
        bib = read(joinpath(out, "label.bib"), String)
        @test !contains(bib, "unpublished") && !contains(bib, "This work")
        tex = read(joinpath(out, "label.tex"), String)
        @test contains(tex, "This work") && !contains(tex, "\\cite{This work}")
        summary = T.reference_summary(v; opts...)
        @test count(==("This work"), summary.key) == 1
        @test sum(summary.n_points) == length(v)

        # `:unpublished` per call: a key and an @unpublished entry.
        out = joinpath(dir, "unpub")
        T.export_points(out, v; formats = (:csv, :tex), cite = :unpublished, opts...)
        bib = read(joinpath(out, "unpub.bib"), String)
        @test contains(bib, "@unpublished{")
        @test contains(bib, "in preparation")
        key = match(r"@unpublished\{([^,]+),", bib)[1]
        @test count(contains(key), readlines(joinpath(out, "unpub.csv"))) == 3
        @test contains(read(joinpath(out, "unpub.tex"), String), "\\cite{$key}")

        # The publication keeps its choice, and a call can change it.
        T.set_publication!(db, T.Publication(; cite = :unpublished, year = 2026))
        @test contains(T.bibtex(v; opts...), "@unpublished{")
        @test !contains(T.bibtex(v; cite = :label, opts...), "@unpublished")
        @test_throws ArgumentError T.bibtex(v; cite = :published, opts...)
        @test_throws ArgumentError T.bibtex(v; cite = :other, opts...)
        # this_work = false: the references are the ones of the data.
        plain = T.bibtex(v; this_work = false, opts...)
        @test !contains(plain, "@unpublished")
        @test contains(plain, "mine-1")
    end
end

@testitem "the article of the publication comes from its DOI" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        v = T.points(db; property = "Mass density")
        text = """
        @article{x,
          author = {Alves, Eduardo and Silva, Ana},
          title = {A rig for water},
          journal = {J. Chem. Eng. Data},
          year = {2026},
          volume = {71},
          doi = {10.1234/rig}
        }
        """
        fetcher = doi -> doi == "10.1234/rig" ? text : error("not found")
        T.set_publication!(
            db,
            T.Publication(; doi = "10.1234/rig", year = 2026, cite = :published),
        )
        opts = (; include_package = false, include_source = false, progress = false)
        out = T.bibtex(v; cache = false, fetcher, opts...)
        @test contains(out, "@article{")
        @test contains(out, "10.1234/rig")
        @test !contains(out, "@unpublished")
        s = T.reference_summary(v; cache = false, fetcher, opts...)
        row = findfirst(==("10.1234/rig"), s.doi)
        @test row !== nothing
        @test s.key[row] != "This work"
        @test s.n_points[row] == 3
        # offline and not cached, the fields of the publication are what is written
        off = T.bibtex(v; online = false, cache = false, opts...)
        @test contains(off, "10.1234/rig")
    end
end

@testitem "a reference moves to another database and the archive is never touched" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        count_points(name) = length(T.points(db; source = name))
        total = length(T.points(db; property = "Mass density"))
        archive = T.member_dataset(db.members[T.member_index(db, "thermoml")])
        before = (count_points("papers"), count_points("my_lab"))
        # The archive is not an origin or a destination.
        @test_throws ArgumentError T.move_reference!(
            db,
            "10.5555/mine-1",
            "thermoml";
            database = "my_lab",
        )
        @test_throws ArgumentError T.move_reference!(
            db,
            "x",
            "papers";
            database = "thermoml",
        )
        # Preview: nothing changes.
        plan = T.move_reference!(db, "10.5555/mine-1", "papers"; database = "my_lab")
        @test !plan.moved && plan.points == before[2] && plan.to == "papers"
        @test (count_points("papers"), count_points("my_lab")) == before
        # The move.
        r = T.move_reference!(
            db,
            "10.5555/mine-1",
            "papers";
            database = "my_lab",
            confirm = true,
        )
        @test r.moved
        @test count_points("papers") == before[1] + before[2]
        @test count_points("my_lab") == 0
        @test length(T.points(db; property = "Mass density")) == total
        @test T.member_dataset(db.members[T.member_index(db, "thermoml")]) === archive
        t = T.table(T.points(db; source = "papers"))
        @test count(==("10.5555/mine-1"), t.doi) == before[2]
        @test_throws ArgumentError T.move_reference!(
            db,
            "10.5555/mine-1",
            "papers";
            database = "papers",
            on_conflict = :nope,
        )
    end
end

@testitem "publish! turns the data of the user into the article" setup =
    [TwoDatabases, OwnData, WorkData] tags = [:unit] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = WorkData.database(dir)
        T.set_publication!(db, T.Publication(; authors = ["Alves, E."], year = 2026))
        text = """
        @article{x,
          author = {Alves, Eduardo and Silva, Ana},
          title = {A rig for water},
          journal = {J. Chem. Eng. Data},
          year = {2026},
          doi = {10.1234/rig}
        }
        """
        fetcher = doi -> doi == "10.1234/rig" ? text : error("not found")
        total = length(T.points(db; property = "Mass density"))
        plan = T.publish!(db; doi = "10.1234/rig", to = "papers", cache = false, fetcher)
        @test !plan.published && plan.resolved && plan.fields.title == "A rig for water"
        @test T.publication(db) !== nothing
        @test_throws ArgumentError T.publish!(db; to = "papers")
        r = T.publish!(
            db;
            doi = "10.1234/rig",
            to = "papers",
            cache = false,
            fetcher,
            confirm = true,
        )
        @test r.published
        @test T.publication(db) === nothing
        @test length(T.points(db; property = "Mass density")) == total
        @test length(T.points(db; source = "my_lab")) == 0
        t = T.table(T.points(db; source = "papers"))
        @test count(==("10.1234/rig"), t.doi) == 3
        bib = T.bibtex(
            T.points(db; source = "papers");
            online = false,
            include_package = false,
            include_source = false,
            progress = false,
        )
        @test contains(bib, "10.1234/rig")
    end
end
