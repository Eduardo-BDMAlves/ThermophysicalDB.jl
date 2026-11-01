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
        "Variable",
        "NumValues",
    ]
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
