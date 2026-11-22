# The look of the figures: colours, markers, sizes and the defaults that the user can change and
# keep (with Preferences.jl). Colours are names of colour schemes (resolved by the plotting
# extension, which finds them in ColorSchemes.jl) or hexadecimal colours.

const PLOT_BACKENDS_KNOWN = (:makie, :plots)
const UNCERTAINTY_MODES = (:auto, :bars, :band, :none)
const PLOT_DEFAULTS_PREFERENCE = "plot_defaults"

# The scientific colour maps of Crameri that the figures use: cold to hot for the colour of a
# point, diverging (centred on zero) for maps of a deviation, and one for counts.
const SEQUENTIAL_COLORMAP = :managua_r
const DIVERGING_COLORMAP = :vik
const COUNT_COLORMAP = :batlow

# Categorical colours (the first 12 colours of `batlowS`, the categorical version of the
# scientific colour map `batlow`) and the order in which the markers are used.
const CATEGORICAL_COLORS = [
    "#011959",
    "#FACCFA",
    "#828231",
    "#226061",
    "#F19D6B",
    "#4D734D",
    "#114360",
    "#FDB4B4",
    "#C09036",
    "#175262",
    "#FCBFD6",
    "#FCA890",
]
const MARKERS = [
    :diamond,
    :circle,
    :rect,
    :utriangle,
    :dtriangle,
    :cross,
    :xcross,
    :star5,
    :hexagon,
    :pentagon,
]

# The colours of the documentation, which come from the emission of gases in discharge tubes
# (see `docs/DocsSetup.jl`): made for a dark panel.
const NEON_COLORS =
    ["#4f6bff", "#ff7a1a", "#2fe0ff", "#ffd36b", "#ff2f3f", "#c8ff4d", "#a98bff", "#58ff7a"]
const NEON_GRADIENT = ["#3347ff", "#6f8cff", "#f2f5ff", "#ff7a1a", "#ff2f3f"]
const NEON_MARKERS = [:circle, :utriangle, :rect, :diamond, :dtriangle, :star5]

"""
    PlotStyle

The look of a figure: `colormap` (the name of a colour scheme, or a vector of colours of a
gradient) for continuous colours, `diverging` for the colours of a map that is centred on zero,
`counts` for counts, `palette` (colours) and `markers` for categories, `background` and
`foreground` (the colour of text, axes and grid; `"none"` is a transparent background), sizes and
`unitformat` (see [`axis_label`](@ref)). Get one with [`plot_style`](@ref).
"""
Base.@kwdef struct PlotStyle
    name::Symbol = :default
    colormap::Union{Symbol,Vector{String}} = SEQUENTIAL_COLORMAP
    diverging::Union{Symbol,Vector{String}} = DIVERGING_COLORMAP
    counts::Union{Symbol,Vector{String}} = COUNT_COLORMAP
    palette::Vector{String} = CATEGORICAL_COLORS
    markers::Vector{Symbol} = MARKERS
    background::String = "white"
    foreground::String = "black"
    markersize::Float64 = 8.0
    linewidth::Float64 = 2.0
    fontsize::Float64 = 13.0
    unitformat::Symbol = :square
end

"""
    plot_style(name = :default; kwargs...) -> PlotStyle

A style of the figures. `:default` (white background, the scientific colour maps `managua_r`
for continuous colours, `vik` for deviations and `batlowS` for categories) and `:neon` (the
colours of the documentation: transparent background, light text and the emission colours of
gases; made for a dark panel, and good up to four to six categories). Keywords replace any field
of the style.
"""
function plot_style(name::Symbol = :default; kwargs...)
    base = if name === :default
        PlotStyle()
    elseif name === :neon
        PlotStyle(;
            name = :neon,
            colormap = NEON_GRADIENT,
            diverging = NEON_GRADIENT,
            palette = NEON_COLORS,
            markers = NEON_MARKERS,
            background = "none",
            foreground = "#9aa3c7",
        )
    else
        throw(ArgumentError("style must be :default or :neon, got $(repr(name))"))
    end
    isempty(kwargs) && return base
    fields = Dict{Symbol,Any}(f => getfield(base, f) for f in fieldnames(PlotStyle))
    for (k, v) in kwargs
        haskey(fields, k) || throw(
            ArgumentError(
                "a style has no field $(repr(k)); the fields are $(fieldnames(PlotStyle))",
            ),
        )
        fields[k] = v
    end
    return PlotStyle(; fields...)
end

# ----------------------------------------------------------------------------------
# The defaults of the session and the ones that are kept
# ----------------------------------------------------------------------------------

const PLOT_DEFAULTS = Dict{Symbol,Any}()

