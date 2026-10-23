# ThermoML JSON -> ParsedArticle.
#
# The JSON files mirror ThermoML.xsd: repeatable elements are arrays, single elements are
# objects, and every object carries a `tml_elements` list that we ignore. Access goes
# through small defensive helpers (`jfield`, `jstr`, ...) because the archive is
# human-curated: a missing or oddly typed field must never abort the whole article.

# ----------------------------------------------------------------------------------
# JSON access helpers
# ----------------------------------------------------------------------------------

jfield(obj, key::AbstractString) = obj isa AbstractDict ? get(obj, key, nothing) : nothing

function jat(obj, keys::AbstractString...)
    for key in keys
        obj = jfield(obj, key)
        obj === nothing && return nothing
    end
    return obj
end

# Iterate something that may be an array, a lone object, or absent.
jitems(::Nothing) = ()
jitems(x::AbstractVector) = x
jitems(x::AbstractDict) = (x,)
jitems(x) = ()

function jstr(obj, key::AbstractString)::String
    v = jfield(obj, key)
    return v isa AbstractString ? String(v) : ""
end

function jnum(obj, key::AbstractString)::Float64
    v = jfield(obj, key)
    v isa Bool && return NaN
    v isa Real && return Float64(v)
    v isa AbstractString && return something(tryparse(Float64, v), NaN)
    return NaN
end

function jint(obj, key::AbstractString)::Int
    v = jfield(obj, key)
    v isa Bool && return 0
    v isa Integer && return Int(v)
    v isa Real && return isfinite(v) ? round(Int, v) : 0
    v isa AbstractString && return something(tryparse(Int, v), 0)
    return 0
end

function jstrings(x)::Vector{String}
    return String[String(s) for s in jitems(x) if s isa AbstractString]
end

# `{"RegNum": {"nOrgNum": 3}}` -> 3 (0 when absent)
jorgnum(obj) = jint(jfield(obj, "RegNum"), "nOrgNum")

# The one non-metadata entry of an object such as {"eTemperature": "...", "tml_elements": [...]}
function only_entry(obj)
    obj isa AbstractDict || return (nothing, nothing)
    for (key, value) in pairs(obj)
        key == "tml_elements" || return (key, value)
    end
    return (nothing, nothing)
end

# ----------------------------------------------------------------------------------
# Conditions (variables and constraints)
# ----------------------------------------------------------------------------------

"How one variable or constraint of an experiment is stored."
struct ConditionSpec
    role::Symbol    # :temperature, :pressure, :composition or :other (goes to extras)
    slot::Int       # component slot for :composition
    label::String   # extras key when the value does not fit a core column
end

mutable struct Conditions
    temperature::Float64
    pressure::Float64
    x::NTuple{MAX_COMPONENTS,Float64}
    extras::Union{Nothing,ExtraPairs}
end

Conditions() = Conditions(NaN, NaN, ntuple(_ -> NaN, MAX_COMPONENTS), nothing)

function copy_conditions(c::Conditions)
    return Conditions(
        c.temperature,
        c.pressure,
        c.x,
        c.extras === nothing ? nothing : copy(c.extras),
    )
end

function condition_spec(type_obj, id_obj, phase::String, orgnums, kinds, names)
    key, value = only_entry(type_obj)
    text = value isa AbstractString ? String(value) : ""
    label = isempty(text) ? "unrecognised condition" : text
    if key == "eTemperature" && text == "Temperature, K"
        return ConditionSpec(:temperature, 0, label)
    elseif key == "ePressure" && text == "Pressure, kPa"
        return ConditionSpec(:pressure, 0, label)
    elseif key == "eComponentComposition" || key == "eSolventComposition"
        org = jorgnum(id_obj)
        name = get(names, org, "component $org")
        label = label * " [" * name * "]" * (isempty(phase) ? "" : " (" * phase * ")")
        if key == "eComponentComposition"
            slot = something(findfirst(==(org), orgnums), 0)
            if slot != 0
                isempty(kinds[slot]) && (kinds[slot] = text)
                kinds[slot] == text && return ConditionSpec(:composition, slot, label)
            end
        end
    end
    return ConditionSpec(:other, 0, label)
end

function apply_condition!(c::Conditions, spec::ConditionSpec, value::Float64)
    if spec.role === :temperature && isnan(c.temperature)
        c.temperature = value
    elseif spec.role === :pressure && isnan(c.pressure)
        c.pressure = value
    elseif spec.role === :composition && isnan(c.x[spec.slot])
        c.x = Base.setindex(c.x, value, spec.slot)
    else
        extras = c.extras === nothing ? (c.extras = ExtraPairs()) : c.extras
        push!(extras, spec.label => value)
    end
    return nothing
