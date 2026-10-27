```@meta
CurrentModule = ThermophysicalDB
```

# [Water density against IAPWS-95](@id tutorial_water)

Liquid water has more experimental density data than almost any other substance in the archive: hundreds of articles, measured with very different instruments over many decades. That makes it the ideal case to show how filtering with everyday units works and how to judge a literature data set against a reference equation.

The reference here is the IAPWS-95 formulation [Wagner2002](@cite), as implemented in [Clapeyron.jl](https://github.com/ClapeyronThermo/Clapeyron.jl) [Walker2022](@cite). IAPWS-95 is a *fundamental equation*: a single expression for the Helmholtz energy ``A(T, \rho)`` of water, fitted to a very large body of data. Every other property follows from derivatives of it. The pressure, for instance, is

```math
p = -\left(\frac{\partial A}{\partial V}\right)_T ,
```

so the density at given ``T`` and ``p`` is the root of this equation in the volume. Nothing is fitted to the atmospheric isobar alone, which makes the comparison with the experiments an independent test.

In the plots of this page ``T`` is the temperature in Celsius; elsewhere in the documentation it is in Kelvin.

```@setup water
Main.DocsSetup.activate!()
```

## Select in °C and atm

Limits are written with `Unitful.jl` units:

```@example water
using ThermophysicalDB, CairoMakie, Unitful, Statistics

db = database(progress = false)
v = points(
    db;
    component = "water",
    pure = true, exact = true,
    property = "Mass density",
    temperature = (0u"°C", 99u"°C"),
    pressure = (0.98u"atm", 1.02u"atm"),
)
```

## The columns we need

```@example water
t = table(v; unitful = true)

T = t.temperature
ρ = t.value
year = Float64.(t.year)

(points = length(ρ), articles = length(unique(t.doi)))
```

## The model at exactly 1 atm

To check the quality of the experimental data of papers within the dataset, we apply the reference model IAPWS95 at the exact atmospheric pressure.

```@example water
using Clapeyron

model = IAPWS95()
mass_density(model, 1u"atm", 25u"°C")
```

The experiments repeat the same temperatures many times (a laboratory measures several samples at 298.15 K, say), and an evaluation of a multiparameter Helmholtz equation is far more expensive than a lookup. So the model is computed once per distinct temperature and reused for every point:

```@example water
by_temperature = Dict(Ti => mass_density(model, 1u"atm", Ti) for Ti in unique(T))
ρ_model = [by_temperature[Ti] for Ti in T]

(distinct_temperatures = length(by_temperature), points = length(T))
```

## The anomaly of water

Plotted on this scale, the experimental points fall on the curve and the maximum of density near 4 °C is visible.

```@example water
fig = Figure(size = (760, 460))
ax = Axis(fig[1, 1]; xlabel = "T [°C]", ylabel = "ρ [kg m⁻³]", title = "Density of liquid water at 1 atm")
sc = scatter!(ax, ustrip.(u"°C", T), ustrip.(u"kg/m^3", ρ); color = year, Main.DocsSetup.year_scale(year)..., markersize = 7)
tt = collect(range(0, 99; length = 200)) .* u"°C"
lines!(ax, ustrip.(u"°C", tt), ustrip.(u"kg/m^3", mass_density.(Ref(model), 1u"atm", tt)); color = "#e8ecff", linewidth = 2, label = "IAPWS-95")
Colorbar(fig[1, 2], sc; label = "year of publication", ticks = Main.DocsSetup.year_ticks(year))
axislegend(ax; position = :rt)
fig
```

## Residuals: how far is each paper?

The relative deviation from the equation, in parts per million, shows what the previous plot hides. Points outside the displayed window are counted, not drawn.

```@example water
res = 1e6 .* Float64.((ρ .- ρ_model) ./ ρ_model)
window = 600
outside = count(>(window), abs.(res))

fig = Figure(size = (760, 460))
ax = Axis(
    fig[1, 1]; xlabel = "T [°C]", ylabel = "(ρ − ρ_IAPWS-95)/ρ_IAPWS-95 [ppm]",
    title = "Deviation from IAPWS-95 ($(outside) points outside ±$(window) ppm)",
    limits = (nothing, (-window, window)),
)
hlines!(ax, [0.0]; color = "#e8ecff", linewidth = 1.5)
sc = scatter!(ax, ustrip.(u"°C", T), res; color = year, Main.DocsSetup.year_scale(year)..., markersize = 7)
Colorbar(fig[1, 2], sc; label = "year of publication", ticks = Main.DocsSetup.year_ticks(year))
fig
```

## Has the data improved with time?

Grouping the residuals by five-year periods summarizes the scatter of each year. Boxes show the quartiles and the line the median; outliers are present.

```@example water
period = 5 .* (t.year .÷ 5)
periods = sort(unique(period))
slot = [findfirst(==(q), periods) for q in period]

fig = Figure(size = (760, 420))
ax = Axis(
    fig[1, 1]; xlabel = "five-year period", ylabel = "(ρ − ρ_IAPWS-95)/ρ_IAPWS-95 [ppm]",
    xticks = (1:length(periods), string.(periods)), xticklabelrotation = π / 4,
    title = "Scatter of water-density data by period",
)
boxplot!(ax, slot, res; color = ("#ffb000", 0.7), show_outliers = true)
fig
```

## Who measured it?

The `doi` column ties every point to its article, so listing the most productive sources takes a few lines:

```@example water
counts = Dict{String,Int}()
for d in t.doi
    counts[d] = get(counts, d, 0) + 1
end
first(sort(collect(counts); by = last, rev = true), 8)
```

To work with a single article, pass its DOI back to [`points`](@ref): `points(v; doi = "10.…")`.

## Citing the sources

Every point belongs to an article, and an analysis that uses them should cite the articles. [`bibtex`](@ref) and [`write_bibtex`](@ref) turn a selection into a BibTeX file with one entry per article. Here is the entry of the first article of the list above, written from the metadata stored in the archive (`online = false` keeps this page independent of the network):

```@example water
one = points(v; doi = first(sort(collect(keys(counts)))))
print(bibtex(one; online = false, include_source = false))
```

For the whole selection, ask for the file. This contacts `doi.org` once per article (a few at a time), so the first export of hundreds of articles takes a while; the entries are kept in the data directory, and later exports are immediate and work offline:

```julia
report = write_bibtex("water.bib", v)
report
```

For each article, the entry delivered by the DOI is compared with the metadata of the archive. The DOI entry is the one written, a field that only the archive has is added to it, and the report lists the fields on which the two disagree, which is a quick way to spot errors in the archive. The file also contains the entries for the ThermoML Archive and for the ThermoML standard, so the origin of the data is credited wherever the file goes.

### A table of the articles

A bibliography does not say what each article measured. [`reference_summary`](@ref) condenses the selection into one row per article and property: number of points, ranges of temperature and pressure, method, and the median expanded uncertainty at ``k = 2``. The units are your choice; here, kelvin and kilopascal:

```@example water
using Unitful
articles = reference_summary(v; online = false, pressure_unit = u"kPa")
```

It is a table in the sense of Tables.jl, so `DataFrame(articles)` works, and it can be written for a paper. `write_references` produces the BibTeX file and the LaTeX table together, so the `\cite{...}` keys of the table are those of the `.bib`; a Markdown and a CSV version come with them:

```julia
write_references("water", v; pressure_unit = u"kPa")
# water.bib  water.tex  water.md  water.csv
```

The articles are ordered from the oldest to the newest year; within a year, by month when the DOI entry has it and otherwise alphabetically. A method name that is too long is replaced by its initials and explained in a note under the table.

## Variations to try

- Use the pressure of each point instead of 1 atm: call `mass_density(model, p, T)` with the stated pressure (`t.pressure`), and widen the pressure window. The model then follows the compression of the liquid.
- Move the upper limit to `99.9u"°C"` and then to `100u"°C"` and watch what happens to the residuals near the boiling point.
- Replace `IAPWS95()` with a cubic model such as `PR(["water"])` and compare the residuals: a cubic equation is off by percent, not ppm, in the liquid density of water.
