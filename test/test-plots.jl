@testitem "labels: symbols, units and the way they are put together" tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB,
        axis_label,
        register_symbol!,
        tex_unit,
        property_symbol,
        property_label

    @test tex_unit("kg/m3") == raw"\mathrm{kg}\,\mathrm{m}^{-3}"
    @test tex_unit("J/K/mol") == raw"\mathrm{J}\,\mathrm{K}^{-1}\,\mathrm{mol}^{-1}"
    @test tex_unit("kPa") == raw"\mathrm{kPa}"
    @test tex_unit("degC") == raw"{}^{\circ}\mathrm{C}"
    @test tex_unit("") == ""
    @test tex_unit("m/s") == raw"\mathrm{m}\,\mathrm{s}^{-1}"
    # What is not understood is written as it is, in roman type.
    @test tex_unit("(a+b)") == raw"\mathrm{(a+b)}"

    @test property_symbol("Mass density") == "\\rho"
    @test property_symbol("Speed of sound") == "w"
    @test property_symbol("not a property") === nothing
    @test axis_label("\\rho", "kg/m3") == raw"\rho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test axis_label("\\rho", "kg/m3"; format = :round) ==
          raw"\rho\;(\mathrm{kg}\,\mathrm{m}^{-3})"
    @test axis_label("\\rho", "kg/m3"; format = :slash) ==
          raw"\rho\;/\;\mathrm{kg}\,\mathrm{m}^{-3}"
    @test axis_label("\\rho", "kg/m3"; format = (s, u) -> "$s in $u") ==
          raw"\rho in \mathrm{kg}\,\mathrm{m}^{-3}"
    @test axis_label("x", "") == "x"
    @test_throws ArgumentError axis_label("x", "K"; format = :nope)

    # A property without a symbol uses its name; a registered symbol replaces the one of the schema.
    @test property_label("Some new property", "K") ==
          raw"\mathrm{Some\ new\ property}\;[\mathrm{K}]"
    register_symbol!("Mass density", "\\varrho")
    @test property_label("Mass density", "kg/m3") ==
          raw"\varrho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    delete!(ThermophysicalDB.USER_SYMBOLS, "Mass density")
    @test property_symbol("Mass density") == "\\rho"
end

@testitem "deviations: kinds, units and the absolute value" tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, DeviationSpec, deviation, deviation_label

    e = [100.0, 200.0, -50.0]
    c = [99.0, 210.0, -55.0]
    # Relative, in percent by default: (e - c) / e.
    @test deviation(e, c) ≈ [1.0, -5.0, -10.0]
    @test deviation(e, c; unit = :fraction) ≈ [0.01, -0.05, -0.1]
    @test deviation(e, c; unit = :ppm) ≈ [1.0e4, -5.0e4, -1.0e5]
    @test deviation(e, c; absolute_value = true) ≈ [1.0, 5.0, 10.0]
    @test deviation(e, c; kind = :absolute) ≈ [1.0, -10.0, 5.0]
    @test deviation(e, c; kind = :absolute, absolute_value = true) ≈ [1.0, 10.0, 5.0]
    @test deviation(e, c; kind = :log, unit = :fraction)[1] ≈ log(100 / 99)
    # The log of a ratio that is not positive is not defined.
    @test isnan(deviation([1.0], [-1.0]; kind = :log)[1])
    # SMAPE is the usual one, without sign and saturating at 2 when the signs differ.
    @test deviation([1.0, 1.0], [3.0, -1.0]; kind = :smape, unit = :fraction) ≈ [1.0, 2.0]
    @test deviation([0.0], [0.0]; kind = :smape)[1] == 0.0
    # The smooth errors follow the relative error for large ones and flatten the small ones.
    big = deviation([1.0], [0.5]; kind = :smae, unit = :fraction)[1]
    @test big ≈ 0.5 atol = 1.0e-6
    small = deviation([1.0], [0.9999]; kind = :smae, unit = :fraction)[1]
    @test abs(small) < 1.0e-4 * 0.02
    @test sign(deviation([1.0], [2.0]; kind = :srl)[1]) == -1
    @test deviation([1.0], [1.0]; kind = :srl)[1] == 0.0
    # Without an experimental value the relative deviation is not defined.
    @test isnan(deviation([0.0], [1.0])[1])

    @test_throws ArgumentError DeviationSpec(:nope)
    @test_throws ArgumentError DeviationSpec(:relative; unit = :nope)
    @test_throws ArgumentError DeviationSpec(:smae; alpha = 0)
    @test_throws DimensionMismatch deviation([1.0], [1.0, 2.0])

    @test deviation_label(DeviationSpec(), "\\rho", "kg/m3") == raw"\delta_{\rho}\;[\%]"
    @test deviation_label(DeviationSpec(:absolute), "\\rho", "kg/m3") ==
          raw"\Delta_{\rho}\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test deviation_label(DeviationSpec(; absolute_value = true), "\\rho", "kg/m3") ==
          raw"\left|\delta_{\rho}\right|\;[\%]"
    @test deviation_label(DeviationSpec(; unit = :fraction), "\\rho", "kg/m3") ==
          raw"\delta_{\rho}\;[-]"
end