end

# ----------------------------------------------------------------------------------
# Properties
# ----------------------------------------------------------------------------------

# Properties that are not a direct value cannot share a label with the direct ones, or a
# filter on "Activity coefficient" would silently mix ratios with values.
function presentation_qualifier(presentation::String)
    presentation == "Direct value, X" && return ("", true)
    startswith(presentation, "Ratio of difference") &&
        return (" [relative difference from reference state]", false)
    startswith(presentation, "Ratio with") && return (" [ratio to reference state]", false)
    startswith(presentation, "Difference with") &&
        return (" [difference from reference state]", true)
    startswith(presentation, "Difference between upper and lower") &&
        return (" [difference between upper and lower temperature]", true)
    isempty(presentation) && return ("", true)
    return (" [" * presentation * "]", true)
end

function property_extras(p, names)
    extras = ExtraPairs()
    method_id = jfield(p, "Property-MethodID")
    component = jorgnum(method_id)
    component > 0 &&
        push!(extras, "property_component" => get(names, component, "component $component"))
    solvent = String[
        get(names, jint(r, "nOrgNum"), "") for r in jitems(jat(p, "Solvent", "RegNum"))
    ]
    filter!(!isempty, solvent)
    isempty(solvent) || push!(extras, "solvent" => join(solvent, " + "))
    for (key, source) in (
        "standard_state" => jstr(p, "eStandardState"),
        "reference_state" => jstr(p, "eRefStateType"),
        "reference_phase" => jstr(jfield(p, "RefPhaseID"), "eRefPhase"),
    )
        isempty(source) || push!(extras, key => source)
    end
    for (key, source) in (
        "reference_temperature_K" => jnum(p, "nRefTemp"),
        "reference_pressure_kPa" => jnum(p, "nRefPressure"),
    )
        isnan(source) || push!(extras, key => source)
    end
    return extras
end

function parse_property(p, names)::Union{Nothing,ParsedProperty}
    group_key, group_obj = only_entry(jat(p, "Property-MethodID", "PropertyGroup"))
    group_key === nothing && return nothing
    raw = jstr(group_obj, "ePropName")
    isempty(raw) && return nothing
    method = jstr(group_obj, "eMethodName")
    isempty(method) && (method = jstr(group_obj, "sMethodName"))
    label, spec = split_property_name(raw)
    unit = spec === nothing ? "" : spec.native
    qualifier, keeps_unit = presentation_qualifier(jstr(p, "ePresentation"))
    keeps_unit || (unit = "")
    return ParsedProperty(
        jint(p, "nPropNumber"),
        String(label) * qualifier,
        unit,
        String(group_key),
        method,
        jstr(jfield(p, "PropPhaseID"), "ePropPhase"),
        jnum(jfield(p, "CombinedUncertainty"), "nCombUncertLevOfConfid") / 100,
        property_extras(p, names),
    )
end

# ----------------------------------------------------------------------------------
# Experiments
# ----------------------------------------------------------------------------------

