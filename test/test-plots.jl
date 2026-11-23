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