@testitem "quartiles and the density of a violin" tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB, quartiles, density_profile, silverman_bandwidth

    @test quartiles(1.0:5.0) == (1.0, 2.0, 3.0, 4.0, 5.0)
    @test quartiles([1.0, NaN, 3.0]) == (1.0, 1.5, 2.0, 2.5, 3.0)
    @test all(isnan, quartiles(Float64[]))
    @test quartiles([7.0]) == (7.0, 7.0, 7.0, 7.0, 7.0)

    v = [-1.0, -0.5, 0.0, 0.1, 0.4, 0.5, 1.0, 1.1]
    p = density_profile(v)
    @test length(p.y) == length(p.density) == 64
    @test maximum(p.density) == 1.0 && minimum(p.density) >= 0
    @test issorted(p.y) && first(p.y) < minimum(v) && last(p.y) > maximum(v)
    # The density is highest where the values are.
    @test -1.0 < p.y[argmax(p.density)] < 1.2
    @test density_profile([2.0]) == (y = [2.0], density = [1.0])
    @test isempty(density_profile(Float64[]).y)
    @test silverman_bandwidth([1.0, 1.0, 1.0]) == 1.0
    @test_throws ArgumentError density_profile(v; bandwidth = 0)
end

@testitem "style and the defaults of the figures" tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB, plot_style, plot_defaults, reset_plot_defaults!, PlotStyle

    s = plot_style()
    @test s isa PlotStyle && s.colormap === :managua_r && s.diverging === :vik
    @test length(s.palette) >= 8 && length(s.markers) == 10
    n = plot_style(:neon)
    @test n.background == "none" && n.colormap isa Vector{String} && length(n.palette) == 8
    @test plot_style(:default; markersize = 12.0).markersize == 12.0
    @test_throws ArgumentError plot_style(:nope)
    @test_throws ArgumentError plot_style(:default; nope = 1)

    d = plot_defaults()
    @test d.deviation === :relative &&
          d.deviation_unit === :percent &&
          d.unitformat === :square
    plot_defaults(deviation = :smape, uncertainty = :bars)
    @test plot_defaults().deviation === :smape && plot_defaults().uncertainty === :bars
    @test_throws ArgumentError plot_defaults(deviation = :nope)
    @test_throws ArgumentError plot_defaults(nope = 1)
    empty!(ThermophysicalDB.PLOT_DEFAULTS)
    @test plot_defaults().deviation === :relative
end

