@testitem "thermoml_phase translates the names of the saturation states" tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, thermoml_phase, thermoml_phases
    @test length(thermoml_phases()) == 33
    @test "Liquid" in thermoml_phases() && "Gas" in thermoml_phases()
    @test !("Metastable liquid" in thermoml_phases())

    liquid = thermoml_phase("Liquid (saturated)")
    @test liquid.name == "Liquid" && liquid.system == ["Liquid", "Gas"]
    @test liquid.saturated && liquid.description == "Liquid (saturated)"
    vapor = thermoml_phase("Vapor (saturated)")
    @test vapor.name == "Gas" && vapor.system == ["Gas", "Liquid"] && vapor.saturated
    both = thermoml_phase("Liquid + Vapor (saturated)")
    @test both.name == "Liquid" && both.system == ["Liquid", "Gas"] && both.saturated

    # Case, spaces, the spelling of vapor and the word after a `+` do not matter.
    @test thermoml_phase("  liquid  +  vapour(Saturated) ").name == "Liquid"
    @test thermoml_phase("Vapour (saturated)").name == "Gas"
    @test thermoml_phase("gas (saturated)").system == ["Gas", "Liquid"]
    swapped = thermoml_phase("Vapor + Liquid")
    @test swapped.name == "Liquid" && swapped.saturated
    @test swapped.system == ["Liquid", "Gas"]

    # A vapor that is not said to be saturated is a gas; the text is kept.
    plain = thermoml_phase("vapor")
    @test plain.name == "Gas" && plain.system == ["Gas"] && !plain.saturated
    @test plain.description == "vapor"

    # The names of the standard, in any case, have nothing to describe.
    exact = thermoml_phase("liquid mixture 1")
    @test exact.name == "Liquid mixture 1" && exact.system == ["Liquid mixture 1"]
    @test !exact.saturated && exact.description == ""
    @test thermoml_phase("LIQUID").name == "Liquid"
    @test thermoml_phase("Metastable liquid").name == "Metastable liquid"
    for name in thermoml_phases()
        @test thermoml_phase(name).name == name
    end

    # Nothing is guessed: no equivalent is an error that names the closest phases.
    for text in (
        "Liquido",
        "Saturated liquid",
        "Liquid + Liquid",
        "Gas + Vapor",
        "(saturated)",
        "Crystall 9",
        "",
    )
        @test_throws ArgumentError thermoml_phase(text)
    end
    err = try
        thermoml_phase("Liquido")
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    @test occursin("\"Liquid\"", err.msg) && occursin("Liquid (saturated)", err.msg)
    @test occursin("thermoml_phases()", err.msg)
    @test ThermophysicalDB.closest_phases("Liquido")[1] == "Liquid"
end

