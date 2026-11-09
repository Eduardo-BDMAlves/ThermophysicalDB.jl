@testmodule TemplateFixtures begin
    using ThermophysicalDB: ThermophysicalDB
    using ..OwnData: OwnData
    const T = ThermophysicalDB

    missing_row() = Any[missing for _ = 1:13]

    # A compound row of the Reference sheet.
    function compound(row, name, inchikey; kw...)
        base = (;
            row,
            name,
            cas = missing,
            inchikey,
            supplier = missing,
            source = missing,
            purity = missing,
            basis = missing,
            purity_unc = missing,
            water = missing,
            analysis = missing,
            purification = missing,
            notes = missing,
        )
        return merge(base, NamedTuple(kw))
    end

    # The points of a sheet: each is a NamedTuple with some of x1, x2, x3, T, P, value, u.
    function points(list)
        cells = Matrix{Any}(missing, length(list), 13)
        for (i, p) in enumerate(list)
            for (key, j) in (
                :x1 => 1,
                :x2 => 2,
                :x3 => 3,
                :ux1 => 4,
                :ux2 => 5,
                :ux3 => 6,
                :T => 7,
                :uT => 8,
                :P => 9,
                :uP => 10,
                :value => 11,
                :u => 12,
            )
                haskey(p, key) && (cells[i, j] = p[key])
            end
        end
        return cells
    end

    function experiment(
        k,
        list;
        name = "Density $k",
        property = "Mass density",
        components = ["water"],
        scale = missing,
        unit = "kg/m3",
        temperature_unit = "K",
        pressure_unit = "kPa",
        composition_unit = "fraction",
        unc_type = "absolute",
        k_factor = 2,
        input_type = "absolute",
        input_k = 2,
        phase = missing,
        first_row = 8,
    )
        units = Any[
            "fraction",
            "fraction",
            "fraction",
            missing,
            missing,
            missing,
            "K",
            missing,
            "kPa",
            missing,
            unit,
            missing,
        ]
        units[1] = units[2] = units[3] = composition_unit
        units[7] = temperature_unit
        units[9] = pressure_unit
        types = Any[missing for _ = 1:12]
        types[12] = unc_type
        ks = Any[missing for _ = 1:12]
        ks[12] = k_factor
        for j in (4, 5, 6, 8, 10)
            types[j] = input_type
            ks[j] = input_k
        end
        return T.TemplateExperiment(
            "x.xlsx",
            k,
            name,
            property,
            phase,
            missing,
            missing,
            Any[components..., (missing for _ = (length(components)+1):3)...],
            scale,
            missing,
            Any[missing, missing],
            units,
            types,
            ks,
            Int[first_row + i - 1 for i = 1:length(list)],
            points(list),
        )
    end

    function data(;
        doi = "10.5555/Template-1",
        authors = Any[
            "Silva, A.",
            missing,
            missing,
            missing,
            missing,
            missing,
            missing,
            missing,
        ],
        year = 2024,
        target = "my_lab",
        kind = "User",
        compounds = [compound(21, "water", OwnData.WATER)],
        experiments,
    )
        reference = (;
            doi,
            authors,
            title = "A title",
            journal = missing,
            year,
            volume = missing,
            pages = missing,
            other = missing,
        )
        return T.TemplateData(
            "x.xlsx",
            1,
            "0.1.0",
            target,
            kind,
            reference,
            compounds,
            experiments,
        )
    end

    function write(dir, name, td; experiments = max(2, length(td.experiments)))
        path = joinpath(dir, name)
        T.write_template(
            path,
            experiments,
            T.TemplateInfo(
                "0.1.0",
                "ThermoML 2.0",
                "2026-01-01",
                NamedTuple[],
                NamedTuple[],
            );
            fill = td,
        )
        return path
    end

    cdb() = OwnData.compound_db()

    function database(dir)
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        return db
    end
end

