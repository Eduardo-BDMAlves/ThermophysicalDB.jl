@testitem "physical rules reject what no real measurement can be" setup = [Synthetic] tags =
    [:unit] begin
    T = ThermophysicalDB
    w = Synthetic.world()
    e = Synthetic.pure(w, w.refs.a)
    eb = Synthetic.binary(w, w.refs.b)
    add!(prop, v; kwargs...) = Synthetic.add!(
        w,
        e,
        prop,
        v;
        temperature = 300.0,
        pressure = 101.325,
        x = (1.0, NaN, NaN),
        kwargs...,
    )
    good = [
        add!(w.props.density, 997.0),
        add!(w.props.viscosity, 8.9e-4),
        add!(w.props.ratio, 1.3),
        add!(w.props.permittivity, 78.0),
        add!(w.props.fraction, 0.4),
        # Properties that may legitimately be negative or zero are never rejected.
        add!(w.props.excess, -1.5e-6),
        add!(w.props.saturation, -2.0e4),
    ]
    bad = Dict(
        add!(w.props.density, -5.0) => "strictly positive",
        add!(w.props.density, 0.0) => "strictly positive",
        add!(w.props.viscosity, -1.0e-3) => "strictly positive",
        add!(w.props.ratio, 0.95) => "bounded below by 1.0",
        add!(w.props.permittivity, 0.5) => "bounded below by 1.0",
        add!(w.props.fraction, 1.2) => "fraction in [0, 1]",
        add!(w.props.fraction, -0.1) => "fraction in [0, 1]",
        add!(w.props.density, NaN) => "not a finite number",
        add!(w.props.density, Inf) => "not a finite number",
        Synthetic.add!(
            w,
            e,
            w.props.density,
            997.0;
            temperature = -3.0,
            pressure = 101.325,
            x = (1.0, NaN, NaN),
        ) => "temperature",
        Synthetic.add!(
            w,
            e,
            w.props.density,
            997.0;
            temperature = 300.0,
            pressure = -1.0,
            x = (1.0, NaN, NaN),
        ) => "pressure",
        Synthetic.add!(
            w,
            e,
            w.props.density,
            997.0;
            temperature = 300.0,
            pressure = 101.325,
            x = (1.3, NaN, NaN),
        ) => "outside [0, 1]",
        Synthetic.add!(
            w,
            eb,
            w.props.density,
            900.0;
            temperature = 300.0,
            pressure = 101.325,
            x = (0.7, 0.6, NaN),
        ) => "add up to",
    )
    res = T.find_outliers(T.DataView(w.ds); trend = false, joint = false)
    @test Set(res.outliers.rows) == Set(keys(bad))
    @test Set(res.kept.rows) == Set(good)
    @test isempty(res.disputed)
    @test res.counts.physical == length(bad)
    why = T.reasons(res)
    @test all(why.code .== :physical_rule) && all(why.axis .== :none)
    @test all(isnan, why.z) && all(why.rank .== 0)
    for (row, fragment) in bad
        k = findfirst(==(row), why.measurement)
        @test occursin(fragment, why.detail[k])
    end
    # The rules can be switched off.
    off = T.find_outliers(T.DataView(w.ds); physical = false, trend = false, joint = false)
    @test length(off.kept) == length(good) + length(bad)
end

@testitem "known limits add ceilings, and rejected points leave the trend analysis" setup =
    [Synthetic] tags = [:unit] begin
    T = ThermophysicalDB
    g = Synthetic.density_grid()
    view = T.DataView(g.ds)
    limits = Dict("mass density" => (0, 1100))
    # 1100 kg/m³ is above every value of the grid except the ones forced above it.
    g.ds.measurements.value[g.rows[5]] = 1500.0
    res = T.find_outliers(view; known_limits = limits)
    why = T.reasons(res)
    k = findfirst(==(g.rows[5]), why.measurement)
    @test why.code[k] == :physical_rule
    @test occursin("limit supplied by the user", why.detail[k])
    # The point does not drag its neighbours into the trend analysis.
    @test length(res.outliers) == 1 && isempty(res.disputed)
    # Without the limit the same point is found by the trend instead.
    free = T.find_outliers(view)
    @test g.rows[5] in free.outliers.rows
    @test T.reasons(free).code[findfirst(==(g.rows[5]), T.reasons(free).measurement)] !=
          :physical_rule
    # One-sided limits.
    low = T.find_outliers(
        view;
        known_limits = Dict("Mass density" => (1050, nothing)),
        trend = false,
        joint = false,
    )
    @test length(low.outliers) == length(view) - count(>(1050), g.ds.measurements.value)
end

