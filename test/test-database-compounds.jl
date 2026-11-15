@testitem "a database with the compound database attached understands compounds by any name" tags =
    [:unit] setup = [CompoundFixture] begin
    using Tables: Tables
    using Logging: Logging
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        function dataset(doi, name, inchikey, formula)
            ds = T.Dataset()
            mole = T.intern!(ds.kinds, "Mole fraction")
            source = T.intern!(ds.sources, "fixture")
            ref = T.add_reference!(ds.references; doi, source)
            id = T.add_compound!(ds.compounds; inchikey, names = [name], formula)
            density = T.add_property!(ds.properties, "Mass density", "kg/m3")
            e = T.add_experiment!(
                ds.experiments;
                reference = ref,
                components = [id],
                kinds = [mole],
            )
            for i = 1:3
                T.add_measurement!(
                    ds.measurements;
                    experiment = e,
                    property = density,
                    temperature = 290.0 + i,
                    pressure = 101.325,
                    value = 1.0,
                )
            end
            return ds
        end
        water = "XLYOFNOQVPJJNP-UHFFFAOYSA-N"
        methane = "VNWKTOKETHGBQD-UHFFFAOYSA-N"
        function members()
            return [
                T.Member(
                    "one";
                    kind = :thermoml,
                    dataset = dataset("10.5555/d-1", "water", water, "H2O"),
                ),
                T.Member(
                    "two";
                    kind = :user,
                    dataset = dataset("10.5555/d-2", "aqua", water, "H2O"),
                ),
                T.Member(
                    "three";
                    kind = :user,
                    dataset = dataset("10.5555/d-3", "methane", methane, "CH4"),
                ),
            ]
        end

        # Nothing is attached to a database that is built by hand, and nothing breaks.
        plain = T.Database(members())
        @test plain.compounds === nothing && plain.compound_loader === nothing
        @test occursin(
            "no compound database attached",
            sprint(show, MIME("text/plain"), plain),
        )
        @test_throws ArgumentError T.link_table(plain)
        @test_throws ArgumentError lookup_compounds(plain, "water")
        @test length(points(plain; component = "aqua")) == 3

        # The compound database is loaded when a name has to be understood, once.
        calls = Ref(0)
        db = T.Database(members())
        db.compound_loader = () -> (calls[] += 1; cdb)
        @test occursin("loaded when a name", sprint(show, MIME("text/plain"), db))
        @test length(points(db; property = "Mass density")) == 9    # no name: nothing loaded
        @test calls[] == 0
        @test length(points(db; component = "oxidane")) == 6
        @test calls[] == 1
        @test length(points(db; component = "7732-18-5")) == 6
        @test calls[] == 1
        @test occursin("(", sprint(show, MIME("text/plain"), db)) && db.compounds === cdb

        # A compound that only one database has is the only one asked
        view = points(db; component = "marsh gas")
        @test length(view) == 3 && [db.members[i].name for i in view.index] == ["three"]

        # What a lookup finds is accepted as a component, whole or in part
        found = lookup_compounds(db, "oxidane")
        @test found isa T.CompoundRecords && length(found) >= 1
        @test length(points(db; component = found)) == 6
        @test length(points(db; component = found[1])) == 6
        @test length(found[[1]]) == 1
        @test length(points(db; component = [found, "methane"])) == 9
        @test_throws ArgumentError points(
            db;
            component = lookup_compounds(db, "sodium chloride"),    # no database measured it
        )

        # A view is refined with the same names
        refined = points(points(db; property = "Mass density"); component = "oxidane")
        @test length(refined) == 6

        # The table of links is made when asked for, and made again when the members change
        @test db.links === nothing
        links = T.link_table(db)
        @test sort!(unique(links.database)) == ["one", "three", "two"]
        @test db.links !== nothing
        T.remove_member!(db, "three")
        @test db.links === nothing && isempty(db.choices)
        @test sort!(unique(T.link_table(db).database)) == ["one", "two"]
        @test_throws ArgumentError points(db; component = "marsh gas")

        # link_compounds! attaches a compound database to a database of one's own
        mine = T.link_compounds!(T.Database(members()), cdb)
        @test mine.compounds === cdb && mine.compound_loader === nothing
        @test length(points(mine; component = "oxidane")) == 6
        @test length(T.find_compounds(mine, "oxidane")) == 1

        # A compound database that cannot be loaded is a warning, once; then names are the dataset's
        failing = T.Database(members())
        tries = Ref(0)
        failing.compound_loader = () -> (tries[] += 1; error("no network"))
        Logging.with_logger(Logging.NullLogger()) do
            @test length(points(failing; component = "aqua")) == 3
            @test_throws ArgumentError points(failing; component = "oxidane")
        end
        @test tries[] == 1
        @test_logs (:warn, r"could not be loaded") begin
            again = T.Database(members())
            again.compound_loader = () -> error("no network")
            points(again; component = "aqua")
        end
    end
end