@testitem "the template is written, read back and extended without losing what was filled" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        path = T.export_template(db, joinpath(dir, "empty.xlsx"); experiments = 3)
        @test isfile(path)
        @test_throws ArgumentError T.export_template(db, path)
        @test T.export_template(db, path; overwrite = true, experiments = 1) == path
        td = T.read_template(path)
        @test td.format == T.TEMPLATE_FORMAT && length(td.experiments) == 1
        @test isempty(td.compounds) && all(!T.isgiven, td.reference.authors)
        @test td.experiments[1].units[7] == "K" &&
              td.experiments[1].unc_type[12] == "absolute"
        @test td.experiments[1].unc_k[12] == 2
        # The lists of this computer are in the file.
        info = T.read_template_info(path)
        @test [d.name for d in info.databases] == ["thermoml", "my_lab"]
        # The menus start with what the databases already use, then the generic choices.
        @test "Other" in info.lists.method && allunique(lowercase.(info.lists.method))
        # Fill, then add experiments: nothing that was typed is lost.
        e = F.experiment(
            1,
            [
                (T = 293.15, P = 101.325, value = 998.2, u = 0.1),
                (T = 303.15, value = 995.6),
            ],
        )
        filled = F.data(experiments = [e])
        file = F.write(dir, "filled.xlsx", filled; experiments = 1)
        @test T.add_template_experiments!(file; count = 2) == 3
        back = T.read_template(file)
        @test length(back.experiments) == 3
        @test back.reference.doi == "10.5555/Template-1" && back.reference.year == 2024
        @test back.reference.authors[1] == "Silva, A."
        @test [c.name for c in back.compounds] == ["water"]
        @test back.target == "my_lab" && back.kind == "User"
        b = back.experiments[1]
        @test b.name == "Density 1" &&
              b.property == "Mass density" &&
              b.components[1] == "water"
        @test b.cells[1, 7] == 293.15 && b.cells[1, 11] == 998.2 && b.cells[2, 7] == 303.15
        @test b.rows == [8, 9]
        @test isempty(back.experiments[3].rows)
        @test_throws ArgumentError T.add_template_experiments!(file; count = 0)
        # A file that is not a template says so.
        other = joinpath(dir, "other.xlsx")
        XLSX.openxlsx(other; mode = "w") do book
            book[1]["A1"] = "hello"
        end
        @test_throws ArgumentError T.read_template(other)
    end
end

@testitem "a filled template is imported, converted to the units of the databases" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        e = F.experiment(
            1,
            [
                (T = 20.0, P = 1.0, value = 0.9982, u = 0.0005),
                (T = 25.0, P = 1.0, value = 0.9970, u = 0.0005),
                (T = 30.0, P = 1.0, value = 0.9956, u = 0.0005),
            ];
            unit = "g/cm3",
            temperature_unit = "degC",
            pressure_unit = "bar",
        )
        path = F.write(dir, "ok.xlsx", F.data(experiments = [e]))
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test report.ok && report.points == 3 && isempty(report.problems)
        @test length(T.member_dataset(db, "my_lab").measurements) == 0
        result = T.import_template(db, path; warn_duplicates = false, compounds = F.cdb())
        @test result.points == 3
        m = T.member_dataset(db, "my_lab").measurements
        @test m.value ≈ [998.2, 997.0, 995.6]
        @test m.temperature ≈ [293.15, 298.15, 303.15]
        @test all(≈(100.0), m.pressure)
        @test m.unc ≈ fill(0.5, 3) && all(==(2.0), m.unc_k[i] for i = 1:3)
        @test isempty(result.ignored)
        # A relative uncertainty is turned into an absolute one with the value.
        e2 = F.experiment(
            1,
            [(T = 300.0, value = 1000.0, u = 0.1)];
            unc_type = "relative (%)",
            k_factor = 1,
        )
        path2 = F.write(
            dir,
            "relative.xlsx",
            F.data(doi = "10.5555/Template-2", experiments = [e2]),
        )
        T.import_template(db, path2; warn_duplicates = false, compounds = F.cdb())
        @test T.member_dataset(db, "my_lab").measurements.unc[end] ≈ 1.0
    end
