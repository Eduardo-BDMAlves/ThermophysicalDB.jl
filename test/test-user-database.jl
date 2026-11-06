@testmodule OwnData begin
    using ThermophysicalDB: ThermophysicalDB
    using ..TwoDatabases: TwoDatabases
    const T = ThermophysicalDB

    const WATER = TwoDatabases.WATER
    const SALT = TwoDatabases.SALT

    # The archive in its file (not read) and nothing else.
    function archive_only(dir)
        T.write_cache(dir, TwoDatabases.archive(), TwoDatabases.manifest())
        return T.Database([
            T.Member("thermoml"; kind = :thermoml, path = T.cache_data_path(dir)),
        ])
    end

    # A compound database that knows water, salt and an ambiguous name.
    function compound_db()
        cdb = T.CompoundDB()
        T.insert_record!(
            cdb;
            inchikey = WATER,
            cas = "7732-18-5",
            formula = "H2O",
            names = ["water", "aqua"],
        )
        T.insert_record!(
            cdb;
            inchikey = SALT,
            cas = "7647-14-5",
            formula = "NaCl",
            names = ["sodium chloride"],
        )
        T.insert_record!(
            cdb;
            inchikey = "AAAAAAAAAAAAAA-BBBBBBBBBB-C",
            cas = "1-11-1",
            names = ["twin"],
        )
        T.insert_record!(
            cdb;
            inchikey = "DDDDDDDDDDDDDD-EEEEEEEEEE-F",
            cas = "2-22-2",
            names = ["twin x"],
        )
        return cdb
    end
end

@testitem "an empty database of your own is added and refuses what it should" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        root = joinpath(dir, "databases")
        m = T.add_database!(db, "my_lab"; dir = root)
        @test m.kind === :user && m.priority == 3 && !m.persistent
        @test [x.name for x in T.members(db)] == ["thermoml", "my_lab"]
        @test length(T.member_dataset(m).measurements) == 0
        lit = T.add_database!(db, "papers"; kind = :literature, dir = root)
        @test [x.name for x in T.members(db)] == ["thermoml", "papers", "my_lab"]
        @test lit.priority == 2
        @test_throws ArgumentError T.add_database!(db, "thermoml"; dir = root)
        @test_throws ArgumentError T.add_database!(db, "MY_LAB"; dir = root)
        @test_throws ArgumentError T.add_database!(db, "a/b"; dir = root)
        @test_throws ArgumentError T.add_database!(db, "x"; kind = :thermoml, dir = root)
        # Nothing is written until the user asks.
        @test !ispath(root)
        # The archive is never written, and a call that does not say which database fails.
        @test_throws ArgumentError T.add_reference!(
            db;
            database = "thermoml",
            doi = "10.1/x",
        )
        @test_throws ArgumentError T.add_reference!(db; doi = "10.1/x")
        @test_throws ArgumentError T.add_reference!(db; database = "nope", doi = "10.1/x")
    end
end

@testitem "a compound must be identified" setup = [TwoDatabases, OwnData] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    cdb = OwnData.compound_db()
    rc(spec) = T.resolve_compound(spec; compounds = cdb)
    # The InChIKey is the identity; the compound database only adds its names.
    c = rc(OwnData.WATER)
    @test c.inchikey == OwnData.WATER && "water" in c.names && c.formula == "H2O"
    # A CAS number or a name that the compound database knows exactly give the InChIKey.
    @test rc("7732-18-5").inchikey == OwnData.WATER
    @test rc("Sodium  Chloride").inchikey == OwnData.SALT
    @test rc((cas = "7647-14-5",)).inchikey == OwnData.SALT
    @test rc((name = "water", formula = "H2O")).inchikey == OwnData.WATER
    # A CAS number nobody knows is the key until an InChIKey is given.
    c = rc("9999-99-9")
    @test c.inchikey == "" && c.cas == "9999-99-9" && "9999-99-9" in c.names
    # A name alone is not enough, and neither is an InChI.
    @test_throws ArgumentError rc("unobtainium")
    @test_throws ArgumentError rc("InChI=1S/H2O/h1H2")
    @test_throws ArgumentError rc((inchikey = "not-a-key",))
    @test_throws ArgumentError rc((cas = "7732-18",))
    @test_throws ArgumentError rc((colour = "blue",))
    @test_throws ArgumentError rc(42)
    # A name that is only close to one is not accepted.
    @test_throws ArgumentError rc("watr")
end