# A table of density measured by three references at several temperatures and pressures.
@testitem "figures are described without a plotting package" tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB,
        PointTable,
        PlotData,
        plotdata,
        FigureSpec,
        plot_comparison,
        plot_isotherms,
        plot_isobars,
        plot_parity,
        plot_residuals,
        plot_xpt,
        plot_facets,
        plot_by_reference,
        model_values,
        point_groups

    n = 60
    temperature = repeat([290.0, 300.0, 310.0, 320.0], inner = 15)
    pressure = repeat([100.0, 5000.0, 10000.0], 20)
    doi = repeat(["10.1/a", "10.1/b", "10.1/c", "10.1/a", "10.1/b"], 12)
    truth(p, T) = 1000 - 0.5 * (T - 300) + 1.0e-5 * p
    value = [truth(pressure[i] * 1.0e3, temperature[i]) * (1 + 0.002 * sin(i)) for i = 1:n]
    cols = (;
        source = fill("x", n),
        doi,
        year = Int16[
            doi[i] == "10.1/a" ? 1990 : doi[i] == "10.1/b" ? 2005 : 2020 for i = 1:n
        ],
        components = fill("water", n),
        xkind = fill("", n),
        property = fill("Mass density", n),
        method = fill("", n),
        phase = fill("Liquid", n),
        temperature,
        pressure,
        x1 = fill(NaN, n),
        value,
        unit = fill("kg/m3", n),
        unc_k2 = fill(0.5, n),
    )
    t = PointTable(cols, "K", "kPa")
    d = plotdata(t)
    @test d isa PlotData && length(d) == n
    @test plotdata(d) === d

    groups = point_groups(d, :reference)
    @test [g.label for g in groups] == ["10.1/a", "10.1/b", "10.1/c"]
    @test sum(length(g.rows) for g in groups) == n
    @test length(point_groups(d, nothing)) == 1
    @test [g.label for g in point_groups(d, :year_group)] == ["1990s", "2000s", "2020s"]
    @test length(point_groups(d, :reference; maxgroups = 2)) == 2
    @test point_groups(d, :reference; maxgroups = 2)[end].label == "others"
    @test_throws ArgumentError point_groups(d, :nope)

    # A model in SI, called once for the same conditions.
    calls = Ref(0)
    model(p, T) = (calls[] += 1; truth(p, T))
    v1 = model_values(d, model)
    v2 = model_values(d, model)
    @test v1 === v2 && calls[] == n
    @test v1[1] ≈ truth(100.0e3, 290.0)
    @test model_values(d, T -> 2T; args = (:temperature,))[1] == 580.0

    fig = plot_comparison(d; model = truth, spec = true)
    @test fig isa FigureSpec && length(fig.panels) == 2 && fig.sharex
    top, bottom = fig.panels
    @test top.ylabel == raw"\rho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test bottom.ylabel == raw"\delta_{\rho}\;[\%]"
    @test bottom.xlabel == raw"T\;[\mathrm{K}]"
    @test all(isempty, (top.tag, bottom.tag))
    @test count(l -> l.kind === :scatter, top.layers) == 3
    @test count(l -> l.kind === :lines, top.layers) == 1
    # The deviations are in percent; the uncertainty bars of the points are in the deviation panel only.
    dev = reduce(vcat, [l.y for l in bottom.layers if l.kind === :scatter])
    @test maximum(abs, dev) < 0.3
    @test any(l -> l.kind === :errorbars, bottom.layers)
    @test !any(l -> l.kind === :errorbars, top.layers)
    # Markers are filled and different for each reference.
    @test length(unique(l.marker for l in top.layers if l.kind === :scatter)) == 3
    # The tags and the other deviations.
    @test [
        p.tag for
        p in plot_comparison(d; model = truth, spec = true, panel_labels = true).panels
    ] == ["(a)", "(b)"]
    fig2 = plot_comparison(
        d;
        model = truth,
        spec = true,
        deviation = :absolute,
        uncertainty = :none,
    )
    @test fig2.panels[2].ylabel == raw"\Delta_{\rho}\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test !any(l -> l.kind in (:errorbars, :band), fig2.panels[2].layers)
    fig3 = plot_comparison(d; model = truth, spec = true, uncertainty = :band)
    @test any(l -> l.kind === :band, fig3.panels[2].layers)
    # Without a model there is nothing to compare with.
    @test_throws ArgumentError plot_comparison(d; spec = true)
    # With calculated values given to the data.
    dc = plotdata(t; calc = value .* 1.01)
    @test plot_comparison(dc; spec = true) isa FigureSpec

    iso = plot_isotherms(d; model = truth, spec = true)
    panel = only(iso.panels)
    @test panel.colorbar.label == raw"T\;[\mathrm{K}]"
    @test panel.colorbar.limits == (290.0, 320.0)
    @test panel.xlabel == raw"p\;[\mathrm{kPa}]"
    @test count(l -> l.kind === :lines, panel.layers) == 4
    @test all(l -> l.color isa Vector{Float64}, panel.layers)
    bar = only(plot_isobars(d; spec = true).panels)
    @test bar.xlabel == raw"T\;[\mathrm{K}]" && bar.colorbar.limits == (100.0, 10000.0)

    par = only(plot_parity(d; model = truth, spec = true).panels)
    @test par.aspect_equal
    @test par.xlabel == raw"\rho_{\mathrm{calc}}\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test count(l -> l.linestyle === :dash, par.layers) == 6      # 1, 5 and 10 %, both sides
    @test count(
        l -> l.linestyle === :dash,
        only(plot_parity(d; model = truth, bands = [2], spec = true).panels).layers,
    ) == 2

    # Three points of each reference: too few for a violin.
    function subset_few(d)
        mask = falses(length(d))
        for g in point_groups(d, :reference)
            mask[g.rows[1:3]] .= true
        end
        return ThermophysicalDB.subset_data(d, mask)
    end
    res = only(plot_residuals(d; model = truth, spec = true).panels)
    @test res.xticks[2] == ["10.1/a", "10.1/b", "10.1/c"]
    @test count(l -> l.kind === :polygon, res.layers) == 3        # 20 points each: violins
    few = only(plot_residuals(subset_few(d); model = truth, spec = true).panels)
    @test count(l -> l.kind === :polygon, few.layers) == 3        # boxes in place of violins
    both = only(plot_residuals(d; model = truth, kind = :both, spec = true).panels)
    @test count(l -> l.kind === :polygon, both.layers) == 6
    box = only(plot_residuals(d; model = truth, kind = :box, spec = true).panels)
    @test count(l -> l.kind === :polygon, box.layers) == 3
    @test_throws ArgumentError plot_residuals(d; model = truth, kind = :nope, spec = true)

    xpt = only(plot_xpt(d; spec = true).panels)
    @test xpt.xlabel == raw"T\;[\mathrm{K}]" && xpt.ylabel == raw"p\;[\mathrm{kPa}]"
    @test xpt.colorbar.label == raw"\rho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    star = only(plot_xpt(d; highlight = "10.1/c", spec = true).panels)
    @test any(l -> l.marker === :star5 && l.label == "This work", star.layers)
    cnt = only(plot_xpt(d; color = :count, spec = true).panels)
    @test only(cnt.layers).kind === :heatmap && sum(filter(!isnan, only(cnt.layers).z)) == n

    fac = plot_by_reference(d; spec = true)
    @test length(fac.panels) == 3 && fac.ncols == 3 && fac.nrows == 1
    @test [p.tag for p in fac.panels] == ["(a)", "(b)", "(c)"]
    @test [p.title for p in fac.panels] == ["10.1/a", "10.1/b", "10.1/c"]
    colored = plot_facets(d; by = :reference, color = :pressure, spec = true)
    @test colored.colorbar.limits == (100.0, 10000.0)
    # The backend is needed to draw (the test runner may have loaded the extensions already).
    saved = copy(ThermophysicalDB.BACKENDS)
    empty!(ThermophysicalDB.BACKENDS)
    try
        @test_throws ArgumentError plot_comparison(d; model = truth)
        @test_throws ArgumentError plot_comparison(d; model = truth, backend = :makie)
        ThermophysicalDB.register_backend!(:makie, spec -> :makie_figure)
        @test plot_comparison(d; model = truth) === :makie_figure
        ThermophysicalDB.register_backend!(:plots, spec -> :plots_figure)
        # With two backends loaded one is chosen.
        @test_throws ArgumentError plot_comparison(d; model = truth)
        @test plot_comparison(d; model = truth, backend = :plots) === :plots_figure
        @test_throws ArgumentError ThermophysicalDB.register_backend!(:nope, identity)
    finally
        empty!(ThermophysicalDB.BACKENDS)
        merge!(ThermophysicalDB.BACKENDS, saved)
    end
    # A mistake in the options is an error, not a silent default.
    @test_throws ArgumentError plot_isotherms(d; unitformat = :nope, spec = true)
    @test_throws ArgumentError plot_isotherms(d; uncertainty = :nope, spec = true)
    @test_throws ArgumentError plot_xpt(d; xunit = "K", spec = true)
