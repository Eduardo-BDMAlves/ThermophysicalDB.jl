```@raw html
---
layout: home

hero:
  name: "ThermophysicalDB.jl"
  text: "Experimental thermophysical data, one call away"
  tagline: Download the NIST/TRC ThermoML Archive once, keep it up to date, and filter, plot and analyse more than a hundred thousand measured systems from the Julia REPL.
  image:
    src: /hero.svg
    alt: Experimental points with uncertainty bars and a fitted curve
  actions:
    - theme: brand
      text: Get started
      link: /10-getting-started
    - theme: alt
      text: Tutorials
      link: /20-tutorials/10-hexane-conductivity
    - theme: alt
      text: View on GitHub
      link: https://github.com/Eduardo-BDMAlves/ThermophysicalDB.jl

features:
  - title: One call gets everything
    details: <code>db = database()</code> downloads the archive from NIST, verifies its SHA-256, parses it once and keeps a binary cache. Later sessions only check for a newer archive and load the cache.
  - title: Filter the way you think
    details: Select by compound, property, temperature and pressure range, author, DOI or year. Chain filters; each one only touches the rows that survived the previous one.
  - title: Units that mean something
    details: Limits accept Unitful quantities such as <code>25u"°C"</code> or <code>1u"atm"</code>, and tables can hand you Unitful columns, in the units of the source or in SI.
  - title: Uncertainty on one footing
    details: Every expanded uncertainty is also restated at k = 2, with an explicit and documented rule, so points from different laboratories can be weighted consistently.
  - title: Tables.jl all the way
    details: A selection is a Tables.jl table made of plain vectors. Plot the columns with Makie, hand them to a DataFrame, or write them to disk, without conversion code.
  - title: Fails loudly, and tells you what to do
    details: Downloads are retried through several strategies. If NIST stays unreachable, the error lists every attempt and the way out, including installing the archive from a file.
---
```

```@meta
CurrentModule = ThermophysicalDB
```

```@setup home
Main.DocsSetup.activate!()
```

## A first look

The first call to [`database`](@ref) downloads and prepares the archive (a few minutes, once). After that, a selection is one line, and its columns are one more.

```@example home
using ThermophysicalDB, CairoMakie

db = database(progress = false)
v = points(db; component = "hexane", property = "Thermal conductivity")
```

`v` is a lazy selection: it only stores which rows matched. Materialise it with [`table`](@ref) and the columns are ordinary vectors, ready to plot.

```@example home
t = table(v)
with_pressure = .!isnan.(t.pressure)

fig = Figure(size = (720, 420))
ax = Axis(fig[1, 1]; xlabel = "T [K]", ylabel = "λ [W m⁻¹ K⁻¹]", title = "Thermal conductivity of hexane")
sc = scatter!(
    ax, t.temperature[with_pressure], t.value[with_pressure];
    color = t.pressure[with_pressure] ./ 1e3, markersize = 9,
)
Colorbar(fig[1, 2], sc; label = "p [MPa]")
fig
```

## Where to go next

```@raw html
<div class="tdb-gallery">
  <a class="tdb-card" href="10-getting-started"><strong>Getting started</strong><span>Install the package, build the database and run your first query.</span></a>
  <a class="tdb-card" href="20-tutorials/10-hexane-conductivity"><strong>Hexane</strong><span>Thermal conductivity against temperature and pressure, with uncertainty bars.</span></a>
  <a class="tdb-card" href="20-tutorials/20-water-density"><strong>Water density</strong><span>Hundreds of laboratories compared with the Kell equation, filtered in °C and atm.</span></a>
  <a class="tdb-card" href="20-tutorials/30-vapor-pressure"><strong>Vapor pressure</strong><span>Clausius–Clapeyron and the enthalpy of vaporization of ethanol.</span></a>
  <a class="tdb-card" href="20-tutorials/40-mixtures"><strong>Binary mixtures</strong><span>The viscosity of ethanol + water against composition.</span></a>
  <a class="tdb-card" href="20-tutorials/50-eos-comparison"><strong>Equations of state</strong><span>Hexane data against PR, SRK, PC-SAFT and SAFT-VR Mie from Clapeyron.jl.</span></a>
  <a class="tdb-card" href="20-tutorials/60-co2-critical-point"><strong>Carbon dioxide</strong><span>Data and equations of state around the critical point.</span></a>
  <a class="tdb-card" href="30-manual/30-uncertainty"><strong>Uncertainty</strong><span>What k = 2 means here and how each point is rescaled.</span></a>
  <a class="tdb-card" href="30-manual/40-data-management"><strong>Updates and cache</strong><span>Where the data live and what to do when the download fails.</span></a>
  <a class="tdb-card" href="95-reference"><strong>API reference</strong><span>Every exported function, with its docstring.</span></a>
</div>
```

## Data source

The data come from the **ThermoML Archive**, created and maintained by the Thermodynamics Research Center (TRC) of the U.S. National Institute of Standards and Technology (NIST) and based on the IUPAC ThermoML standard. ThermophysicalDB.jl is an independent project that downloads, reads and filters that archive; it does not own, modify or redistribute the data. The goal of the package is to bring several experimental databases under one interface, and the ThermoML Archive is the first one supported.

- Dataset: [doi:10.18434/mds2-2422](https://doi.org/10.18434/mds2-2422)
- Standard: M. Frenkel *et al.*, *Pure and Applied Chemistry* **78** (2006) 541–612
- More details and how to cite: [About the data](@ref 40-about-data)

## Contributors

```@raw html
<!-- ALL-CONTRIBUTORS-LIST:START - Do not remove or modify this section -->
<!-- prettier-ignore-start -->
<!-- markdownlint-disable -->

<!-- markdownlint-restore -->
<!-- prettier-ignore-end -->

<!-- ALL-CONTRIBUTORS-LIST:END -->
```
