@testitem "significant_digits counts the digits as the number is written" tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    @test T.significant_digits(298.893) == 6
    @test T.significant_digits(0.03312) == 4
    @test T.significant_digits(6100.0) == 2         # trailing zeros of a whole number do not count
    @test T.significant_digits(101.325) == 6
    @test T.significant_digits(1.0) == 1
    @test T.significant_digits(0.5) == 1
    @test T.significant_digits(2.5e-5) == 2
    @test T.significant_digits(0.0) == 1
    @test T.significant_digits(-12.50) == 3
end

@testitem "the ThermoML tree has the elements of the schema, in order, for samples and digits" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    view = T.DataView(ds)
    context = T.ThermomlContext(view)
    groups = T.articles_of(view)
    ref = only(keys(groups))
    article = T.thermoml_article(context, ref, groups[ref])
    get(o, key) = last(only(p for p in o.pairs if first(p) == key))
    @test first.(article.pairs) == ["Version", "Citation", "Compound", "PureOrMixtureData"]
    @test get(get(article, "Version"), "nVersionMajor") == 2

    citation = get(article, "Citation")
    @test first.(citation.pairs) == [
        "eType",
        "sAuthor",
        "sPubName",
        "yrPubYr",
        "sTitle",
        "sAbstract",
        "sKeyword",
        "sDOI",
        "sVol",
        "sPage",
    ]

    compounds = get(article, "Compound")
    @test length(compounds) == 3
    co2 = compounds[1]
    @test first.(co2.pairs) == [
        "RegNum",
        "sStandardInChI",
        "sStandardInChIKey",
        "sCommonName",
        "sFormulaMolec",
        "Sample",
    ]
    sample = only(get(co2, "Sample"))
    steps = get(sample, "purity")
    @test length(steps) == 2
    @test first.(steps[2].pairs) == [
        "nStep",
        "ePurifMethod",
        "sPurifMethod",
        "nPurityMol",
        "nPurityMolDigits",
        "eAnalMeth",
        "sAnalMeth",
    ]
    @test get(steps[2], "nPurityMol") ≈ 99.9 && get(steps[2], "nPurityMolDigits") == 3
    @test get(steps[1], "nPurityMass") ≈ 99.5 && get(steps[1], "nPurityMassDigits") == 3
    @test !any(c -> first(c) == "Sample", compounds[3].pairs)         # water: no sample

    blocks = get(article, "PureOrMixtureData")
    first_block = blocks[1]
    @test first.(first_block.pairs) == [
        "nPureOrMixtureDataNumber",
        "Component",
        "eExpPurpose",
        "Property",
        "PhaseID",
        "Constraint",
        "Variable",
        "NumValues",
    ]
    # the composition fixed by the constraint is not repeated as a variable of every point
    constraint = only(get(first_block, "Constraint"))
    @test get(constraint, "nConstraintValue") == 0.5 &&
          get(constraint, "nConstrDigits") == 2
    components = get(first_block, "Component")
    @test get(components[1], "nSampleNm") == 1
    value = get(only(get(get(first_block, "NumValues")[1], "PropertyValue")), "nPropDigits")
    @test value == 4
    # the second block (water) has no sample: its component carries no `nSampleNm`
    @test !any(c -> first(c) == "nSampleNm", get(blocks[2], "Component")[1].pairs)
    # a free-text method is written as `sMethodName`, an enumerated one as `eMethodName`
    property = get(get(blocks[2], "Property")[1], "Property-MethodID")
    group = get(get(property, "PropertyGroup"), "VolumetricProp")
    @test first.(group.pairs) == ["ePropName", "sMethodName"]
    @test last(group.pairs[2]) == "free text method"
    ratio = get(get(blocks[2], "Property")[2], "Property-MethodID")
    @test last(get(get(ratio, "PropertyGroup"), "VolumetricProp").pairs[2]) ==
          "method not stated"
    first_property = get(get(first_block, "Property")[1], "Property-MethodID")
    hot_wire = get(get(first_property, "PropertyGroup"), "TransportProp")
    @test first.(hot_wire.pairs) == ["ePropName", "eMethodName"] ||
          first.(hot_wire.pairs) == ["ePropName", "sMethodName"]
    # the value-level uncertainty is always written; the evaluation of the property when known
    uncertainty = get(get(first_block, "Property")[1], "CombinedUncertainty")
    @test get(uncertainty, "eCombUncertEvalMethod") ==
          "Propagation of evaluated standard uncertainties"
    @test get(uncertainty, "nCombCoverageFactor") == 2
    @test get(uncertainty, "nCombUncertLevOfConfid") ≈ 95