@testitem "references, experiments and points of your own are found with the archive" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        cdb = OwnData.compound_db()
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(
            db;
            doi = "https://doi.org/10.5555/Mine-1",
            authors = "Silva, A.",
            year = 2024,
        )
        @test ref isa T.ReferenceRef
        ds = T.member_dataset(db, "my_lab")
        @test ds.references.doi == ["10.5555/Mine-1"]
        # The same DOI is the same reference.
        @test T.add_reference!(db; doi = "10.5555/Mine-1").id == ref.id
        exp = T.add_experiment!(
            ref;
            components = ["water", "7647-14-5"],
            composition_scale = :molality,
            compounds = cdb,
        )
        @test exp.ncomp == 2
        @test ds.compounds.key == [OwnData.WATER, OwnData.SALT]
        @test T.pool_string(ds.kinds, ds.experiments.kinds[1][1]) == "Molality, mol/kg"
        row = T.add_measurement!(
            exp;
            property = "Mass density",
            unit = "kg/m3",
            value = 1038.1,
            temperature = 293.15,
            pressure = 101.325,
            composition = [NaN, 1.0],
            unc = 0.5,
            unc_k = 2,
        )
        @test row == 1
        T.add_measurement!(
            exp;
            property = "Mass density",
            unit = "kg/m3",
            value = 1036.4,
            temperature = 298.15,
            composition = (NaN, 1.0),
        )
        # Nothing new to the archive and the property is shared: one number for it.
        @test length(db.registry.property_keys) == 1
        v = T.points(
            db;
            component = ["water", "sodium chloride"],
            match = :all,
            property = "Mass density",
        )
        @test length(v) == 2 + 2
        t = T.table(v)
        @test sort(unique(t.database)) == ["my_lab", "thermoml"]
        mine = t.value[t.database .== "my_lab"]
        @test sort(mine) == [1036.4, 1038.1]
        # A property that only the user has is found, and only in the user's database.
        T.add_measurement!(
            T.add_experiment!(ref; components = [OwnData.WATER]);
            property = "Viscosity",
            unit = "Pa s",
            value = 8.9e-4,
            temperature = 298.15,
        )
        @test length(db.registry.property_keys) == 2
        w = T.points(db; property = "Viscosity")
        @test length(w) == 1 && length(T.parts(w)) == 1
        @test T.validate(ds)
    end
end

@testitem "a point that makes no sense is refused" setup = [TwoDatabases, OwnData] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(db; title = "Thesis")
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        ok = (; property = "Mass density", unit = "kg/m3", value = 997.0)
        add(; kw...) = T.add_measurement!(exp; merge(ok, (; kw...))...)
        @test_throws ArgumentError add(value = NaN)
        @test_throws ArgumentError add(value = Inf)
        @test_throws ArgumentError add(temperature = -1.0)
        @test_throws ArgumentError add(temperature = 0.0)
        @test_throws ArgumentError add(pressure = -5.0)
        @test_throws ArgumentError add(unc = -1.0)
        @test_throws ArgumentError add(unc_k = 0)
        @test_throws ArgumentError add(unc_level = 95)
        @test_throws ArgumentError add(composition = [0.5, 0.5])
        @test_throws ArgumentError add(composition = [-0.1])
        @test_throws ArgumentError T.add_measurement!(exp; property = " ", value = 1.0)
        @test_throws ArgumentError T.add_reference!(db)
        @test_throws ArgumentError T.add_reference!(db; doi = "10.1/x", year = 3)
        @test_throws ArgumentError T.add_reference!(db; doi = "10.1/x", colour = "red")
        @test_throws ArgumentError T.add_experiment!(ref; components = String[])
        @test_throws ArgumentError T.add_experiment!(
            ref;
            components = [OwnData.WATER],
            composition_scale = :percent,
        )
        @test_throws ArgumentError T.add_experiment!(
            ref;
            components = [OwnData.WATER, OwnData.SALT],
            composition_scale = [:mole_fraction],
        )
        # Nothing of this was added.
        @test length(T.member_dataset(db, "my_lab").measurements) == 0
        @test length(db.registry.property_keys) == 1
    end
end