end

@testitem "every mistake of a template is listed with its cell and nothing is added" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        good = (T = 293.15, value = 998.2)
        e1 =
            F.experiment(1, [good, (T = 300.0,)], name = "Density 1", components = ["wter"])
        e2 = F.experiment(
            2,
            [(T = 300.0, value = 1.0, x1 = 0.5), (T = 301.0, value = 2.0, x1 = 0.5)];
            components = ["water", "water"],
            scale = "Molality",
            composition_unit = "fraction",
        )
        path = F.write(dir, "bad.xlsx", F.data(year = "nineteen", experiments = [e1, e2]))
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test !report.ok
        text = join(report.problems, "\n")
        @test contains(text, "Reference!C14") && contains(text, "EXP-1!C12")
        @test contains(text, "PTS-1!L9")
        @test contains(text, "PTS-2!B8") && contains(text, "composition scale")
        err = try
            T.import_template(db, path; compounds = F.cdb())
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && contains(err.msg, "nothing was added")
        @test length(T.member_dataset(db, "my_lab").measurements) == 0
        # A mistake that only the package can see (a unit of another quantity) names the sheet row.
        bad_unit = F.experiment(1, [good]; unit = "bar")
        path2 = F.write(dir, "unit.xlsx", F.data(experiments = [bad_unit]))
        r2 = T.import_template(db, path2; only_check = true, compounds = F.cdb())
        @test !r2.ok && any(contains("PTS-1, row 8"), r2.problems)
    end
end

@testitem "a database that does not exist is created, unless told not to" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        e = F.experiment(1, [(T = 293.15, value = 998.2)])
        path = F.write(dir, "new.xlsx", F.data(target = "fresh_lab", experiments = [e]))
        r = T.import_template(
            db,
            path;
            create = false,
            only_check = true,
            compounds = F.cdb(),
        )
        @test !r.ok && any(contains("fresh_lab"), r.problems)
        # A check does not leave the database behind.
        @test T.import_template(db, path; only_check = true, compounds = F.cdb()).ok
        @test !any(m -> m.name == "fresh_lab", T.members(db))
        T.import_template(db, path; warn_duplicates = false, compounds = F.cdb())
        @test any(m -> m.name == "fresh_lab", T.members(db))
        @test length(T.member_dataset(db, "fresh_lab").measurements) == 1
        # The kind written in the file must be the kind of the database.
        other = F.write(
            dir,
            "kind.xlsx",
            F.data(
                target = "fresh_lab",
                kind = "Literature",
                doi = "10.5555/K",
                experiments = [e],
            ),
        )
        @test !T.import_template(db, other; only_check = true, compounds = F.cdb()).ok
    end
end

@testitem "two files of the same work are joined" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        a = F.data(
            compounds = [F.compound(21, "water", OwnData.WATER)],
            experiments = [F.experiment(1, [(T = 293.15, value = 998.2)])],
        )
        b = F.data(
            compounds = [
                F.compound(21, "water", OwnData.WATER),
                F.compound(22, "salt", OwnData.SALT),
            ],
            experiments = [
                F.experiment(
                    1,
                    [(T = 293.15, value = 1038.1, x2 = 0.1)];
                    name = "Brine",
                    components = ["water", "salt"],
                    scale = "Molality",
                    composition_unit = "mol/kg",
                ),
            ],
        )
        p1 = F.write(dir, "a.xlsx", a)
        p2 = F.write(dir, "b.xlsx", b)
        result =
            T.import_template(db, [p1, p2]; warn_duplicates = false, compounds = F.cdb())
        @test result.points == 2 && length(result.experiments) == 2
        @test length(T.member_dataset(db, "my_lab").references) == 1
        # Different works are refused.
        c = F.data(
            doi = "10.5555/Other",
            experiments = [F.experiment(1, [(T = 1.0, value = 1.0)])],
        )
        p3 = F.write(dir, "c.xlsx", c)
        @test_throws ArgumentError T.import_template(db, [p1, p3])
    end