end

@testitem "the XML of an article is escaped, namespaced and carries the notice" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    view = T.DataView(ds)
    context = T.ThermomlContext(view)
    groups = T.articles_of(view)
    ref = only(keys(groups))
    article = T.thermoml_article(context, ref, groups[ref])
    xml = T.thermoml_xml(article; comment = "a -- b\nsecond line")
    @test startswith(
        xml,
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!--\na - - b\nsecond line\n-->\n",
    )
    @test occursin("<DataReport xmlns=\"http://www.iupac.org/namespaces/ThermoML\">", xml)
    @test endswith(xml, "</DataReport>\n")
    @test occursin("<nPurityMolDigits>3</nPurityMolDigits>", xml)
    @test count("<purity>", xml) == 3
    @test occursin("<sAuthor>Doe, J.</sAuthor>\n    <sAuthor>Roe, R.</sAuthor>", xml)
    io = IOBuffer()
    T.write_xml(io, "x", "a < b & \"c\"", 0)
    @test String(take!(io)) == "<x>a &lt; b &amp; &quot;c&quot;</x>\n"
    @test T.xml_file_name("10.1016/j.fluid.2013.07.008", 1) ==
          "10.1016_j.fluid.2013.07.008.xml"[1:(end-4)]
    @test T.xml_file_name("", 7) == "article-7"
end

@testitem "export_points writes ThermoML JSON and one XML per article; the JSON reads back" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:integration] begin
    T = ThermophysicalDB
    ds = SampleData.build()
    view = T.points(ds; component = "methane")
    mktempdir() do dir
        report = T.export_points(
            joinpath(dir, "out"),
            view;
            formats = (:thermoml, :thermoml_xml),
            progress = false,
        )
        @test basename.(report.files) == ["out.thermoml.json", "out.thermoml"]
        @test report.bibtex === nothing                                   # no network needed
        xml_files = readdir(joinpath(dir, "out", "out.thermoml"))
        @test xml_files == ["10.5555_tdbfixture-001.xml"]

        doc = T.JSON.parse(read(joinpath(dir, "out", "out.thermoml.json"), String))
        article = only(doc["articles"])
        @test article["Version"]["nVersionMajor"] == 2
        # the package reads its own export: same points, conditions, digits and samples
        io = IOBuffer()
        T.write_json(
            io,
            T.thermoml_article(
                T.ThermomlContext(view),
                only(keys(T.articles_of(view))),
                view.rows,
            ),
            0,
            100,
        )
        back = T.parse_article("10.5555/tdbfixture-001.json", take!(io))
        @test back.error == ""
        @test back.doi == "10.5555/tdbfixture-001"
        @test length(back.experiments) == 1
        e = only(back.experiments)
        original = view.dataset.measurements
        rows = view.rows
        @test [m.value for m in e.measurements] == original.value[rows]
        @test [m.temperature for m in e.measurements] == original.temperature[rows]
        @test [m.pressure for m in e.measurements] == original.pressure[rows]
        # a count the source gave comes back as it was; a missing one is taken from the number
        @test [m.digits for m in e.measurements] == [0x04, 0x04]
        @test original.digits[rows] == [0x04, T.NO_DIGITS]
        @test [m.temperature_digits for m in e.measurements] == [0x06, 0x06]
        @test e.purpose == "Principal objective of the work"
        @test e.samples == [1, 1]
        co2 = first(c for c in back.compounds if c.formula == "CO2")
        summary = T.summarize_purity(only(co2.samples).steps)
        @test summary.purity ≈ 0.999 && summary.kind == 2 && summary.basis == 2
        @test only(e.properties).coverage == 2
    end
end