end

@testitem "several properties make facets with their own units" tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB, PointTable, plotdata, plot_facets, plot_comparison

    n = 12
    cols = (;
        source = fill("x", n),
        doi = fill("10.1/a", n),
        year = fill(Int16(2000), n),
        components = fill("water", n),
        xkind = fill("", n),
        property = vcat(fill("Mass density", 6), fill("Speed of sound", 6)),
        method = fill("", n),
        phase = fill("", n),
        temperature = repeat([290.0, 300.0, 310.0], 4),
        pressure = fill(101.325, n),
        x1 = fill(NaN, n),
        value = collect(1.0:n),
        unit = vcat(fill("kg/m3", 6), fill("m/s", 6)),
        unc_k2 = fill(NaN, n),
    )
    d = plotdata(PointTable(cols, "K", "kPa"))
    fig = plot_facets(d; spec = true)
    @test length(fig.panels) == 2
    @test fig.panels[1].ylabel == raw"\rho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    @test fig.panels[2].ylabel == raw"w\;[\mathrm{m}\,\mathrm{s}^{-1}]"
    @test [p.tag for p in fig.panels] == ["(a)", "(b)"]
    @test all(isempty(p.title) for p in fig.panels)
    # One property at a time for the figures that need it.
    @test_throws ArgumentError plot_comparison(d; model = (p, T) -> 1.0, spec = true)
    @test_throws ArgumentError plot_facets(d; maxpanels = 1, spec = true)
end

@testitem "figures take a selection, with the units of the axes" setup = [FilterData] tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, plotdata, plot_comparison, plot_xpt, DataView

    view = DataView(FilterData.build())
    d = plotdata(
        view;
        property = "Mass density",
        component = "water",
        pressure_unit = "MPa",
    )
    @test length(d) == 4
    @test ThermophysicalDB.pressure_unit(d) == "MPa"
    @test ThermophysicalDB.column(d, :pressure)[1] ≈ 0.101325
    fig = plot_comparison(d; model = (p, T) -> 997.0, spec = true)
    @test fig.panels[1].layers[1].kind === :lines
    @test all(==(997.0), fig.panels[1].layers[1].y)
    # The axes of the figure ask for the units of the selection.
    fig = plot_xpt(
        view;
        property = "Mass density",
        component = "water",
        xunit = "degC",
        yunit = "bar",
        spec = true,
    )
    p = only(fig.panels)
    @test p.xlabel == raw"T\;[{}^{\circ}\mathrm{C}]"
    @test p.ylabel == raw"p\;[\mathrm{bar}]"
    @test only(l for l in p.layers).x[1] ≈ 295.0 - 273.15
    # A model sees SI whatever the units of the table.
    seen = Float64[]
    plot_comparison(
        view;
        property = "Mass density",
        component = "water",
        temperature_unit = "degC",
        pressure_unit = "MPa",
        model = (p, T) -> (push!(seen, p, T); 997.0),
        spec = true,
    )
    @test seen[1] ≈ 101325.0 && seen[2] ≈ 295.0
    # Units belong to the data when it is already prepared.
    @test_throws ArgumentError plot_xpt(d; xunit = "degC", spec = true)
end

@testmodule PlotSamples begin
    using ThermophysicalDB: PointTable, plotdata

    truth(p, T) = 1000 - 0.5 * (T - 300) + 1.0e-5 * p

    function data(; n = 60)
        temperature = repeat([290.0, 300.0, 310.0, 320.0], inner = cld(n, 4))[1:n]
        pressure = repeat([100.0, 5000.0, 10000.0], cld(n, 3))[1:n]
        doi = repeat(["10.1/a", "10.1/b", "10.1/c"], cld(n, 3))[1:n]
        value =
            [truth(pressure[i] * 1.0e3, temperature[i]) * (1 + 0.002 * sin(i)) for i = 1:n]
        cols = (;
            source = fill("x", n),
            doi,
            year = Int16[
                doi[i] == "10.1/a" ? 1990 : doi[i] == "10.1/b" ? 2005 : 2020 for i = 1:n
            ],
            components = fill("water", n),
            xkind = fill("", n),
            property = fill("Mass density", n),
            method = fill("", n),
            phase = fill("Liquid", n),
            temperature,
            pressure,
            x1 = fill(NaN, n),
            value,
            unit = fill("kg/m3", n),
            unc_k2 = fill(0.5, n),
        )
        return plotdata(PointTable(cols, "K", "kPa"))
    end
end

