@testmodule SaltWater begin
    using ThermophysicalDB: ThermophysicalDB
    const T = ThermophysicalDB

    const M_SALT = 58.44277
    const M_WATER = 18.01528

    # Three NaCl + water systems, one for each way the sources give the composition, and a
    # system without a composition kind. Every one has the same mixture: x(NaCl) = 0.1.
    function build()
        ds = T.Dataset()
        src = T.intern!(ds.sources, "thermoml")
        ref = T.add_reference!(
            ds.references;
            doi = "10.5555/tdbcomp-001",
            year = 2001,
            source = src,
        )
        salt = T.add_compound!(
            ds.compounds;
            inchikey = "FAPWRFPIFSIZLT-UHFFFAOYSA-M",
            names = ["sodium chloride"],
            formula = "ClNa",
        )
        water = T.add_compound!(ds.compounds; names = ["water"], formula = "H2O")
        rho = T.add_property!(ds.properties, "Mass density", "kg/m3")
        kinds = ("Mole fraction", "Mass fraction", "Molality, mol/kg", "")
        w = M_SALT * 0.1 / (M_SALT * 0.1 + M_WATER * 0.9)
        b = 1000 * 0.1 / (0.9 * M_WATER)
        values = ((0.1, 0.9), (w, 1 - w), (b, NaN), (0.1, 0.9))
        for (k, kind) in enumerate(kinds)
            id = isempty(kind) ? T.NO_ID : T.intern!(ds.kinds, kind)
            e = T.add_experiment!(
                ds.experiments;
                reference = ref,
                components = [salt, water],
                kinds = [id, id],
            )
            T.add_measurement!(
                ds.measurements;
                experiment = e,
                property = rho,
                value = 1070.0 + k,
                temperature = 298.15,
                pressure = 101.325,
                composition = (values[k]..., NaN),
            )
        end
        return ds
    end
end

@testitem "scale kernels agree with hand calculations and round trip" setup = [SaltWater] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    M = [SaltWater.M_SALT, SaltWater.M_WATER]
    x = [0.1, 0.9]
    mean_mass = 0.1 * M[1] + 0.9 * M[2]

    w = T.convert_composition(x, :mole_fraction, :mass_fraction; molar_mass = M)
    @test w ≈ [0.1 * M[1], 0.9 * M[2]] ./ mean_mass
    b = T.convert_composition(x, :mole_fraction, :molality; molar_mass = M, solvent = 2)
    @test b[1] ≈ 100 / (0.9 * M[2]) && isnan(b[2])
    r = T.convert_composition(x, :mole_fraction, :amount_ratio; solvent = 2)
    @test r[1] ≈ 0.1 / 0.9
    c = T.convert_composition(
        x,
        :mole_fraction,
        :molarity;
        molar_mass = M,
        density = 1070.0,
    )
    @test c[1] ≈ 1070 * 0.1 / mean_mass
    # the volume of solution is filled by the components: sum(c_i M_i) = density (g/dm3)
    @test sum(c .* M) ≈ 1070.0
    rho_i = T.convert_composition(
        x,
        :mole_fraction,
        :mass_concentration;
        molar_mass = M,
        density = 1070.0,
    )
    @test sum(rho_i) ≈ 1070.0

    for scale in T.COMPOSITION_SCALES
        v = T.convert_composition(
            x,
            :mole_fraction,
            scale;
            molar_mass = M,
            solvent = 2,
            density = 1070.0,
        )
        back = T.convert_composition(
            v,
            scale,
            :mole_fraction;
            molar_mass = M,
            solvent = 2,
            density = 1070.0,
        )
        @test back ≈ x
    end
    # from and to a scale without passing through mole fractions in the user's hands
    @test T.convert_composition(w, :mass_fraction, :molality; molar_mass = M, solvent = 2) ≈
          b nans = true
end

@testitem "scale kernels refuse what they cannot know" setup = [SaltWater] tags =
    [:unit, :fast] begin
    T = ThermophysicalDB
    M = [SaltWater.M_SALT, SaltWater.M_WATER]
    x = [0.1, 0.9]
    err(f) =
        try
            f()
            ""
        catch e
            sprint(showerror, e)
        end
    @test occursin(
        "molar mass",
        err(() -> T.convert_composition(x, :mole_fraction, :mass_fraction)),
    )
    @test occursin(
        "solvent",
        err(() -> T.convert_composition(x, :mole_fraction, :molality; molar_mass = M)),
    )
    @test occursin(
        "density",
        err(() -> T.convert_composition(x, :mole_fraction, :molarity; molar_mass = M)),
    )
    @test occursin(
        "do not add up",
        err(
            () -> T.convert_composition(
                [0.3, 0.3],
                :mole_fraction,
                :mass_fraction;
                molar_mass = M,
            ),
        ),
    )
    @test_throws ArgumentError T.convert_composition(x, :bogus, :molality)
    @test_throws ArgumentError T.convert_composition(
        x,
        :mole_fraction,
        :molality;
        molar_mass = [1.0],
    )
    # a single missing fraction is the rest
    @test T.convert_composition([0.1, NaN], :mole_fraction, :mole_fraction) ≈ x
end