@testitem "the data of an article go in together, or not at all" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        cdb = OwnData.compound_db()
        T.add_database!(db, "papers"; kind = :literature, dir = joinpath(dir, "databases"))
        ds = T.member_dataset(db, "papers")
        article =
            (doi = "10.5555/paper-7", authors = ["Souza, B.", "Lima, C."], year = 2020)
        good = (
            components = ["water", "7647-14-5"],
            composition_scale = :molality,
            compounds = cdb,
            property = "Mass density",
            unit = "kg/m3",
            temperature = [293.15, 298.15, 303.15],
            pressure = 101.325,
            x2 = [1.0, 1.0, 1.0],
            value = [1038.1, 1036.4, 1034.5],
        )
        pure = (
            components = [OwnData.WATER],
            property = "Mass density",
            unit = "kg/m3",
            temperature = [293.15, 298.15],
            value = [998.2, 997.0],
            purpose = "check",
        )
        bad = merge(pure, (; value = [998.2, NaN]))
        short = merge(pure, (; temperature = [293.15]))
        extra = merge(pure, (; x2 = [0.5, 0.5]))
        for experiment in (bad, short, extra, merge(pure, (; colour = 1)))
            @test_throws ArgumentError T.add_reference_data!(
                db;
                reference = article,
                experiments = [good, experiment],
            )
        end
        @test_throws ArgumentError T.add_reference_data!(
            db;
            reference = article,
            experiments = [
                good,
                (components = ["unobtainium"], property = "x", value = [1.0]),
            ],
        )
        # Nothing was added by any of them, not even the reference or the compounds.
        @test length(ds.references) == 0 && length(ds.compounds) == 0
        @test length(ds.experiments) == 0 && length(ds.measurements) == 0
        r = T.add_reference_data!(db; reference = article, experiments = [good, pure])
        @test r.points == 5 && length(r.experiments) == 2
        @test length(ds.references) == 1 && length(ds.experiments) == 2
        @test ds.references.authors[1] == ["Souza, B.", "Lima, C."]
        @test ds.measurements.pressure[1:3] == fill(101.325, 3)
        @test isnan(ds.measurements.pressure[4])
        @test ds.measurements.composition[2][1:3] == [1.0, 1.0, 1.0]
        @test T.pool_string(ds.purposes, ds.experiments.purpose[2]) == "check"
        # More data of the same article, by its DOI.
        more = T.add_reference_data!(
            db;
            reference = "10.5555/paper-7",
            experiments = [merge(pure, (; temperature = [313.15], value = [992.2]))],
        )
        @test more.points == 1 && length(ds.references) == 1 && length(ds.experiments) == 3
        @test_throws ArgumentError T.add_reference_data!(
            db;
            reference = "10.5555/not-there",
            experiments = [pure],
        )
        @test length(T.points(db; doi = "10.5555/paper-7")) == 6
        @test T.validate(ds)
    end
end

@testitem "a saved database is found again, with its priority" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        root = joinpath(dir, "databases")
        T.add_database!(db, "my_lab"; dir = root)
        T.add_database!(db, "papers"; kind = :literature, dir = root)
        ref = T.add_reference!(db; database = "my_lab", doi = "10.5555/mine-2")
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        for k = 1:3
            T.add_measurement!(
                exp;
                property = "Viscosity",
                unit = "Pa s",
                value = k * 1e-3,
                temperature = 290.0 + k,
            )
        end
        @test T.discover_members(root) == T.Member[]
        path = T.save_database(db, "my_lab")
        @test isfile(path) && isfile(joinpath(root, "my_lab", "member.toml"))
        @test !isdir(joinpath(root, "papers"))
        @test T.members(db)[end].persistent
        found = T.discover_members(root)
        @test [m.name for m in found] == ["my_lab"]
        @test found[1].kind === :user && found[1].persistent && found[1].priority == 3
        # Its tables are read when a query needs them, and the catalog without them.
        @test !T.is_open(found[1])
        again = T.Database([db.members[1], found[1]])
        @test length(T.points(again; property = "Viscosity")) == 3
        @test T.is_open(found[1])
        # The priority is kept in the description.
        T.set_priority!(db, "my_lab", 0)
        @test [m.name for m in T.members(db)] == ["my_lab", "thermoml", "papers"]
        @test T.discover_members(root)[1].priority == 0
        # A name that is saved is not taken again by mistake.
        fresh = OwnData.archive_only(joinpath(dir, "other"))
        @test_throws ArgumentError T.add_database!(fresh, "my_lab"; dir = root)
        # What cannot be read is skipped with a warning.
        meta = joinpath(root, "my_lab", "member.toml")
        write(
            meta,
            replace(read(meta, String), r"schema_version = \d+" => "schema_version = 1"),
        )
        @test_logs (:warn, r"skipped") @test T.discover_members(root) == T.Member[]
        write(meta, "not toml [")
        @test_logs (:warn, r"skipped") @test T.discover_members(root) == T.Member[]
        # More points and another save: the new file replaces the old one.
        write(meta, "")
        T.save_database(db, "my_lab")
        T.add_measurement!(exp; property = "Viscosity", unit = "Pa s", value = 4e-3)
        T.save_database(db, "my_lab")
        @test length(T.member_dataset(T.discover_members(root)[1]).measurements) == 4
    end
end

@testitem "database() opens the saved databases of the user" setup =
    [Fixtures, ThermoMLFixture, TwoDatabases, OwnData] tags = [:integration] begin
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
        T.forget_database!()
        db = T.database(; options...)
        @test length(T.members(db)) == 1
        T.add_database!(db, "my_lab"; dir = joinpath(tmp, "databases"))
        ref = T.add_reference!(db; doi = "10.5555/mine-3")
        exp = T.add_experiment!(ref; components = [OwnData.WATER])
        T.add_measurement!(exp; property = "Viscosity", unit = "Pa s", value = 1e-3)
        T.save_database(db, "my_lab")
        both = T.database(; options..., reload = true)
        @test [m.name for m in T.members(both)] == ["thermoml", "my_lab"]
        @test length(T.points(both; property = "Viscosity")) == 1
        # The archive alone, and the two are not mixed up in the session.
        alone = T.database(; options..., user_databases = false)
        @test length(T.members(alone)) == 1
        @test T.database(; options..., user_databases = false) === alone
        T.forget_database!()
    end
end