@testitem "the XML validates against ThermoML.xsd when xmllint is available" setup =
    [Fixtures, ThermoMLFixture, SampleData] tags = [:integration] begin
    T = ThermophysicalDB
    xsd = joinpath(pkgdir(T), "dev", "ThermoML.xsd")
    xmllint = Sys.which("xmllint")
    if xmllint === nothing || !isfile(xsd)
        @info "xmllint or dev/ThermoML.xsd not found: schema validation skipped"
    else
        ds = SampleData.build()
        mktempdir() do dir
            T.export_points(
                joinpath(dir, "all"),
                T.DataView(ds);
                formats = (:thermoml_xml,),
                progress = false,
            )
            file = joinpath(dir, "all", "all.thermoml", "10.5555_tdbfixture-001.xml")
            err = IOBuffer()
            ok = success(pipeline(`$xmllint --noout --schema $xsd $file`; stderr = err))
            ok || @info String(take!(err))
            @test ok
        end
    end
end

@testmodule ConditionsFixture begin
    # A fictitious article with everything the core columns do not hold: a variable other
    # than T, p and composition (with a phase), a phase tied to a component, a solvent, a
    # constraint with a phase and a component, and a TRC reference id.
    const JSON = """
    {
      "Citation": {
        "TRCRefID": {"yrYrPub": "2005", "sAuthor1": "doe", "sAuthor2": "roe", "nAuthorn": "0"},
        "sAuthor": ["Doe, J."],
        "sTitle": "A Fictitious Study of Conditions",
        "sDOI": "10.5555/tdbfixture-002",
        "sPubName": "Fictitious Journal of Thermophysics",
        "yrPubYr": "2005"
      },
      "Compound": [
        {"RegNum": {"nOrgNum": 1}, "sCommonName": ["water"], "sFormulaMolec": "H2O",
         "sStandardInChI": "InChI=1S/H2O/h1H2", "sStandardInChIKey": "XLYOFNOQVPJJNP-UHFFFAOYSA-N"},
        {"RegNum": {"nOrgNum": 2}, "sCommonName": ["ethanol"], "sFormulaMolec": "C2H6O",
         "sStandardInChI": "InChI=1S/C2H6O/c1-2-3/h3H,2H2,1H3",
         "sStandardInChIKey": "LFQSCWFLJHTTHZ-UHFFFAOYSA-N"}
      ],
      "PureOrMixtureData": [{
        "nPureOrMixtureDataNumber": 1,
        "Component": [{"RegNum": {"nOrgNum": 1}}, {"RegNum": {"nOrgNum": 2}}],
        "PhaseID": [{"ePhase": "Liquid", "RegNum": {"nOrgNum": 1}},
                    {"ePhase": "Liquid", "RegNum": {"nOrgNum": 2}}],
        "Property": [{
          "nPropNumber": 1, "ePresentation": "Direct value, X",
          "PropPhaseID": {"ePropPhase": "Liquid", "RegNum": {"nOrgNum": 2}},
          "Solvent": {"RegNum": [{"nOrgNum": 1}]},
          "Property-MethodID": {"PropertyGroup": {"VolumetricProp": {
            "ePropName": "Mass density, kg/m3", "sMethodName": "vibrating tube"}}}
        }],
        "Constraint": [{
          "nConstraintNumber": 1, "nConstraintValue": 1.5, "nConstrDigits": 2,
          "ConstraintID": {"ConstraintType": {"eMiscellaneous": "Frequency, MHz"},
                           "RegNum": {"nOrgNum": 2}},
          "ConstraintPhaseID": {"eConstraintPhase": "Liquid", "RegNum": {"nOrgNum": 1}}
        }],
        "Variable": [
          {"nVarNumber": 1, "VariableID": {"VariableType": {"eTemperature": "Temperature, K"}},
           "VarPhaseID": {"eVarPhase": "Liquid", "RegNum": {"nOrgNum": 1}}},
          {"nVarNumber": 2, "VariableID": {"VariableType": {"eComponentComposition": "Mole fraction"},
                                           "RegNum": {"nOrgNum": 1}},
           "VarPhaseID": {"eVarPhase": "Liquid"}},
          {"nVarNumber": 3, "VariableID": {"VariableType": {"eSolventComposition": "Solvent: Mole fraction"},
                                           "RegNum": {"nOrgNum": 2}},
           "VarPhaseID": {"eVarPhase": "Liquid"}},
          {"nVarNumber": 4, "VariableID": {"VariableType": {"eMiscellaneous": "Wavelength, nm"}}}
        ],
        "NumValues": [
          {"VariableValue": [
             {"nVarNumber": 1, "nVarValue": 298.15, "nVarDigits": 5},
             {"nVarNumber": 2, "nVarValue": 0.3, "nVarDigits": 1},
             {"nVarNumber": 3, "nVarValue": 0.7, "nVarDigits": 1},
             {"nVarNumber": 4, "nVarValue": 0.25, "nVarDigits": 2}],
           "PropertyValue": [{"nPropNumber": 1, "nPropValue": 912.5, "nPropDigits": 4}]},
          {"VariableValue": [
             {"nVarNumber": 1, "nVarValue": 303.15, "nVarDigits": 5},
             {"nVarNumber": 2, "nVarValue": 0.3, "nVarDigits": 1},
             {"nVarNumber": 3, "nVarValue": 0.7, "nVarDigits": 1},
             {"nVarNumber": 4, "nVarValue": 0.5, "nVarDigits": 2}],
           "PropertyValue": [{"nPropNumber": 1, "nPropValue": 908.1, "nPropDigits": 4}]}
        ]
      }]
    }
    """

    import ThermophysicalDB

    function dataset()
        T = ThermophysicalDB
        ds = T.Dataset()
        source = T.intern!(ds.sources, "thermoml")
        article = T.parse_article("10.5555/tdbfixture-002.json", Vector{UInt8}(JSON))
        isempty(article.error) || error(article.error)
        T.ingest!(ds, article, source, T.BuildReport())
        return ds
    end