@testitem "the amounts of a fraction are understood by every database that is asked" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        function pure(doi, name, inchikey)
            ds = T.Dataset()
            source = T.intern!(ds.sources, "fixture")
            ref = T.add_reference!(ds.references; doi, source)
            id = T.add_compound!(ds.compounds; inchikey, names = [name])
            return ds, ref, id
        end
        water = "XLYOFNOQVPJJNP-UHFFFAOYSA-N"
        methane = "VNWKTOKETHGBQD-UHFFFAOYSA-N"
        a, _, _ = pure("10.5555/f-1", "methane", methane)
        b, _, _ = pure("10.5555/f-2", "water", water)
        db = T.Database([
            T.Member("one"; kind = :thermoml, dataset = a),
            T.Member("two"; kind = :user, dataset = b),
        ])
        T.link_compounds!(db, cdb)
        reg = db.registry
        found = T.find_compounds(db, "oxidane")
        # the second database has the compound, the first one does not
        @test T.member_fraction(reg, 1, nothing) == (true, nothing)
        @test T.member_fraction(reg, 1, "water" => (0.1, 0.2)) ==
              (true, ["water" => (0.1, 0.2)])
        ok, _ = T.member_fraction(reg, 1, found => (0.1, 0.2))
        @test !ok
        ok, translated = T.member_fraction(reg, 2, [found => (0.1, 0.2)])
        @test ok && only(translated).first isa T.CompoundMatches
        @test only(translated).first.id == Int32[1] && only(translated).second == (0.1, 0.2)
    end
end

@testitem "database() attaches the compound database without reading it" tags =
    [:integration] setup = [Fixtures, ThermoMLFixture, CompoundFixture] begin
    T = ThermophysicalDB
    mktempdir() do tmp
        tgz = Fixtures.make_tgz(
            joinpath(tmp, "payload.tgz"),
            Dict("10.5555/tdbfixture-001.json" => ThermoMLFixture.JSON),
        )
        release = Fixtures.make_release("2099-01-01")
        dir = joinpath(tmp, "thermoml")
        options = (;
            dir,
            progress = false,
            fetch = () -> release,
            download = Fixtures.fake_download(tgz, T.file_sha256(tgz)),
        )
        cdb = CompoundFixture.database(joinpath(tmp, "compounds"))
        calls = Ref(0)
        T.forget_database!()
        db = T.database(; options..., compound_library = () -> (calls[] += 1; cdb))
        @test db.compounds === nothing && db.compound_loader !== nothing && calls[] == 0
        @test length(points(db)) > 0 && calls[] == 0
        # the default asks for `compound_database()`, and a different choice is a different object
        default = T.database(; options...)
        @test default !== db && default.compound_loader !== nothing
        none = T.database(; options..., compound_library = false)
        @test none.compound_loader === nothing && none.compounds === nothing
        @test T.database(; options..., compound_library = false) === none
        mine = T.database(; options..., compound_library = cdb)
        @test mine.compounds === cdb && mine.compound_loader === nothing
        T.forget_database!()
    end
end

@testitem "a question is asked only where somebody can answer it, and a name is looked up once" tags =
    [:unit] setup = [CompoundFixture] begin
    T = CompoundFixture.T
    mktempdir() do dir
        cdb = CompoundFixture.database(dir)
        ds = T.Dataset()
        mole = T.intern!(ds.kinds, "Mole fraction")
        source = T.intern!(ds.sources, "fixture")
        ref = T.add_reference!(ds.references; doi = "10.5555/q-1", source)
        id = T.add_compound!(
            ds.compounds;
            inchikey = "VNWKTOKETHGBQD-UHFFFAOYSA-N",
            names = ["methane"],
            formula = "CH4",
        )
        density = T.add_property!(ds.properties, "Mass density", "kg/m3")
        e = T.add_experiment!(
            ds.experiments;
            reference = ref,
            components = [id],
            kinds = [mole],
        )
        T.add_measurement!(
            ds.measurements;
            experiment = e,
            property = density,
            temperature = 290.0,
            pressure = 101.325,
            value = 1.0,
        )
        db = T.link_compounds!(T.Database([T.Member("a"; kind = :user, dataset = ds)]), cdb)

        # The streams given by the caller are asked; the terminal only when it is one
        @test T.can_ask(IOBuffer(), IOBuffer())
        @test !T.can_ask(stdin, IOBuffer())
        # A misspelling is an error that lists the close compounds, never a question that waits
        err = try
            points(db; component = "metane")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && occursin("methane", err.msg)
        # ... and a prepared input still answers it
        answer = IOBuffer("1\n")
        @test length(
            points(db; component = "metane", input = answer, output = IOBuffer()),
        ) == 1

        # A text with one answer is kept, and forgotten when the databases change
        T.forget_choices!(db)
        @test isempty(db.choices)
        @test length(points(db; component = "methane")) == 1
        @test haskey(db.choices, "methane")
        T.forget_links!(db)
        @test isempty(db.choices)

        # The search of the compound database does not read every name unless asked to
        @test isempty(T.lookup_local(cdb, "metane"; approximate = false))
        @test !isempty(T.lookup_local(cdb, "metane"))
        found = T.find_compounds(ds, cdb, "74-82-8")
        @test found.id == Int32[1] && found.points == [1]
    end
end