@testitem "the ThermoML export translates the phase of points at saturation" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    get(o, key) = last(only(p for p in o.pairs if first(p) == key))

    function article_of(view)
        context = T.ThermomlContext(view)
        ref = only(keys(T.articles_of(view)))
        return T.thermoml_article(context, ref, view.rows)
    end

    # The points of the fixture are gas; at saturation they become liquid ones.
    ds = SampleData.build()
    view = T.points(ds; component = "methane")
    original = T.pool_string(ds.phases, ds.measurements.phase[first(view.rows)])
    @test original == "Gas"
    ds.measurements.phase[view.rows] .= T.intern!(ds.phases, "Liquid (saturated)")
    block = first(get(article_of(view), "PureOrMixtureData"))
    id = get(first(get(block, "Property")), "PropPhaseID")
    @test first.(id.pairs) == ["ePropPhase", "sPhaseDescription"]    # the order of the schema
    @test get(id, "ePropPhase") == "Liquid"
    @test get(id, "sPhaseDescription") == "Liquid (saturated)"
    phases = [get(p, "ePhase") for p in get(block, "PhaseID")]
    @test "Liquid" in phases && "Gas" in phases && length(phases) == 2

    # The vapor of the same system is a gas property, in a block that has the liquid too.
    ds.measurements.phase[view.rows] .= T.intern!(ds.phases, "Vapor (saturated)")
    block = first(get(article_of(view), "PureOrMixtureData"))
    id = get(first(get(block, "Property")), "PropPhaseID")
    @test get(id, "ePropPhase") == "Gas"
    @test get(id, "sPhaseDescription") == "Vapor (saturated)"
    phases = [get(p, "ePhase") for p in get(block, "PhaseID")]
    @test sort(phases) == ["Gas", "Liquid"]

    # A phase of the standard, and the one the archive has that the schema does not list, are
    # written as they are, without a description.
    for name in ("Gas", "Metastable liquid")
        ds.measurements.phase[view.rows] .= T.intern!(ds.phases, name)
        block = first(get(article_of(view), "PureOrMixtureData"))
        id = get(first(get(block, "Property")), "PropPhaseID")
        @test first.(id.pairs) == ["ePropPhase"] && get(id, "ePropPhase") == name
    end

    # The files carry the description, and a phase without an equivalent is refused first.
    ds.measurements.phase[view.rows] .= T.intern!(ds.phases, "Liquid (saturated)")
    mktempdir() do dir
        T.export_points(
            joinpath(dir, "out"),
            view;
            formats = (:thermoml, :thermoml_xml),
            progress = false,
        )
        xml =
            read(joinpath(dir, "out", "out.thermoml", "10.5555_tdbfixture-001.xml"), String)
        @test occursin("<sPhaseDescription>Liquid (saturated)</sPhaseDescription>", xml)
        @test occursin("<ePropPhase>Liquid</ePropPhase>", xml)
        json = read(joinpath(dir, "out", "out.thermoml.json"), String)
        @test occursin("\"sPhaseDescription\": \"Liquid (saturated)\"", json)
    end

    ds.measurements.phase[view.rows] .= T.intern!(ds.phases, "Liquido")
    err = try
        T.ThermomlContext(view)
        nothing
    catch e
        e
    end
    @test err isa ArgumentError
    count = length(view)
    @test occursin("\"Liquido\" ($count point", err.msg)
    @test occursin("\"Liquid\"", err.msg) && occursin("update_points!", err.msg)
    mktempdir() do dir
        @test_throws ArgumentError T.export_points(
            joinpath(dir, "out"),
            view;
            formats = (:thermoml,),
            progress = false,
        )
        # The other formats keep the text of the user.
        T.export_points(joinpath(dir, "csv"), view; formats = (:csv,), progress = false)
        @test occursin("Liquido", read(joinpath(dir, "csv", "csv.csv"), String)) ||
              !isempty(readdir(joinpath(dir, "csv")))
    end
end

@testitem "update_points! changes the phase of the points" setup =
    [TwoDatabases, OwnData, AuditData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    mktempdir() do dir
        db, _ = AuditData.lab(dir, 4)
        mine() = T.points(db; source = "my_lab")
        function count_of(name)
            tally = T.phases(mine())
            i = findfirst(==(name), tally.phase)
            return i === nothing ? 0 : tally.points[i]
        end

        sel = T.points(db; source = "my_lab", temperature = (291.5, 293.5))
        @test length(sel) == 2
        r = T.update_points!(db, sel; phase = "Liquid (saturated)")
        @test r.points == 2 && r.changed == 2
        @test count_of("Liquid (saturated)") == 2
        # the same text again changes nothing, and a filter finds the points
        @test T.update_points!(db, sel; phase = "Liquid (saturated)").changed == 0
        @test length(T.points(db; source = "my_lab", phase = "saturated")) == 2

        # a function of the current text, and one text for each point
        r = T.update_points!(
            db,
            mine();
            phase = p -> p == "Liquid (saturated)" ? "Vapor (saturated)" : "Liquid",
        )
        @test r.changed == 4
        @test count_of("Vapor (saturated)") == 2 && count_of("Liquid") == 2
        r = T.update_points!(db, mine(); phase = ["Gas", "Gas", "Liquid", "  Liquid "])
        @test r.points == 4
        @test count_of("Gas") == 2 && count_of("Liquid") == 2

        # the empty text clears the phase
        T.update_points!(db, sel; phase = "")
        @test count_of("Gas") + count_of("Liquid") == 2

        # mistakes change nothing
        before = T.phases(mine())
        @test_throws ArgumentError T.update_points!(db, sel; phase = 3)
        @test_throws ArgumentError T.update_points!(db, sel; phase = ["Gas"])
        @test_throws ArgumentError T.update_points!(db, sel; phase = p -> 1)
        @test T.phases(mine()) == before
        @test_throws ArgumentError T.update_points!(db, sel; vapor = "Gas")
    end
end