end

@testitem "conditions without a column, phases of components, solvent and TRC id are kept" setup =
    [ConditionsFixture] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = ConditionsFixture.dataset()
    @test T.validate(ds)
    cd = ds.conditions
    roles = cd.role
    # phases (two, one per component), the frequency constraint, and the variable values
    @test count(==(0x03), roles) == 2
    @test count(==(0x01), roles) == 1
    @test count(==(0x02), roles) == 4          # solvent composition and amplitude, twice
    water = Int32(findfirst(n -> "water" in n, ds.compounds.names))
    ethanol = Int32(findfirst(n -> "ethanol" in n, ds.compounds.names))
    phases = findall(==(0x03), roles)
    @test cd.component[phases] == [water, ethanol]
    constraint = only(findall(==(0x01), roles))
    @test cd.component[constraint] == ethanol && cd.phase_component[constraint] == water
    @test T.pool_string(ds.phases, cd.phase[constraint]) == "Liquid"
    @test T.pool_string(ds.condition_groups, cd.group[constraint]) == "eMiscellaneous"
    variables = findall(==(0x02), roles)
    @test Set(T.pool_string(ds.condition_groups, cd.group[i]) for i in variables) ==
          Set(["eSolventComposition", "eMiscellaneous"])
    @test sort(cd.value[variables]) == [0.25, 0.5, 0.7, 0.7]
    # the phase of the core variables and the extras of the property
    @test T.extra_texts(ds, :experiment, "variable_phase:temperature") == ["Liquid"]
    @test T.extra_numbers(ds, :experiment, "variable_phase_component:temperature") ==
          [water]
    @test T.extra_texts(ds, :reference, "citation:TRCRefID:sAuthor1") == ["doe"]
    @test T.extra_texts(ds, :measurement, "solvent_ids") == fill(string(water), 2)
    @test T.extra_texts(ds, :measurement, "phase_ids") == fill(string(ethanol), 2)

    t = T.condition_table(ds)
    @test t.role ==
          ["phase", "phase", "constraint", "variable", "variable", "variable", "variable"]
    @test t.component[1:2] == ["water", "ethanol"]
    @test t.label[3] == "Frequency, MHz" && t.group[3] == "eMiscellaneous"
    @test t.value[3] == 1.5 && t.digits[3] == 2 && t.phase_component[3] == "water"
    @test t.measurement[1:3] == fill(T.NO_ID, 3) && t.measurement[4:end] == [1, 1, 2, 2]
    @test all(==("10.5555/tdbfixture-002"), t.doi)
    # a selection of one point keeps its variables and the conditions of its experiment
    one = T.DataView(ds, Int32[2])
    t1 = T.condition_table(one)
    @test count(==("variable"), t1.role) == 2 && count(==("phase"), t1.role) == 2