end

@testitem "what this version does not store is reported, not dropped in silence" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        e = F.experiment(1, [(T = 293.15, value = 998.2)])
        cells = copy(e.cells)
        cells[1, 13] = "a note"      # the note column
        e = T.TemplateExperiment(
            e.file,
            e.sheet,
            e.name,
            e.property,
            e.phase,
            e.method,
            e.purpose,
            e.components,
            e.scale,
            e.source,
            e.notes,
            e.units,
            e.unc_type,
            e.unc_k,
            e.rows,
            cells,
        )
        path = F.write(dir, "ignored.xlsx", F.data(experiments = [e]))
        result = @test_logs (:warn, r"not stored yet") T.import_template(
            db,
            path;
            warn_duplicates = false,
            compounds = F.cdb(),
        )
        @test any(contains("Note"), result.ignored)
        @test result.points == 1
    end
end

@testitem "the uncertainties of T, P and the amounts are stored, a percentage of an absolute scale" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        # degC: an absolute u(T) is a difference (0.05 degC = 0.05 K); a relative one is taken of K.
        absolute = F.experiment(
            1,
            [(T = 25.0, uT = 0.05, P = 1.0, uP = 0.001, value = 998.2)];
            temperature_unit = "degC",
            pressure_unit = "bar",
        )
        relative = F.experiment(
            2,
            [(T = 25.0, uT = 0.01, value = 998.2)];
            temperature_unit = "degC",
            input_type = "relative (%)",
            input_k = 1,
        )
        fahrenheit = F.experiment(
            3,
            [(T = 77.0, uT = 0.09, value = 998.2)];
            temperature_unit = "degF",
        )
        path = F.write(
            dir,
            "inputs.xlsx",
            F.data(experiments = [absolute, relative, fahrenheit]),
        )
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test report.ok
        @test !any(contains("u(T)"), report.ignored)
        T.import_template(db, path; warn_duplicates = false, compounds = F.cdb())
        part = only(T.parts(T.points(db; source = "my_lab", duplicate = true)))
        u = T.uncertainty_table(part)
        function expanded(row, quantity)
            i = findfirst(
                n ->
                    u.measurement[n] == row &&
                    u.quantity[n] == quantity &&
                    u.kind[n] == "expanded",
                eachindex(u.measurement),
            )
            return (u.value[i], u.k[i])
        end
        @test expanded(1, "temperature") == (0.05, 2.0)
        @test expanded(1, "pressure")[1] ≈ 0.1          # 0.001 bar = 0.1 kPa
        @test expanded(2, "temperature")[1] ≈ 0.01e-2 * 298.15
        @test expanded(2, "temperature")[2] == 1.0
        @test expanded(3, "temperature")[1] ≈ 0.09 * 5 / 9
    end
end

@testitem "an uncertainty of T without its coverage factor or with a wrong sign is a problem of its cell" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        # The writer fills a missing coverage factor with its default, so the arguments are made from
        # the data directly: a cell that was emptied by hand reads as `missing`.
        e = F.experiment(1, [(T = 293.15, uT = 0.05, value = 998.2)]; input_k = missing)
        args = T.template_arguments(F.data(experiments = [e]))
        @test any(contains("PTS-1!I7"), args.problems)
        e = F.experiment(1, [(T = 293.15, uT = -0.05, value = 998.2)])
        path = F.write(dir, "neg.xlsx", F.data(experiments = [e]))
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test any(contains("PTS-1!I8"), report.problems)
    end
end

