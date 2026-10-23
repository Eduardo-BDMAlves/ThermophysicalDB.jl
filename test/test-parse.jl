@testmodule ThermoMLFixture begin
    # A miniature article with the same structure as the real archive: a mixture with a
    # composition constraint and T/P variables, a pure compound with a constraint on P and
    # a "Frequency" condition plus a ratio-type property, and an unsupported 4-component
    # system. The numbers are synthetic.
    const JSON = """
    {
      "Citation": {
        "sAuthor": ["Patek, J.", "Klomfar, J."],
        "sKeyword": ["carbon dioxide", "methane"],
        "sTitle": "Thermal Conductivity of CO2 + CH4",
        "sDOI": "10.1007/s10765-005-5566-6",
        "sPubName": "Int. J. Thermophys.",
        "yrPubYr": "2005",
        "sVol": "26",
        "sPage": "577-592",
        "eType": "journal"
      },
      "Compound": [
        {"RegNum": {"nOrgNum": 1}, "sCommonName": ["methane", "carbane"],
         "sFormulaMolec": "CH4", "sStandardInChI": "InChI=1S/CH4/h1H4",
         "sStandardInChIKey": "VNWKTOKETHGBQD-UHFFFAOYSA-N"},
        {"RegNum": {"nOrgNum": 2}, "sCommonName": ["carbon dioxide"],
         "sFormulaMolec": "CO2", "sStandardInChI": "InChI=1S/CO2/c2-1-3",
         "sStandardInChIKey": "CURLTUGMZLYLDI-UHFFFAOYSA-N"},
        {"RegNum": {"nOrgNum": 3}, "sCommonName": ["water"], "sFormulaMolec": "H2O"}
      ],
      "PureOrMixtureData": [
        {
          "nPureOrMixtureDataNumber": 1,
          "Component": [
            {"RegNum": {"nOrgNum": 2}, "nSampleNm": 1},
            {"RegNum": {"nOrgNum": 1}, "nSampleNm": 1}
          ],
          "PhaseID": [{"ePhase": "Gas"}],
          "Property": [{
            "nPropNumber": 1,
            "ePresentation": "Direct value, X",
            "PropPhaseID": {"ePropPhase": "Gas"},
            "CombinedUncertainty": {"nCombUncertLevOfConfid": 95},
            "Property-MethodID": {
              "RegNum": {"nOrgNum": 2},
              "PropertyGroup": {"TransportProp": {
                "ePropName": "Thermal conductivity, W/m/K",
                "eMethodName": "Hot wire method"}}
            }
          }],
          "Constraint": [{
            "nConstraintNumber": 1, "nConstraintValue": 0.5,
            "ConstraintID": {
              "ConstraintType": {"eComponentComposition": "Mole fraction"},
              "RegNum": {"nOrgNum": 2}}
          }],
          "Variable": [
            {"nVarNumber": 1,
             "VariableID": {"VariableType": {"eTemperature": "Temperature, K"}}},
            {"nVarNumber": 2,
             "VariableID": {"VariableType": {"ePressure": "Pressure, kPa"}}}
          ],
          "NumValues": [
            {"VariableValue": [{"nVarNumber": 1, "nVarValue": 298.893},
                               {"nVarNumber": 2, "nVarValue": 6100}],
             "PropertyValue": [{"nPropNumber": 1, "nPropValue": 0.03312,
                                "CombinedUncertainty": {"nCombExpandUncertValue": 0.00059}}]},
            {"VariableValue": [{"nVarNumber": 1, "nVarValue": 299.016},
                               {"nVarNumber": 2, "nVarValue": 5760}],
             "PropertyValue": [{"nPropNumber": 1, "nPropValue": 0.02896}]}
          ]
        },
        {
          "nPureOrMixtureDataNumber": 2,
          "Component": [{"RegNum": {"nOrgNum": 3}, "nSampleNm": 1}],
          "Property": [
            {"nPropNumber": 1, "ePresentation": "Direct value, X",
             "PropPhaseID": {"ePropPhase": "Liquid"},
             "Property-MethodID": {"PropertyGroup": {"VolumetricProp": {
               "ePropName": "Mass density, kg/m3", "sMethodName": "free text method"}}}},
            {"nPropNumber": 2, "ePresentation": "Ratio with the reference state, X/X(REF)",
             "Property-MethodID": {"PropertyGroup": {"VolumetricProp": {
               "ePropName": "Mass density, kg/m3"}}}}
          ],
          "Constraint": [
            {"nConstraintNumber": 1, "nConstraintValue": 101.325,
             "ConstraintID": {"ConstraintType": {"ePressure": "Pressure, kPa"}}},
            {"nConstraintNumber": 2, "nConstraintValue": 1.0,
             "ConstraintID": {"ConstraintType": {"eMiscellaneous": "Frequency, MHz"}}}
          ],
          "Variable": [{"nVarNumber": 1,
             "VariableID": {"VariableType": {"eTemperature": "Temperature, K"}}}],
          "NumValues": [{
            "VariableValue": [{"nVarNumber": 1, "nVarValue": 293.15}],
            "PropertyValue": [{"nPropNumber": 1, "nPropValue": 998.2},
                              {"nPropNumber": 2, "nPropValue": 1.0001}]
          }]
        },
        {
          "nPureOrMixtureDataNumber": 3,
          "Component": [{"RegNum": {"nOrgNum": 1}}, {"RegNum": {"nOrgNum": 2}},
                        {"RegNum": {"nOrgNum": 3}}, {"RegNum": {"nOrgNum": 4}}]
        }
      ],
      "ReactionData": [{"nReactionDataNumber": 1}]
    }
    """
end