const DEFAULT_SETTINGS = (
    style = :default,
    colormap = nothing,
    deviation = :relative,
    deviation_unit = :percent,
    unitformat = :square,
    uncertainty = :auto,
    backend = nothing,
    marker_by = :reference,
)

function check_default(name::Symbol, value)
    ok = if name === :style
        value in (:default, :neon)
    elseif name === :deviation
        value in DEVIATION_KINDS
    elseif name === :deviation_unit
        haskey(DEVIATION_UNITS, value)
    elseif name === :unitformat
        value in LABEL_FORMATS
    elseif name === :uncertainty
        value in UNCERTAINTY_MODES
    elseif name === :backend
        value === nothing || value in PLOT_BACKENDS_KNOWN
    elseif name === :marker_by
        value === nothing || value in (:reference, :method, :phase, :year_group)
    elseif name === :colormap
        value === nothing || value isa Symbol
    else
        false
    end
    ok || throw(ArgumentError("invalid value $(repr(value)) for the default $(repr(name))"))
    return value
end

# The kept preferences, as symbols (they are stored as text).
function stored_defaults()
    raw = Preferences.load_preference(@__MODULE__, PLOT_DEFAULTS_PREFERENCE, nothing)
    raw isa AbstractDict || return Dict{Symbol,Any}()
    out = Dict{Symbol,Any}()
    for (k, v) in raw
        key = Symbol(k)
        haskey(DEFAULT_SETTINGS, key) || continue
        value = v == "" ? nothing : Symbol(v)
        try
            out[key] = check_default(key, value)
        catch err
            err isa ArgumentError || rethrow()
        end
    end
    return out
end

"""
    plot_defaults(; style, colormap, deviation, deviation_unit, unitformat, uncertainty,
                  backend, marker_by, persist = false) -> NamedTuple

The defaults of the figures: the values that a figure uses when you do not give them. Without
arguments it returns the current ones. `style` is `:default` or `:neon` ([`plot_style`](@ref));
`colormap` the name of a colour scheme (`nothing` keeps the one of the style); `deviation` and
`deviation_unit` the ones of [`DeviationSpec`](@ref); `unitformat` the one of
[`axis_label`](@ref); `uncertainty` how the uncertainty of the points is shown (`:auto`, `:bars`,
`:band` or `:none`); `backend` (`:makie` or `:plots`) the one that draws when both are loaded;
`marker_by` what the marker of a point tells apart (`:reference`, `:method`, `:phase`,
`:year_group` or `nothing`).

The new values hold for this Julia session. With `persist = true` they are also kept with
Preferences.jl, in the `LocalPreferences.toml` of the active environment, and are the starting
point of the next sessions; `reset_plot_defaults!` forgets them.
"""
function plot_defaults(; persist::Bool = false, kwargs...)
    for (k, v) in kwargs
        haskey(DEFAULT_SETTINGS, k) || throw(
            ArgumentError("unknown default $(repr(k)); they are $(keys(DEFAULT_SETTINGS))"),
        )
        check_default(k, v)
        PLOT_DEFAULTS[k] = v
    end
    if persist && !isempty(kwargs)
        kept = Dict{String,String}(
            string(k) => (v === nothing ? "" : string(v)) for (k, v) in stored_defaults()
        )
        for (k, v) in kwargs
            kept[string(k)] = v === nothing ? "" : string(v)
        end
        Preferences.set_preferences!(@__MODULE__, PLOT_DEFAULTS_PREFERENCE => kept)
    end
    stored = stored_defaults()
    return NamedTuple{keys(DEFAULT_SETTINGS)}(
        map(keys(DEFAULT_SETTINGS)) do k
            get(PLOT_DEFAULTS, k, get(stored, k, getfield(DEFAULT_SETTINGS, k)))
        end,
    )
end

"""
    reset_plot_defaults!()

Forget the defaults of the figures that were set in this session and the ones that were kept
with `plot_defaults(...; persist = true)`.
"""
function reset_plot_defaults!()
    empty!(PLOT_DEFAULTS)
    Preferences.delete_preferences!(
        @__MODULE__,
        PLOT_DEFAULTS_PREFERENCE;
        block_precompilation = false,
    )
    return nothing
end

# The style of a figure: the one asked for, or the one of the defaults, with the colour map that
# was chosen.
function resolve_style(style, colormap)
    s =
        style isa PlotStyle ? style :
        plot_style(style === nothing ? plot_defaults().style : style)
    cm = colormap === nothing ? plot_defaults().colormap : colormap
    cm === nothing && return s
    return plot_style(s.name; colormap = cm)
end