@testitem "add_measurement! stores the uncertainties of the conditions" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db = OwnData.archive_only(joinpath(dir, "thermoml"))
        T.add_database!(db, "my_lab"; dir = joinpath(dir, "databases"))
        ref = T.add_reference!(
            db;
            database = "my_lab",
            title = "t",
            year = 2026,
            authors = ["A"],
        )
        e = T.add_experiment!(
            ref;
            components = ["water", "sodium chloride"],
            composition_scale = :molality,
            compounds = OwnData.compound_db(),
        )
        T.add_measurement!(
            e;
            property = "Mass density",
            unit = "kg/m3",
            value = 1000.0,
            temperature = "25 degC",
            pressure = "101.325 kPa",
            composition = [1.0],
            unc_temperature = "0.01 %",
            unc_pressure = T.UncertaintyTerm("0.5 kPa"; k = 2),
            unc_composition = "0.1 %",
        )
        part = only(T.parts(T.points(db; source = "my_lab")))
        u = T.uncertainty_table(part)
        pick(q, kind) = u.value[findfirst(
            i -> u.quantity[i] == q && u.kind[i] == kind,
            eachindex(u.quantity),
        )]
        @test pick("temperature", "expanded") ≈ 1.0e-4 * 298.15
        @test pick("pressure", "expanded") == 0.5
        @test pick("pressure", "combined") == 0.25
        @test pick("composition1", "expanded") ≈ 1.0e-3
        # an uncertainty of what is not given, or in a wrong unit, adds nothing
        n = length(u.value)
        @test_throws ArgumentError T.add_measurement!(
            e;
            property = "Mass density",
            unit = "kg/m3",
            value = 1.0,
            unc_pressure = 1.0,
        )
        @test_throws ArgumentError T.add_measurement!(
            e;
            property = "Mass density",
            unit = "kg/m3",
            value = 1.0,
            temperature = 300.0,
            unc_temperature = "1 mol/kg",
        )
        @test length(
            T.uncertainty_table(only(T.parts(T.points(db; source = "my_lab")))).value,
        ) == n
    end
end

@testitem "the workbook that the package writes is consistent" setup =
    [TwoDatabases, OwnData] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    ext = Base.get_extension(T, :ThermophysicalDBXLSXExt)
    info = T.TemplateInfo("0.1.0", "ThermoML 2.0", "2026-01-01", NamedTuple[], NamedTuple[])
    book = ext.build_template(3, info, UInt8[])
    names = [s.name for s in book.sheets]
    @test names == [
        "Guide",
        "Reference",
        "EXP-1",
        "PTS-1",
        "EXP-2",
        "PTS-2",
        "EXP-3",
        "PTS-3",
        "Properties",
        "Lists",
    ]
    # Merged ranges never overlap (Excel refuses a file where they do).
    function cells_of(ref)
        a, b = occursin(':', ref) ? split(ref, ':') : (ref, ref)
        parse_ref(x) = begin
            m = match(r"^([A-Z]+)(\d+)$", x)
            col = foldl((acc, c) -> acc * 26 + (c - 'A' + 1), m[1]; init = 0)
            (parse(Int, m[2]), col)
        end
        (r1, c1), (r2, c2) = parse_ref(a), parse_ref(b)
        return [(r, c) for r = r1:r2 for c = c1:c2]
    end
    for sheet in book.sheets
        seen = Set{Tuple{Int,Int}}()
        for m in sheet.merges
            for cell in cells_of(m)
                @test cell ∉ seen
                push!(seen, cell)
            end
        end
    end
    # Every list that a menu uses is a defined name.
    defined = Set(first.(book.names))
    for sheet in book.sheets, v in sheet.validations
        v.kind === :list && @test v.formula1 in defined
    end
    @test allunique(first.(book.names))
    for k = 1:3, key in ("name", "property", "components", "scale")
        @test "exp$(k)_$key" in defined
    end
    @test "pts3_table" in defined && "template_format" in defined && "ref_doi" in defined
end