@testitem "parse_article extracts conditions, uncertainty and qualifiers" setup =
    [ThermoMLFixture] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    a = T.parse_article(
        "10.1007/s10765-005-5566-6.json",
        Vector{UInt8}(ThermoMLFixture.JSON),
    )
    @test a.error == ""
    @test a.doi == "10.1007/s10765-005-5566-6"
    @test a.year == 2005
    @test a.authors == ["Patek, J.", "Klomfar, J."]
    @test a.extras == ["keywords" => "carbon dioxide; methane"]
    @test length(a.compounds) == 3
    @test a.compounds[3].inchikey == ""
    @test a.reaction_blocks == 1
    @test length(a.experiments) == 2
    @test length(a.skipped) == 1 && occursin("4 components", a.skipped[1])

    e1 = a.experiments[1]
    @test e1.orgnums == [2, 1]
    @test e1.kinds == ["Mole fraction", ""]
    @test e1.extras == ["phases" => "Gas"]
    p = e1.properties[1]
    @test (p.label, p.unit, p.group) == ("Thermal conductivity", "W/m/K", "TransportProp")
    @test (p.method, p.phase) == ("Hot wire method", "Gas")
    @test p.level ≈ 0.95
    @test p.extras == ["property_component" => "carbon dioxide"]
    m1, m2 = e1.measurements
    @test (m1.temperature, m1.pressure, m1.value) == (298.893, 6100.0, 0.03312)
    @test m1.composition[1] == 0.5 && all(isnan, m1.composition[2:3])
    @test m1.unc == 0.00059
    @test isnan(m2.unc)

    e2 = a.experiments[2]
    @test [p.label for p in e2.properties] == ["Mass density", "Mass density [ratio to reference state]"]
    @test [p.unit for p in e2.properties] == ["kg/m3", ""]
    @test e2.properties[1].method == "free text method"
    @test [m.property for m in e2.measurements] == [1, 2]
    @test all(m -> m.pressure == 101.325 && m.temperature == 293.15, e2.measurements)
    @test all(m -> m.extras == ["Frequency, MHz" => 1.0], e2.measurements)
    @test isempty(e2.extras)
end

@testitem "parse_article reports instead of throwing" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    broken = T.parse_article("x.json", Vector{UInt8}("{oops"))
    @test !isempty(broken.error)
    @test isempty(broken.experiments)
    not_object = T.parse_article("y.json", Vector{UInt8}("[1, 2]"))
    @test occursin("not an object", not_object.error)
    # Missing optional parts are tolerated, and the file name stands in for the DOI.
    bare = T.parse_article("10.1/z.json", Vector{UInt8}("{}"))
    @test bare.error == "" && bare.doi == "10.1/z"
end

@testitem "build_dataset merges articles into a queryable dataset" setup =
    [Fixtures, ThermoMLFixture] tags = [:integration] begin
    T = ThermophysicalDB
    mktempdir() do dir
        archive = joinpath(dir, "t.tgz")
        Fixtures.make_tgz(
            archive,
            Dict("10.1007/s10765-005-5566-6.json" => ThermoMLFixture.JSON),
        )
        ds, report =
            @test_logs (:info, r"skipped") (:info, r"ReactionData") match_mode = :any T.build_dataset(
                archive;
                progress = false,
            )
        @test T.validate(ds)
        @test (report.articles, report.experiments, report.reaction_blocks) == (1, 2, 1)
        @test isempty(report.failed) && length(report.skipped) == 1
        @test length(ds) == 4
        @test length(ds.references) == 1 && length(ds.compounds) == 3
        @test ds.properties.label == [
            "Thermal conductivity",
            "Mass density",
            "Mass density [ratio to reference state]",
        ]
        @test ds.properties.unit == ["W/m/K", "kg/m3", ""]

        tbl = T.table(T.points(ds; component = "methane"))
        @test tbl.components == fill("carbon dioxide + methane", 2)
        @test tbl.temperature == [298.893, 299.016]
        @test tbl.pressure == [6100.0, 5760.0]
        @test tbl.x1 == [0.5, 0.5] && all(isnan, tbl.x2)
        @test tbl.xkind == fill("Mole fraction", 2)
        @test isequal(tbl.unc, [0.00059, NaN])
        @test isequal(tbl.unc_level, [0.95, NaN])
        @test isequal(tbl.unc_k2, [0.00059, NaN])
        @test tbl.method == fill("Hot wire method", 2) && tbl.phase == fill("Gas", 2)

        water = T.table(T.points(ds; component = "water"))
        @test water.value == [998.2, 1.0001]
        @test water.unit == ["kg/m3", ""]
        @test water.method == ["free text method", ""]

        @test isequal(
            T.extra_numbers(ds, :measurement, "Frequency, MHz"),
            [NaN, NaN, 1.0, 1.0],
        )
        @test T.extra_texts(ds, :measurement, "property_component") ==
              ["carbon dioxide", "carbon dioxide", "", ""]
        @test T.extra_texts(ds, :reference, "keywords") == ["carbon dioxide; methane"]
        @test T.extra_texts(ds, :experiment, "phases") == ["Gas", ""]
    end
end

@testitem "build_dataset skips unparsable articles and says so" setup =
    [Fixtures, ThermoMLFixture] tags = [:integration] begin
    T = ThermophysicalDB
    mktempdir() do dir
        archive = joinpath(dir, "t.tgz")
        files = Dict("bad.json" => "{not json", "10.1/x.json" => ThermoMLFixture.JSON)
        Fixtures.make_tgz(archive, files)
        ds, report = @test_logs (:warn, r"could not be parsed") (:info, r"skipped") (
            :info,
            r"ReactionData",
        ) match_mode = :any T.build_dataset(archive; progress = false)
        @test length(report.failed) == 1 && startswith(report.failed[1], "bad.json")
        @test length(ds) == 4
    end
end