@testitem "the Makie extension draws every figure" setup = [PlotSamples] tags = [:unit] begin
    using ThermophysicalDB
    using CairoMakie

    d = PlotSamples.data()
    truth = PlotSamples.truth
    @test haskey(ThermophysicalDB.BACKENDS, :makie)
    figures = [
        plot_comparison(d; model = truth),
        plot_comparison(d; model = truth, deviation = :smape, style = :neon),
        plot_isotherms(d; model = truth),
        plot_isobars(d),
        plot_parity(d; model = truth, bands = [1, 2]),
        plot_residuals(d; model = truth),
        plot_residuals(d; model = truth, kind = :both),
        plot_xpt(d; highlight = "10.1/c"),
        plot_xpt(d; color = :count),
        plot_facets(d; by = :reference, color = :pressure),
        plot_by_reference(d),
        plot_deviation_map(d; model = truth),
        plot_years(d),
    ]
    @test all(f -> f isa CairoMakie.Makie.Figure, figures)
    # They are drawn: the figure can be written as a vector file.
    mktempdir() do dir
        path = joinpath(dir, "figure.svg")
        save(path, first(figures))
        @test filesize(path) > 1000
    end
    # The labels are LaTeX.
    axes = [c for c in first(figures).content if c isa CairoMakie.Makie.Axis]
    @test length(axes) == 2
    @test axes[1].ylabel[] isa CairoMakie.Makie.LaTeXStrings.LaTeXString

    # A position of the user's layout.
    fig = Figure()
    ax = plot_parity!(fig[1, 1], d; model = truth)
    ax2 = plot_xpt!(fig[1, 2], d)
    @test ax isa Vector && ax2 isa Vector && length(ax) == 1

    # A colour map by name, reversed with `_r`, and one given as colours.
    @test plot_xpt(d; colormap = :vik) isa CairoMakie.Makie.Figure
    @test plot_xpt(
        d;
        style = ThermophysicalDB.plot_style(:default; colormap = ["#000000", "#ffffff"]),
    ) isa CairoMakie.Makie.Figure
end

@testitem "the Plots extension draws every figure" setup = [PlotSamples] tags = [:unit] begin
    using ThermophysicalDB
    import Plots

    d = PlotSamples.data()
    truth = PlotSamples.truth
    @test haskey(ThermophysicalDB.BACKENDS, :plots)
    ThermophysicalDB.plot_defaults(backend = :plots)
    try
        figures = [
            plot_comparison(d; model = truth),
            plot_isotherms(d; model = truth),
            plot_parity(d; model = truth),
            plot_residuals(d; model = truth),
            plot_xpt(d; highlight = "10.1/c"),
            plot_xpt(d; color = :count),
            plot_by_reference(d; color = :pressure),
            plot_deviation_map(d; model = truth),
            plot_years(d),
        ]
        @test all(f -> f isa Plots.Plot, figures)
        mktempdir() do dir
            path = joinpath(dir, "figure.svg")
            Plots.savefig(first(figures), path)
            @test filesize(path) > 1000
        end
        # The recipe: `plot(data; kind, options)`.
        p = Plots.plot(d; kind = :parity, options = (model = truth,))
        @test p isa Plots.Plot
        @test_throws ArgumentError Plots.plot(d; kind = :nope)
    finally
        empty!(ThermophysicalDB.PLOT_DEFAULTS)
    end
end

# The three ways in which the archive writes an equilibrium point.
@testmodule VleSamples begin
    using ThermophysicalDB: PointTable, plotdata

    function rows()
        cols = Dict(
            k => Any[] for k in (
                :doi,
                :year,
                :components,
                :property,
                :phase,
                :temperature,
                :pressure,
                :x1,
                :value,
                :unit,
            )
        )
        function add(doi, property, phase, T, p, x1, value, unit)
            push!(cols[:doi], doi)
            push!(cols[:year], Int16(2000))
            push!(cols[:components], "a + b")
            push!(cols[:property], property)
            push!(cols[:phase], phase)
            push!(cols[:temperature], T)
            push!(cols[:pressure], p)
            push!(cols[:x1], x1)
            push!(cols[:value], value)
            push!(cols[:unit], unit)
        end
        # Bubble pressures at two temperatures with the vapour composition (x1 and T match).
        for T in (300.0, 320.0), x in (0.2, 0.5, 0.8)
            add(
                "10.1/p",
                "Vapor or sublimation pressure",
                "Liquid",
                T,
                NaN,
                x,
                100 + T / 10 + 50x,
                "kPa",
            )
            add("10.1/p", "Mole fraction", "Gas", T, NaN, x, min(0.99, x + 0.15), "")
        end
        # Boiling temperatures at 101.325 kPa (x1 and p match), temperature in kelvin.
        for x in (0.1, 0.4, 0.7)
            add(
                "10.1/t",
                "Boiling temperature at pressure P",
                "Liquid",
                NaN,
                101.325,
                x,
                380 - 30x,
                "K",
            )
            add(
                "10.1/t",
                "Mole fraction",
                "Liquid",
                NaN,
                101.325,
                x,
                min(0.99, x + 0.1),
                "",
            )
        end
        # Compositions only: the liquid and the gas at a temperature and a pressure.
        add("10.1/c", "Mole fraction", "Liquid", 298.15, 500.0, NaN, 0.3, "")
        add("10.1/c", "Mole fraction", "Gas", 298.15, 500.0, NaN, 0.9, "")
        add("10.1/c", "Mole fraction", "Liquid", 298.15, 900.0, NaN, 0.5, "")
        n = length(cols[:doi])
        columns = (;
            source = fill("x", n),
            doi = String.(cols[:doi]),
            year = Int16.(cols[:year]),
            components = String.(cols[:components]),
            xkind = fill("", n),
            property = String.(cols[:property]),
            method = fill("", n),
            phase = String.(cols[:phase]),
            temperature = Float64.(cols[:temperature]),
            pressure = Float64.(cols[:pressure]),
            x1 = Float64.(cols[:x1]),
            value = Float64.(cols[:value]),
            unit = String.(cols[:unit]),
            unc_k2 = fill(NaN, n),
        )
        return columns
    end
    data(; temperature_unit = "K", pressure_unit = "kPa") =
        plotdata(PointTable(rows(), temperature_unit, pressure_unit))