@testitem "only_check adds nothing and the report says whether the data are ThermoML compatible" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        e = F.experiment(1, [(T = 293.15, value = 998.2)]; phase = "Liquid")
        path = F.write(dir, "good.xlsx", F.data(experiments = [e]))
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test report.ok
        @test !report.imported
        @test report.thermoml_compatible
        @test isempty(report.thermoml_failures)
        @test sum(m.name == "my_lab" ? T.member_points(m) : 0 for m in db.members) == 0   # nothing was added
        result = T.import_template(db, path; compounds = F.cdb(), warn_duplicates = false)
        @test result.imported
        @test result.thermoml_compatible

        # a phase that ThermoML does not have, a citation that cannot be identified, a mixture
        # without its composition and an unknown property: all listed, the data are still storable
        bad = F.experiment(
            1,
            [(T = 293.15, value = 998.2)];
            phase = "Not specified",
            property = "Mass density",
        )
        td = F.data(experiments = [bad], doi = "", authors = Any[missing for _ = 1:8])
        path = F.write(dir, "bad.xlsx", td)
        report = T.import_template(db, path; only_check = true, compounds = F.cdb())
        @test !report.thermoml_compatible
        @test any(contains("citation"), report.thermoml_failures)
        @test any(contains("phase"), report.thermoml_failures)
    end
end

@testitem "the menus of the template start with what the databases already use" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    using XLSX
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        ref = T.add_reference!(
            db;
            database = "my_lab",
            title = "t",
            year = 2026,
            authors = ["A"],
        )
        e = T.add_experiment!(ref; components = ["water"], compounds = F.cdb())
        for (method, n) in (("Invented rheometer", 3), ("Pycnometer", 1))
            for i = 1:n
                T.add_measurement!(
                    e;
                    property = "Mass density",
                    unit = "kg/m3",
                    value = 990.0 + i,
                    temperature = 290.0 + i + 10n,
                    pressure = 101.325,
                    method,
                    phase = "Liquid",
                )
            end
        end
        used = T.template_info(db).lists
        @test used.method[1] == "Invented rheometer"
        @test "Pycnometer" in used.method && "Liquid" in used.phase
        path = T.export_template(db, joinpath(dir, "menus.xlsx"); experiments = 1)
        info = T.read_template_info(path)
        @test info.lists.method[1:length(used.method)] == used.method
        @test "Other" in info.lists.method && allunique(lowercase.(info.lists.method))
        @test count(==("Pycnometer"), info.lists.method) == 1
        # A file without a database keeps the menus when experiments are added.
        @test T.add_template_experiments!(path; count = 1) == 2
        @test T.read_template_info(path).lists.method == info.lists.method
    end
end

@testitem "the menus count samples whose analyses and purifications are lists" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    db = T.Database([T.Member("samples"; kind = :thermoml, dataset = SampleData.build())])
    used = T.template_info(db).lists
    @test "Commercial source" in used.source
    @test "Gas chromatography" in used.analysis && "Stated by supplier" in used.analysis
    @test "Fractional distillation" in used.purification
end

@testitem "a source without a match says so instead of calling itself unknown" setup =
    [TwoDatabases, OwnData, TemplateFixtures] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    F = TemplateFixtures
    mktempdir() do dir
        db = F.database(dir)
        ref = T.add_reference!(
            db;
            database = "my_lab",
            title = "t",
            year = 2026,
            authors = ["A"],
        )
        e = T.add_experiment!(ref; components = ["water"], compounds = F.cdb())
        T.add_measurement!(
            e;
            property = "Mass density",
            unit = "kg/m3",
            value = 998.0,
            temperature = 293.15,
            pressure = 101.325,
        )
        @test length(T.points(db; source = "my_lab")) == 1
        err = try
            T.points(db; component = "ethanol", source = "my_lab")
        catch e
            e
        end
        @test err isa ArgumentError && contains(err.msg, "exists but none")
        err = try
            T.points(db; source = "nowhere")
        catch e
            e
        end
        @test err isa ArgumentError && contains(err.msg, "unknown source")
    end
end