@testitem "every classical consistency rule accepts a sane value and rejects an impossible one" tags =
    [:unit] begin
    T = ThermophysicalDB
    bounds(label) = T.property_bounds(label, nothing)
    violates(label, v) = begin
        b = bounds(label)
        v < b.lo || v > b.hi || (b.strict && v <= b.lo)
    end
    # (label as written in ThermoML, sane value, impossible value)
    cases = [
        ("Kinematic viscosity, m2/s", 1.0e-6, -1.0e-6),
        ("Self diffusion coefficient, m2/s", 2.3e-9, -1.0e-9),
        ("Binary diffusion coefficient, m2/s", 1.0e-5, 0.0),
        ("Interfacial tension, N/m", 0.05, -0.01),
        ("Critical temperature, K", 647.1, -5.0),
        ("Critical pressure, kPa", 22064.0, 0.0),
        ("Critical density, kg/m3", 322.0, -1.0),
        ("Critical molar volume, m3/mol", 5.6e-5, -1.0e-5),
        ("Critical specific volume, m3/kg", 3.1e-3, 0.0),
        ("Critical compressibility factor", 0.23, -0.2),
        ("Triple point temperature, K", 273.16, 0.0),
        ("Triple point pressure, kPa", 0.6117, -0.1),
        ("Normal boiling temperature, K", 373.15, -1.0),
        ("Normal melting temperature, K", 273.15, 0.0),
        ("Boiling temperature at pressure P, K", 400.0, -400.0),
        ("Eutectic temperature, K", 250.0, 0.0),
        ("Activity coefficient", 1.2, -0.3),
        ("Fugacity, kPa", 90.0, -1.0),
        ("Fugacity coefficient", 0.97, 0.0),
        ("Henry's Law constant (mole fraction scale), kPa", 7.0e6, -1.0),
        ("Henry's Law constant (molality scale), kPa*kg/mol", 3000.0, -1.0),
        ("Henry's Law constant (amount concentration scale), kPa*dm3/mol", 3000.0, 0.0),
        ("Equilibrium constant in terms of mole fraction", 12.0, -1.0),
        ("Equilibrium constant in terms of molality, (mol/kg)^n", 12.0, 0.0),
        (
            "Equilibrium constant in terms of amount concentration (molarity), (mol/dm3)^n",
            4.0,
            -1.0,
        ),
        ("Equilibrium constant in terms of partial pressure, kPa^n", 4.0, -1.0),
        ("Electrical conductivity, S/m", 0.0, -1.0e-3),
        ("Molar conductivity, S*m2/mol", 0.0126, -0.01),
        ("Ionic strength (molality basis), mol/kg", 0.1, -0.1),
        ("Ionic strength (amount concentration basis), mol/dm3", 0.1, -0.1),
        ("Molality, mol/kg", 1.0, -1.0),
        ("Molar enthalpy of vaporization or sublimation, kJ/mol", 40.7, -1.0),
        ("Molar entropy of vaporization or sublimation, J/K/mol", 109.0, -1.0),
        ("Molar entropy, J/K/mol", 69.9, -0.5),
        ("Refractive index (Na D-line)", 1.333, 0.99),
        ("Refractive index (other wavelength)", 1.34, 0.5),
        ("Mole fraction in LLG critical state", 0.4, 1.3),
        ("Mass fraction in LLG critical state", 0.4, -0.2),
        ("Eutectic composition: mole fraction", 0.4, 1.2),
        ("Eutectic composition: mass fraction", 0.4, -0.1),
        ("Eutectic composition: volume fraction", 0.4, 1.01),
        ("Speed of sound, m/s", 1480.0, 0.0),
        ("Thermal conductivity, W/m/K", 0.6, -0.6),
    ]
    for (label, sane, impossible) in cases
        @test !violates(label, sane)
        @test violates(label, impossible)
        @test bounds(label) !== T.NO_BOUNDS
    end
    # A value of exactly zero is allowed where the quantity may vanish.
    @test !violates("Electrical conductivity, S/m", 0.0)
    @test !violates("Molar enthalpy of vaporization or sublimation, kJ/mol", 0.0)
    # Quantities that can have either sign, or that depend on the reference state, have no rule.
    for label in (
        "Molar enthalpy, kJ/mol",
        "Molar enthalpy of solution, kJ/mol",
        "Molar enthalpy of transition or fusion, kJ/mol",
        "Osmotic coefficient",
        "Heat capacity change at transition, J/K/mol",
        "Thermal pressure coefficient, kPa/K",
        "Molar heat capacity at saturation pressure, J/K/mol",
        "Molar entropy of reaction, J/K/mol",
    )
        @test bounds(label) === T.NO_BOUNDS
    end
end
