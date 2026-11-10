@testmodule ThermoMLFixture begin
    # A miniature article with the same structure as the real archive: a mixture with a
    # composition constraint and T/P variables, a pure compound with a constraint on P and
    # a "Frequency" condition plus a ratio-type property, and an unsupported 4-component
    # system. Everything here is fictitious: the bibliographic data do not describe a real
    # article (the DOI uses the Crossref test prefix) and no number comes from the archive.
    const JSON = """
    {
      "Citation": {
        "sAuthor": ["Doe, J.", "Roe, R."],
        "sKeyword": ["carbon dioxide", "methane"],
        "sTitle": "Thermal Conductivity of a Fictitious Binary Gas Mixture",
        "sDOI": "10.5555/tdbfixture-001",
        "sPubName": "Fictitious Journal of Thermophysics",
        "yrPubYr": "2005",
        "sVol": "1",
        "sPage": "1-12",
        "eType": "journal",
        "sAbstract": "A fictitious abstract."
      },
      "Compound": [
        {"RegNum": {"nOrgNum": 1}, "sCommonName": ["methane", "carbane"],
         "sFormulaMolec": "CH4", "sStandardInChI": "InChI=1S/CH4/h1H4",
         "sStandardInChIKey": "VNWKTOKETHGBQD-UHFFFAOYSA-N",
         "Sample": [{"nSampleNm": 1, "eSource": "Commercial source",
           "purity": [{"nStep": 1, "nPurityMass": 99.95, "nPurityMassDigits": 4,
                       "nWaterMassPerCent": 0.002, "eAnalMeth": ["Stated by supplier"]}]}]},
        {"RegNum": {"nOrgNum": 2}, "sCommonName": ["carbon dioxide"],
         "sFormulaMolec": "CO2", "sStandardInChI": "InChI=1S/CO2/c2-1-3",
         "sStandardInChIKey": "CURLTUGMZLYLDI-UHFFFAOYSA-N",
         "Sample": [{"nSampleNm": 1, "eSource": "Commercial source",
           "purity": [
             {"nStep": 1, "nPurityMass": 99.5, "nPurityMassDigits": 3,
              "eAnalMeth": ["Stated by supplier"], "ePurifMethod": ["None used"]},
             {"nStep": 2, "nPurityMol": 99.9, "nPurityMolDigits": 3,
              "eAnalMeth": ["Gas chromatography"], "sAnalMeth": ["FID"],
              "ePurifMethod": ["Fractional distillation"], "sPurifMethod": ["twice"]}]}]},
        {"RegNum": {"nOrgNum": 3}, "sCommonName": ["water"], "sFormulaMolec": "H2O"}
      ],
      "PureOrMixtureData": [
        {
          "nPureOrMixtureDataNumber": 1,
          "eExpPurpose": "Principal objective of the work",
          "Component": [
            {"RegNum": {"nOrgNum": 2}, "nSampleNm": 1},
            {"RegNum": {"nOrgNum": 1}, "nSampleNm": 1}
          ],
          "PhaseID": [{"ePhase": "Gas"}],
          "Property": [{
            "nPropNumber": 1,
            "ePresentation": "Direct value, X",
            "PropPhaseID": {"ePropPhase": "Gas"},
            "CombinedUncertainty": {"nCombUncertAssessNum": 1,
              "sCombUncertEvaluator": "Fictitious evaluator",
              "eCombUncertEvalMethod": "Propagation of evaluated standard uncertainties",
              "nCombCoverageFactor": 2, "nCombUncertLevOfConfid": 95},
            "Property-MethodID": {
              "RegNum": {"nOrgNum": 2},
              "PropertyGroup": {"TransportProp": {
                "ePropName": "Thermal conductivity, W/m/K",
                "eMethodName": "Hot wire method"}}
            }
          }],
          "Constraint": [{
            "nConstraintNumber": 1, "nConstraintValue": 0.5, "nConstrDigits": 2,
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
            {"VariableValue": [{"nVarNumber": 1, "nVarValue": 298.893, "nVarDigits": 6},
                               {"nVarNumber": 2, "nVarValue": 6100, "nVarDigits": 2}],
             "PropertyValue": [{"nPropNumber": 1, "nPropValue": 0.03312, "nPropDigits": 4,
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
    a = T.parse_article("10.5555/tdbfixture-001.json", Vector{UInt8}(ThermoMLFixture.JSON))
    @test a.error == ""
    @test a.doi == "10.5555/tdbfixture-001"
    @test a.year == 2005
    @test a.authors == ["Doe, J.", "Roe, R."]
    @test a.extras == [
        "keywords" => "carbon dioxide; methane",
        "citation:eType" => "journal",
        "abstract" => "A fictitious abstract.",
    ]
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
    @test p.coverage == 2 &&
          p.unc_method == "Propagation of evaluated standard uncertainties"
    @test p.extras == ["property_component" => "carbon dioxide"]
    @test p.evaluator == "Fictitious evaluator" && p.assessment == 1.0
    @test e1.purpose == "Principal objective of the work"
    @test e1.samples == [1, 1]
    m1, m2 = e1.measurements
    @test (m1.digits, m1.temperature_digits, m1.pressure_digits) == (0x04, 0x06, 0x02)
    @test (m2.digits, m2.temperature_digits) == (T.NO_DIGITS, T.NO_DIGITS)
    @test (m1.temperature, m1.pressure, m1.value) == (298.893, 6100.0, 0.03312)
    @test m1.composition[1] == 0.5 && all(isnan, m1.composition[2:3])
    @test m1.unc == 0.00059
    @test isnan(m2.unc)

    e2 = a.experiments[2]
    @test [p.label for p in e2.properties] == ["Mass density", "Mass density [ratio to reference state]"]
    @test [p.unit for p in e2.properties] == ["kg/m3", ""]
    @test e2.properties[1].method == "free text method" && e2.properties[1].method_text
    @test !p.method_text
    @test m1.composition_digits == (0x02, T.NO_DIGITS, T.NO_DIGITS)   # digits of the constraint
    @test [m.property for m in e2.measurements] == [1, 2]
    @test all(m -> m.pressure == 101.325 && m.temperature == 293.15, e2.measurements)
    @test all(m -> m.conditions === nothing, e2.measurements)
    # a constraint without a column is kept with the experiment, with its kind and its label
    # (the pressure is also in the column of every point)
    @test e2.constraints == [
        T.ParsedCondition("ePressure", "Pressure, kPa", 101.325, T.NO_DIGITS, "", 0, 0),
        T.ParsedCondition("eMiscellaneous", "Frequency, MHz", 1.0, T.NO_DIGITS, "", 0, 0),
    ]
    @test isempty(e2.extras)
end

@testitem "parse_article reads samples, purity steps and the purity summary" setup =
    [ThermoMLFixture] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    a = T.parse_article("10.5555/tdbfixture-001.json", Vector{UInt8}(ThermoMLFixture.JSON))
    methane, co2, water = a.compounds[1], a.compounds[2], a.compounds[3]
    @test isempty(water.samples)

    s = only(methane.samples)
    @test (s.number, s.origin, s.status) == (1, "Commercial source", "")
    step = only(s.steps)
    @test step.mass ≈ 0.9995 && isnan(step.mole) && step.digits == 0x04
    @test step.water_mass ≈ 2e-5
    sm = T.summarize_purity(s.steps)
    @test sm.purity ≈ 0.9995 && sm.kind == 1 && isnan(sm.initial) && sm.initial_kind == 0
    @test sm.basis == 1 && sm.analysis == ["Stated by supplier"]

    c = only(co2.samples)
    @test length(c.steps) == 2
    @test c.steps[2].analysis_text == "FID" && c.steps[2].purification_text == "twice"
    sc = T.summarize_purity(c.steps)
    @test sc.purity ≈ 0.999 && sc.kind == 2        # mole fraction of the last step
    @test sc.initial ≈ 0.995 && sc.initial_kind == 1
    @test sc.basis == 2                            # measured beats the supplier's word
    @test sc.analysis == ["Stated by supplier", "Gas chromatography"]
    @test sc.purification == ["None used", "Fractional distillation"]

    @test T.analysis_basis("Stated by supplier") == 1
    @test T.analysis_basis("Estimated by the compiler") == 3
    @test T.analysis_basis("Not known") == 0 && T.analysis_basis("") == 0
    @test T.analysis_basis("Estimation") == 3 && T.analysis_basis("Other") == 0
    @test T.analysis_basis("Karl Fischer titration") == 2
    @test T.purity_basis_code(["Estimated by the compiler", "Stated by supplier"]) == 1
    empty = T.summarize_purity(T.ParsedPurityStep[])
    @test isnan(empty.purity) && empty.kind == 0 && empty.basis == 0
end

@testitem "parse_article reports instead of throwing" tags = [:unit, :fast] begin
    T = ThermophysicalDB
    broken = T.parse_article("x.json", Vector{UInt8}("{oops"))
    @test !isempty(broken.error)
    @test isempty(broken.experiments)
    not_object = T.parse_article("y.json", Vector{UInt8}("[1, 2]"))
    @test occursin("not an object", not_object.error)
    # Missing optional parts are tolerated, and the file name stands in for the DOI.
    bare = T.parse_article("10.5555/tdbfixture-005.json", Vector{UInt8}("{}"))
    @test bare.error == "" && bare.doi == "10.5555/tdbfixture-005"
end

@testitem "build_dataset merges articles into a queryable dataset" setup =
    [Fixtures, ThermoMLFixture] tags = [:integration] begin
    T = ThermophysicalDB
    mktempdir() do dir
        archive = joinpath(dir, "t.tgz")
        Fixtures.make_tgz(
            archive,
            Dict("10.5555/tdbfixture-001.json" => ThermoMLFixture.JSON),
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

        # samples: one per described compound, and the experiments point at them
        @test T.validate(ds)
        @test length(ds.samples) == 2 && length(ds.purity_steps) == 3
        co2 = findfirst(==("carbon dioxide"), first.(ds.compounds.names))
        row = ds.samples.index[(Int32(1), Int32(co2), Int32(1))]
        @test ds.samples.purity[row] ≈ 0.999 && ds.samples.purity_kind[row] == 0x02
        @test ds.samples.purity_initial[row] ≈ 0.995
        @test ds.samples.purity_basis[row] == 0x02 && ds.samples.nsteps[row] == 0x02
        @test T.pool_string(ds.origins, ds.samples.origin[row]) == "Commercial source"
        @test [T.pool_string(ds.analyses, i) for i in ds.samples.analysis[row]] == ["Stated by supplier", "Gas chromatography"]
        @test ds.experiments.samples[1][1] == row           # carbon dioxide
        @test ds.experiments.samples[2][1] != T.NO_ID       # methane
        @test ds.experiments.samples[3][1] == T.NO_ID       # no third component
        @test ds.experiments.samples[1][2] == T.NO_ID       # water: no sample described
        @test T.pool_string(ds.purposes, ds.experiments.purpose[1]) ==
              "Principal objective of the work"
        @test ds.measurements.digits[1:2] == [0x04, T.NO_DIGITS]
        @test ds.measurements.composition_digits[1][1:2] == [0x02, 0x02]
        @test ds.method_texts.strings == ["free text method"]
        @test ds.measurements.unc_k[1] == 2.0 && isnan(ds.measurements.unc_k[2])
        @test T.pool_string(ds.unc_methods, ds.measurements.unc_method[1]) ==
              "Propagation of evaluated standard uncertainties"
        @test ds.measurements.unc_method[2] == T.NO_ID

        water = T.table(T.points(ds; component = "water"))
        @test water.value == [998.2, 1.0001]
        @test water.unit == ["kg/m3", ""]
        @test water.method == ["free text method", ""]

        cd = ds.conditions
        # the first system: its phase and the composition it fixes; the second: the pressure
        # and the frequency it fixes
        @test length(cd) == 4 &&
              cd.scope == fill(0x01, 4) &&
              cd.role == [0x03, 0x01, 0x01, 0x01]
        @test T.pool_string(ds.condition_groups, cd.group[2]) == "eComponentComposition"
        @test T.pool_string(ds.condition_groups, cd.group[3]) == "ePressure"
        @test cd.value[2] == 0.5 && cd.value[3] == 101.325
        @test T.pool_string(ds.condition_labels, cd.label[1]) == "Gas"
        @test cd.component[1] == T.NO_ID
        @test T.pool_string(ds.condition_groups, cd.group[4]) == "eMiscellaneous"
        @test T.pool_string(ds.condition_labels, cd.label[4]) == "Frequency, MHz"
        @test cd.value[4] == 1.0 && cd.digits[4] == T.NO_DIGITS
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
        files = Dict(
            "bad.json" => "{not json",
            "10.5555/tdbfixture-003.json" => ThermoMLFixture.JSON,
        )
        Fixtures.make_tgz(archive, files)
        ds, report = @test_logs (:warn, r"could not be parsed") (:info, r"skipped") (
            :info,
            r"ReactionData",
        ) match_mode = :any T.build_dataset(archive; progress = false)
        @test length(report.failed) == 1 && startswith(report.failed[1], "bad.json")
        @test length(ds) == 4
    end
end