function parse_experiment(pm, names, path, skipped)::Union{Nothing,ParsedExperiment}
    number = jint(pm, "nPureOrMixtureDataNumber")
    orgnums = Int[jorgnum(c) for c in jitems(jfield(pm, "Component"))]
    if isempty(orgnums) || length(orgnums) > MAX_COMPONENTS
        push!(
            skipped,
            "$path, system $number: $(length(orgnums)) components " *
            "(supported: 1 to $MAX_COMPONENTS)",
        )
        return nothing
    end
    kinds = fill("", length(orgnums))

    extras = ExtraPairs()
    phases =
        filter!(!isempty, String[jstr(p, "ePhase") for p in jitems(jfield(pm, "PhaseID"))])
    isempty(phases) || push!(extras, "phases" => join(phases, "; "))
    for (key, field) in (
        "compiler" => "sCompiler",
        "contributor" => "sContributor",
        "date_added" => "dateDateAdded",
    )
        value = jstr(pm, field)
        isempty(value) || push!(extras, key => value)
    end

    properties = ParsedProperty[]
    property_index = Dict{Int,Int}()
    for p in jitems(jfield(pm, "Property"))
        parsed = parse_property(p, names)
        parsed === nothing && continue
        push!(properties, parsed)
        property_index[parsed.number] = length(properties)
    end

    base = Conditions()
    for c in jitems(jfield(pm, "Constraint"))
        id = jfield(c, "ConstraintID")
        phase = jstr(jfield(c, "ConstraintPhaseID"), "eConstraintPhase")
        spec =
            condition_spec(jfield(id, "ConstraintType"), id, phase, orgnums, kinds, names)
        apply_condition!(base, spec, jnum(c, "nConstraintValue"))
    end

    specs = Dict{Int,ConditionSpec}()
    for v in jitems(jfield(pm, "Variable"))
        id = jfield(v, "VariableID")
        phase = jstr(jfield(v, "VarPhaseID"), "eVarPhase")
        specs[jint(v, "nVarNumber")] =
            condition_spec(jfield(id, "VariableType"), id, phase, orgnums, kinds, names)
    end

    measurements = ParsedMeasurement[]
    for row in jitems(jfield(pm, "NumValues"))
        conditions = copy_conditions(base)
        for vv in jitems(jfield(row, "VariableValue"))
            spec = get(specs, jint(vv, "nVarNumber"), nothing)
            spec === nothing && continue
            apply_condition!(conditions, spec, jnum(vv, "nVarValue"))
        end
        for pv in jitems(jfield(row, "PropertyValue"))
            index = get(property_index, jint(pv, "nPropNumber"), 0)
            index == 0 && continue
            value = jnum(pv, "nPropValue")
            isnan(value) && continue
            push!(
                measurements,
                ParsedMeasurement(
                    Int32(index),
                    value,
                    jnum(jfield(pv, "CombinedUncertainty"), "nCombExpandUncertValue"),
                    conditions.temperature,
                    conditions.pressure,
                    conditions.x,
                    conditions.extras,
                ),
            )
        end
    end
    return ParsedExperiment(number, orgnums, kinds, properties, measurements, extras)
end

# ----------------------------------------------------------------------------------
# Article
# ----------------------------------------------------------------------------------

function compound_display_name(c::ParsedCompound)
    isempty(c.names) || return c.names[1]
    return isempty(c.formula) ? c.inchikey : c.formula
end

function parse_article_unchecked(path::String, bytes)::ParsedArticle
    root = JSON.parse(bytes)
    root isa AbstractDict ||
        throw(ArgumentError("the top level of the file is not an object"))
    citation = jfield(root, "Citation")
    doi = jstr(citation, "sDOI")
    isempty(doi) && (doi = String(chopsuffix(path, ".json")))   # files are named by DOI
    extras = ExtraPairs()
    keywords = jstrings(jfield(citation, "sKeyword"))
    isempty(keywords) || push!(extras, "keywords" => join(keywords, "; "))

    compounds = ParsedCompound[
        ParsedCompound(
            jorgnum(c),
            jstr(c, "sStandardInChIKey"),
            jstr(c, "sStandardInChI"),
            jstr(c, "sFormulaMolec"),
            jstrings(jfield(c, "sCommonName")),
        ) for c in jitems(jfield(root, "Compound"))
    ]
    names = Dict{Int,String}(c.org_num => compound_display_name(c) for c in compounds)

    skipped = String[]
    experiments = ParsedExperiment[]
    for pm in jitems(jfield(root, "PureOrMixtureData"))
        parsed = parse_experiment(pm, names, path, skipped)
        parsed === nothing || push!(experiments, parsed)
    end
    return ParsedArticle(
        path,
        doi,
        jstr(citation, "sTitle"),
        jstr(citation, "sPubName"),
        jint(citation, "yrPubYr"),
        jstr(citation, "sVol"),
        jstr(citation, "sPage"),
        jstrings(jfield(citation, "sAuthor")),
        extras,
        compounds,
        experiments,
        length(jitems(jfield(root, "ReactionData"))),
        skipped,
        "",
    )
end

"""
    parse_article(path, bytes) -> ParsedArticle

Parse one ThermoML JSON file. Never throws (except on interruption): an article that
cannot be parsed comes back with a non-empty `error` so a single bad file cannot stop the
processing of the other 11,922. Safe to call from several threads.
"""
function parse_article(path::AbstractString, bytes::AbstractVector{UInt8})::ParsedArticle
    try
        return parse_article_unchecked(String(path), bytes)
    catch err
        err isa InterruptException && rethrow()
        return failed_article(path, sprint(showerror, err))
    end
end