@testitem "a selection is converted from any source scale, with the reason when it is not" setup =
    [SaltWater] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SaltWater.build()
    v = T.points(ds)
    M = Dict("sodium chloride" => SaltWater.M_SALT, "water" => SaltWater.M_WATER)

    conv = T.convert_composition(v, :mole_fraction; molar_mass = M, solvent = "water")
    # the system without a kind is the only one not converted
    @test conv.status == [:ok, :ok, :ok, :no_composition]
    @test conv.x1[1:3] ≈ fill(0.1, 3)
    @test conv.x2[1:3] ≈ fill(0.9, 3)
    @test isnan(conv.x1[4])
    @test all(==("Mole fraction"), conv.xkind)
    @test occursin("no_composition", sprint(show, conv))

    # a source in molality has no amount of its solvent: the solvent has to be told
    mass = T.convert_composition(v, :mass_fraction; molar_mass = M)
    @test mass.status == [:ok, :ok, :solvent_not_given, :no_composition]
    mass = T.convert_composition(v, :mass_fraction; molar_mass = M, solvent = "water")
    @test mass.status == [:ok, :ok, :ok, :no_composition]
    @test mass.x1[1:3] ≈ fill(
        SaltWater.M_SALT * 0.1 / (SaltWater.M_SALT * 0.1 + SaltWater.M_WATER * 0.9),
        3,
    )

    # nothing is guessed: no molar mass, no solvent, no density
    none = T.convert_composition(v, :mass_fraction; solvent = "water")
    @test none.status ==
          [:missing_molar_mass, :missing_molar_mass, :missing_molar_mass, :no_composition]
    nosolvent = T.convert_composition(v, :molality; molar_mass = M)
    @test nosolvent.status ==
          [:solvent_not_given, :solvent_not_given, :solvent_not_given, :no_composition]
    nodensity = T.convert_composition(v, :molarity; molar_mass = M, solvent = "water")
    @test nodensity.status ==
          [:missing_density, :missing_density, :missing_density, :no_composition]

    # density as a number or as a vector with one value for each point
    c1 = T.convert_composition(
        v,
        :molarity;
        molar_mass = M,
        density = 1070.0,
        solvent = "water",
    )
    c2 = T.convert_composition(
        v,
        :molarity;
        molar_mass = M,
        density = fill(1070.0, 4),
        solvent = "water",
    )
    @test c1.x1[1:3] ≈ c2.x1[1:3]
    @test c1.status[1:3] == [:ok, :ok, :ok]
    @test_throws ArgumentError T.convert_composition(
        v,
        :molarity;
        molar_mass = M,
        density = [1.0],
        solvent = "water",
    )
    @test_throws ArgumentError T.convert_composition(
        v,
        :molarity;
        molar_mass = M,
        density = -1.0,
        solvent = "water",
    )
    @test_throws ArgumentError T.convert_composition(
        v,
        :molarity;
        molar_mass = M,
        density = (T, p) -> 1000.0,
    )

    @test_throws ArgumentError T.convert_composition(
        v,
        :molality;
        molar_mass = M,
        solvent = "plutonium",
    )
    @test_throws ArgumentError T.convert_composition(
        v,
        :mole_fraction;
        strict = true,
        molar_mass = M,
    )
    @test_throws ArgumentError T.convert_composition(v, :nonsense)
    # what the user gives wins; a wrong entry is refused
    @test_throws ArgumentError T.convert_composition(
        v,
        :mass_fraction;
        molar_mass = Dict("water" => -1.0),
    )
    # the data of the archive are untouched
    @test ds.measurements.composition[1][1] == 0.1
end

@testitem "table and export_points can convert the composition" setup =
    [SaltWater, CompoundFixture] tags = [:unit, :fast] begin
    T = ThermophysicalDB
    ds = SaltWater.build()
    v = T.points(ds)
    M = Dict("sodium chloride" => SaltWater.M_SALT, "water" => SaltWater.M_WATER)

    raw = T.table(v)
    @test raw.xkind[3] == "Molality, mol/kg"
    t = @test_logs (:warn, r"1 points") T.table(
        v;
        composition = :mass_fraction,
        molar_mass = M,
        solvent = "water",
        details = true,
    )
    @test all(==("Mass fraction"), t.xkind)
    w = M["sodium chloride"] * 0.1 / (M["sodium chloride"] * 0.1 + M["water"] * 0.9)
    @test t.x1[1:3] ≈ fill(w, 3)
    @test t.composition_status == [:ok, :ok, :ok, :no_composition]
    @test_throws ArgumentError T.table(
        v;
        composition = :mass_fraction,
        molar_mass = M,
        solvent = "water",
        strict = true,
    )

    # molar masses from the compound database, linked by InChIKey and by name
    mktempdir() do dir
        db = CompoundFixture.database(dir)
        dbt = @test_logs (:warn, r"not converted") T.table(
            v;
            composition = :mass_fraction,
            compounds = db,
            solvent = "water",
        )
        @test dbt.x1[1:3] ≈ fill(w, 3) rtol = 1.0e-4
    end

    mktempdir() do dir
        report = @test_logs (:warn, r"not converted") T.export_points(
            joinpath(dir, "salt"),
            v;
            formats = (:csv,),
            references = false,
            reference = :doi,
            composition = :molality,
            solvent = "water",
            molar_mass = M,
            progress = false,
        )
        text = read(joinpath(dir, "salt", "salt.csv"), String)
        @test occursin("x1 [mol/kg]", text)
    end
end