end

@testitem "the conditions are exported to ThermoML and read back unchanged" setup =
    [ConditionsFixture] tags = [:integration] begin
    T = ThermophysicalDB
    ds = ConditionsFixture.dataset()
    view = T.DataView(ds)
    mktempdir() do dir
        T.export_points(
            joinpath(dir, "c"),
            view;
            formats = (:thermoml, :thermoml_xml),
            progress = false,
        )
        doc = T.JSON.parse(read(joinpath(dir, "c", "c.thermoml.json"), String))
        article = only(doc["articles"])
        block = only(article["PureOrMixtureData"])
        @test article["Citation"]["TRCRefID"] == Dict(
            "yrYrPub" => 2005,
            "sAuthor1" => "doe",
            "sAuthor2" => "roe",
            "nAuthorn" => 0,
        )
        @test [p["ePhase"] for p in block["PhaseID"]] == ["Liquid", "Liquid"]
        @test [p["RegNum"]["nOrgNum"] for p in block["PhaseID"]] == [1, 2]
        constraint = only(block["Constraint"])
        @test constraint["ConstraintID"]["ConstraintType"] ==
              Dict("eMiscellaneous" => "Frequency, MHz")
        @test constraint["ConstraintID"]["RegNum"]["nOrgNum"] == 2
        @test constraint["ConstraintPhaseID"]["RegNum"]["nOrgNum"] == 1
        @test constraint["nConstrDigits"] == 2
        types = [first(keys(v["VariableID"]["VariableType"])) for v in block["Variable"]]
        @test types == [
            "eTemperature",
            "eComponentComposition",
            "eSolventComposition",
            "eMiscellaneous",
        ]
        @test block["Variable"][1]["VarPhaseID"]["RegNum"]["nOrgNum"] == 1
        @test block["Variable"][3]["VariableID"]["RegNum"]["nOrgNum"] == 2
        property = only(block["Property"])
        @test property["PropPhaseID"]["RegNum"]["nOrgNum"] == 2
        @test property["Solvent"]["RegNum"][1]["nOrgNum"] == 1
        @test length(block["NumValues"][1]["VariableValue"]) == 4

        # the package reads its own export: the same conditions
        io = IOBuffer()
        T.write_json(
            io,
            T.thermoml_article(
                T.ThermomlContext(view),
                only(keys(T.articles_of(view))),
                view.rows,
            ),
            0,
            100,
        )
        back = T.parse_article("10.5555/tdbfixture-002.json", take!(io))
        @test back.error == ""
        e = only(back.experiments)
        original = T.parse_article(
            "10.5555/tdbfixture-002.json",
            Vector{UInt8}(ConditionsFixture.JSON),
        ).experiments[1]
        @test e.constraints == original.constraints
        @test [(p.phase, p.orgs) for p in e.phases] == [(p.phase, p.orgs) for p in original.phases]
        @test [m.conditions for m in e.measurements] == [m.conditions for m in original.measurements]
        @test e.properties[1].solvent_orgs == original.properties[1].solvent_orgs
        @test e.properties[1].phase_orgs == original.properties[1].phase_orgs
    end
end

@testitem "the XML with conditions, phases and solvent validates against ThermoML.xsd" setup =
    [ConditionsFixture] tags = [:integration] begin
    T = ThermophysicalDB
    xsd = joinpath(pkgdir(T), "dev", "ThermoML.xsd")
    xmllint = Sys.which("xmllint")
    if xmllint === nothing || !isfile(xsd)
        @info "xmllint or dev/ThermoML.xsd not found: schema validation skipped"
    else
        ds = ConditionsFixture.dataset()
        mktempdir() do dir
            T.export_points(
                joinpath(dir, "c"),
                T.DataView(ds);
                formats = (:thermoml_xml,),
                progress = false,
            )
            file = joinpath(dir, "c", "c.thermoml", "10.5555_tdbfixture-002.xml")
            err = IOBuffer()
            ok = success(pipeline(`$xmllint --noout --schema $xsd $file`; stderr = err))
            ok || @info String(take!(err))
            @test ok
        end
    end
end