end

@testitem "equilibrium points are put together from the rows of the archive" setup =
    [VleSamples] tags = [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB, equilibrium, plot_pxy, plot_txy, plot_xy, FigureSpec

    d = VleSamples.data()
    e = equilibrium(d)
    # 6 bubble pressures + 3 boiling temperatures + 2 composition points (one with only the liquid).
    @test length(e) == 6 + 3 + 2
    byref(doi) = findall(==(doi), e.doi)
    p = byref("10.1/p")
    @test all(isfinite, e.y[p]) && all(isfinite, e.pressure[p])
    @test sort(e.pressure[p]) ≈
          sort([100 + T / 10 + 50x for T in (300.0, 320.0) for x in (0.2, 0.5, 0.8)])
    @test e.y[p[1]] ≈ min(0.99, e.x[p[1]] + 0.15)
    t = byref("10.1/t")
    @test all(==(101.325), e.pressure[t]) &&
          all(isfinite, e.temperature[t]) &&
          all(isfinite, e.y[t])
    c = byref("10.1/c")
    @test length(c) == 2
    paired = c[findfirst(i -> isfinite(e.x[i]) && isfinite(e.y[i]), c)]
    @test e.x[paired] == 0.3 && e.y[paired] == 0.9 && e.pressure[paired] == 500.0
    half = c[findfirst(i -> isnan(e.y[i]), c)]
    @test e.x[half] == 0.5 && e.pressure[half] == 900.0

    # A boiling temperature is converted to the temperature unit of the table.
    ec = equilibrium(VleSamples.data(temperature_unit = "degC"))
    tt = findall(==("10.1/t"), ec.doi)
    @test sort(ec.temperature[tt]) ≈ sort([380 - 30x - 273.15 for x in (0.1, 0.4, 0.7)])
    @test ThermophysicalDB.convert_pressure(1.0, "MPa", "kPa") == 1000.0
    @test ThermophysicalDB.convert_temperature(300.0, "K", "degC") ≈ 26.85

    # P-x-y: a panel for each isotherm (300 and 320 K and the 298.15 K one).
    fig = plot_pxy(d; spec = true)
    @test fig isa FigureSpec && length(fig.panels) == 3
    @test all(
        p -> p.xlabel == raw"x_1,\,y_1" && p.ylabel == raw"p\;[\mathrm{kPa}]",
        fig.panels,
    )
    @test [p.tag for p in fig.panels] == ["(a)", "(b)", "(c)"]
    @test any(l -> l.label == "bubble (x)", fig.panels[1].layers) &&
          any(l -> l.label == "dew (y)", fig.panels[1].layers)
    @test any(!l.filled && isempty(l.label) && !isempty(l.x) for l in fig.panels[1].layers)
    one = plot_pxy(d; at = 300.0, spec = true)
    @test length(one.panels) == 1 && one.panels[1].title == "T = 300 K"
    @test_throws ArgumentError plot_pxy(d; at = 123.0, spec = true)
    # More sections than `maxpanels`: the richest are kept (with `at`, it is an error).
    few = @test_logs (:info,) match_mode = :any plot_pxy(d; maxpanels = 1, spec = true)
    @test length(few.panels) == 1
    @test_throws ArgumentError plot_pxy(d; at = [300.0, 320.0], maxpanels = 1, spec = true)
    # A model: (p, y) at the temperature and the composition; its lines are in the figure.
    model(T, x) = (1.0e3 * (100 + T / 10 + 50x), min(0.99, x + 0.15))
    with_model = plot_pxy(d; at = 300.0, model, spec = true)
    @test count(l -> l.kind === :lines, with_model.panels[1].layers) == 2

    # T-x-y: the isobar of 101.325 kPa, from the boiling temperatures.
    tfig = plot_txy(d; at = 101.325, spec = true)
    @test length(tfig.panels) == 1 && tfig.panels[1].ylabel == raw"T\;[\mathrm{K}]"
    @test tfig.panels[1].title == "p = 101.33 kPa" ||
          startswith(tfig.panels[1].title, "p = 101.3")
    tmodel(p, x) = (380 - 30x, min(0.99, x + 0.1))
    @test count(
        l -> l.kind === :lines,
        plot_txy(d; at = 101.325, model = tmodel, spec = true).panels[1].layers,
    ) == 2

    # x-y: the points that have both compositions, coloured by the temperature.
    xy = only(plot_xy(d; spec = true).panels)
    @test xy.aspect_equal && xy.xlabel == "x_1" && xy.colorbar !== nothing
    @test sum(length(l.x) for l in xy.layers if l.kind === :scatter) == 6 + 3 + 1
    # Data without the properties are refused.
    density = ThermophysicalDB.PointTable((;
        source = ["x"],
        doi = ["d"],
        year = Int16[1],
        components = ["a"],
        xkind = [""],
        property = ["Mass density"],
        method = [""],
        phase = [""],
        temperature = [300.0],
        pressure = [100.0],
        x1 = [NaN],
        value = [1.0],
        unit = ["kg/m3"],
        unc_k2 = [NaN],
    ),)
    @test_throws ArgumentError plot_xy(ThermophysicalDB.plotdata(density); spec = true)
end

@testitem "the saturation figure pairs the critical points of each reference" tags =
    [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, PointTable, plotdata, plot_saturation

    rows = Any[]
    add(doi, property, phase, T, p, value, unit) =
        push!(rows, (doi, property, phase, T, p, value, unit))
    for T in (250.0, 280.0, 300.0)
        add("10.1/a", "Mass density", "Liquid", T, NaN, 700 - 0.8 * (T - 250), "kg/m3")
        add("10.1/a", "Mass density", "Gas", T, NaN, 2 + 0.05 * (T - 250), "kg/m3")
        add(
            "10.1/a",
            "Vapor or sublimation pressure",
            "Liquid",
            T,
            NaN,
            10 * exp((T - 250) / 30),
            "kPa",
        )
    end
    # A density with a pressure is not at saturation.
    add("10.1/a", "Mass density", "Liquid", 260.0, 5000.0, 690.0, "kg/m3")
    add("10.1/a", "Critical temperature", "", NaN, NaN, 400.0, "K")
    add("10.1/a", "Critical density", "", NaN, NaN, 250.0, "kg/m3")
    add("10.1/a", "Critical pressure", "", NaN, NaN, 4000.0, "kPa")
    add("10.1/b", "Critical temperature", "", NaN, NaN, 402.0, "K")
    add("10.1/b", "Critical density", "", NaN, NaN, 245.0, "kg/m3")
    n = length(rows)
    col(i) = [r[i] for r in rows]
    t = PointTable(
        (;
            source = fill("x", n),
            doi = String.(col(1)),
            year = fill(Int16(2000), n),
            components = fill("a", n),
            xkind = fill("", n),
            property = String.(col(2)),
            method = fill("", n),
            phase = String.(col(3)),
            temperature = Float64.(col(4)),
            pressure = Float64.(col(5)),
            x1 = fill(NaN, n),
            value = Float64.(col(6)),
            unit = String.(col(7)),
            unc_k2 = fill(NaN, n),
        ),
        "K",
        "kPa",
    )
    fig = plot_saturation(plotdata(t); spec = true)
    @test length(fig.panels) == 2
    rho, ps = fig.panels
    @test rho.ylabel == raw"\rho\;[\mathrm{kg}\,\mathrm{m}^{-3}]"
    liquid = only(l for l in rho.layers if l.label == "liquid")
    @test length(liquid.x) == 3 && liquid.filled          # the one with a pressure is left out
    gas = only(l for l in rho.layers if l.label == "gas")
    @test !gas.filled
    stars = [l for l in rho.layers if l.marker === :star5]
    @test length(stars) == 2 && sort([only(l.x) for l in stars]) == [400.0, 402.0]
    @test sort([only(l.y) for l in stars]) == [245.0, 250.0]
    @test ps.yscale === :log10 && ps.xlabel == raw"1000\,/\,T\;[\mathrm{K}^{-1}]"
    pstar = only(l for l in ps.layers if l.marker === :star5)       # only 10.1/a gives a critical pressure
    @test only(pstar.x) ≈ 1000 / 400 && only(pstar.y) == 4000.0
    @test length(
        plot_saturation(plotdata(t); saturated_only = false, spec = true).panels[1].layers[1].x,
    ) == 4
end

@testitem "the second cycle: deviation map, excess, ternary and years" setup = [PlotSamples] tags =
    [:unit, :fast] begin
    using ThermophysicalDB:
        ThermophysicalDB,
        PointTable,
        plotdata,
        plot_deviation_map,
        plot_excess,
        plot_ternary,
        plot_years,
        FigureSpec

    d = PlotSamples.data()
    truth = PlotSamples.truth

    # Deviation map: the colour is the deviation, centred on zero with the diverging map.
    fig = plot_deviation_map(d; model = truth, spec = true)
    panel = only(fig.panels)
    @test fig isa FigureSpec && panel.colorbar !== nothing
    @test panel.colorrange[1] == -panel.colorrange[2] && panel.colorrange[2] > 0
    @test panel.colormap == ThermophysicalDB.plot_style(:default).diverging
    @test panel.xlabel == raw"T\;[\mathrm{K}]" && panel.ylabel == raw"p\;[\mathrm{kPa}]"
    @test sum(length(l.x) for l in panel.layers) == length(d)
    absolute = only(
        plot_deviation_map(d; model = truth, absolute_value = true, spec = true).panels,
    )
    @test absolute.colorrange[1] == 0.0
    @test only(plot_deviation_map(d; model = truth, limit = 5, spec = true).panels).colorrange ==
          (-5.0, 5.0)

    # Years: the bars of each year and the cumulative number.
    yfig = plot_years(d; spec = true)
    @test length(yfig.panels) == 2 && yfig.panels[1].layers[1].kind === :polygon
    cumulative = yfig.panels[2].layers[1]
    @test cumulative.y[end] == length(d) && issorted(cumulative.y)
    @test cumulative.x[1] == 1990.0 && cumulative.x[end] == 2020.0
    @test length(plot_years(d; cumulative = false, spec = true).panels) == 1

    # Excess: the fraction of one component on the x axis, whatever the order of the articles;
    # only the points with a mole fraction.
    n = 12
    xs = collect(range(0.1, 0.9; length = 6))
    cols = (;
        source = fill("x", n),
        doi = repeat(["10.1/a", "10.1/b"], 6),
        year = fill(Int16(2000), n),
        # The second article lists the system the other way round: x1 is then water.
        components = repeat(["a + b", "b + a"], 6),
        xkind = vcat(fill("Mole fraction", 10), fill("Molality", 2)),
        property = repeat(["Excess molar volume", "Excess molar enthalpy"], inner = 6),
        method = fill("", n),
        phase = fill("Liquid", n),
        temperature = fill(298.15, n),
        pressure = fill(101.325, n),
        x1 = repeat(xs, 2),
        x2 = 1 .- repeat(xs, 2),
        value = [x * (1 - x) for x in repeat(xs, 2)],
        unit = repeat(["m3/mol", "J/mol"], inner = 6),
        unc_k2 = fill(NaN, n),
    )
    ex = plot_excess(plotdata(PointTable(cols, "K", "kPa")); spec = true)
    @test length(ex.panels) == 2 && all(p -> p.xlabel == raw"x_{\mathrm{a}}", ex.panels)
    # 10 mole-fraction points (the molality ones are left out) and the order is undone:
    # the points of "b + a" have x_a = 1 - x1.
    drawn = [(l.x, l.y) for p in ex.panels for l in p.layers if l.kind === :scatter]
    @test sum(length(x) for (x, _) in drawn) == 10
    @test all(0 < v < 1 for (x, _) in drawn for v in x)
    # Both orders give the same values of x_a (the others would be 0.26, 0.58 and 0.9).
    @test sort(unique(round.(vcat((x for (x, _) in drawn)...); digits = 6))) ==
          [0.1, 0.42, 0.74]
    @test length(
        plot_excess(
            plotdata(PointTable(cols, "K", "kPa"));
            xkind = nothing,
            color = :temperature,
            spec = true,
        ).panels,
    ) == 2

    # Ternary: the triangle, its labels and the points in its plane.
    m = 10
    x1 = collect(range(0.05, 0.6; length = m))
    x2 = fill(0.3, m)
    tcols = (;
        source = fill("x", m),
        doi = fill("10.1/t", m),
        year = fill(Int16(2010), m),
        components = fill("a + b + c", m),
        xkind = fill("", m),
        property = fill("Mass density", m),
        method = fill("", m),
        phase = fill("Liquid", m),
        temperature = fill(300.0, m),
        pressure = fill(101.0, m),
        x1,
        x2,
        x3 = fill(NaN, m),
        value = 800 .+ 100 .* x1,
        unit = fill("kg/m3", m),
        unc_k2 = fill(NaN, m),
    )
    td = plotdata(PointTable(tcols, "K", "kPa"))
    tfig = plot_ternary(td; spec = true)
    tp = only(tfig.panels)
    @test !tp.frame && tp.aspect_equal && tp.colorbar !== nothing
    texts = [l for l in tp.layers if l.kind === :text]
    @test length(texts) == 2 && texts[2].text == ["a", "b", "c"]
    points = only(l for l in tp.layers if l.kind === :scatter)
    # The third fraction is what is left; the point of x = (0.05, 0.3, 0.65) is near the top.
    @test points.y[1] ≈ 0.65 * sqrt(3) / 2 && points.x[1] ≈ 0.3 + 0.65 / 2
    @test points.y[end] ≈ 0.1 * sqrt(3) / 2
    @test_throws ArgumentError plot_ternary(td; components = "a + b", spec = true)
    # A binary system is refused.
    @test_throws ArgumentError plot_ternary(d; spec = true)
end

@testitem "the axes and the colour bars take units of the units packages" setup =
    [FilterData] tags = [:unit, :fast] begin
    using ThermophysicalDB: ThermophysicalDB, DataView, plot_xpt, plot_isotherms, plotdata
    using Unitful: Unitful
    using DynamicQuantities: DynamicQuantities as DQ
    using FlexUnits: FlexUnits as FU

    view = DataView(FilterData.build())
    common = (; property = "Mass density", component = "water", spec = true)
    # Text, Unitful and FlexUnits give the same figure: the same numbers and the same labels.
    text = only(plot_xpt(view; common..., xunit = "degC", yunit = "bar").panels)
    unitful = only(
        plot_xpt(view; common..., xunit = Unitful.u"°C", yunit = Unitful.u"bar").panels,
    )
    @test unitful.xlabel == text.xlabel && unitful.ylabel == text.ylabel
    @test only(unitful.layers).x == only(text.layers).x
    @test only(unitful.layers).y == only(text.layers).y
    flex = only(
        plot_xpt(
            view;
            common...,
            xunit = FU.UnitRegistry.uparse("K"),
            yunit = FU.UnitRegistry.uparse("bar"),
        ).panels,
    )
    @test flex.xlabel == raw"T\;[\mathrm{K}]" && flex.ylabel == text.ylabel
    @test only(flex.layers).y == only(text.layers).y

    # The colour bar and the value of a property.
    bar = plot_isotherms(view; common..., cunit = Unitful.u"°C").panels[1].colorbar
    @test bar.label == raw"T\;[{}^{\circ}\mathrm{C}]" && bar.limits[1] < 100
    d = plotdata(
        view;
        property = "Mass density",
        component = "water",
        unit = Unitful.u"g/cm^3",
    )
    @test ThermophysicalDB.column(d, :value) isa Vector{Float64}
    @test ThermophysicalDB.value_unit(d, "Mass density") == "g cm^-3"

    # A selection with no points says so.
    @test_throws ArgumentError plot_xpt(view; property = "Nothing like this", spec = true)

    # DynamicQuantities keeps no text of its units: the error says to use text.
    @test_throws ArgumentError plot_xpt(view; common..., xunit = DQ.uparse("K"))
end
