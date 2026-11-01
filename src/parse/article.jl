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
    role::Symbol    # :temperature, :pressure, :composition or :other (goes to the conditions)
    slot::Int       # component slot for :composition
    group::String   # element of the schema that names the kind of condition
    label::String   # the name the source wrote, with its unit
    phase::String
    org::Int        # component the condition refers to, 0 for the whole system
    phase_org::Int  # component the phase is stated for, 0 for none
end

mutable struct Conditions
    temperature::Float64
    pressure::Float64
    x::NTuple{MAX_COMPONENTS,Float64}
    x_digits::NTuple{MAX_COMPONENTS,UInt8}
    temperature_digits::UInt8
    pressure_digits::UInt8
    others::Union{Nothing,Vector{ParsedCondition}}
end

Conditions() = Conditions(
    NaN,
    NaN,
    ntuple(_ -> NaN, MAX_COMPONENTS),
    ntuple(_ -> NO_DIGITS, MAX_COMPONENTS),
    NO_DIGITS,
    NO_DIGITS,
    nothing,
)

function copy_conditions(c::Conditions)
    return Conditions(
        c.temperature,
        c.pressure,
        c.x,
        c.x_digits,
        c.temperature_digits,
        c.pressure_digits,
        c.others === nothing ? nothing : copy(c.others),
    )
end

function condition_spec(type_obj, id_obj, phase::String, phase_org, orgnums, kinds, names)
    key, value = only_entry(type_obj)
    text = value isa AbstractString ? String(value) : ""
    label = isempty(text) ? "unrecognised condition" : text
    group = key === nothing ? "" : String(key)
    org = jorgnum(id_obj)
    if key == "eTemperature" && text == "Temperature, K"
        return ConditionSpec(:temperature, 0, group, label, phase, 0, phase_org)
    elseif key == "ePressure" && text == "Pressure, kPa"
        return ConditionSpec(:pressure, 0, group, label, phase, 0, phase_org)
    elseif key == "eComponentComposition"
        slot = something(findfirst(==(org), orgnums), 0)
        if slot != 0
            isempty(kinds[slot]) && (kinds[slot] = text)
            kinds[slot] == text && return ConditionSpec(
                :composition,
                slot,
                group,
                label,
                phase,
                org,
                phase_org,
            )
        end
    end
    return ConditionSpec(:other, 0, group, label, phase, org, phase_org)
end

function apply_condition!(
    c::Conditions,
    spec::ConditionSpec,
    value::Float64,
    digits::UInt8 = NO_DIGITS,
)
    if spec.role === :temperature && isnan(c.temperature)
        c.temperature = value
        c.temperature_digits = digits
    elseif spec.role === :pressure && isnan(c.pressure)
        c.pressure = value
        c.pressure_digits = digits
    elseif spec.role === :composition && isnan(c.x[spec.slot])
        c.x = Base.setindex(c.x, value, spec.slot)
        c.x_digits = Base.setindex(c.x_digits, digits, spec.slot)
    else
        others = c.others === nothing ? (c.others = ParsedCondition[]) : c.others
        push!(others, parsed_condition(spec, value, digits))
    end
    return nothing
end

# Whether the column that `spec` fills is still empty (a second value goes to the others).
function is_free(c::Conditions, spec::ConditionSpec)
    spec.role === :temperature && return isnan(c.temperature)
    spec.role === :pressure && return isnan(c.pressure)
    spec.role === :composition && return isnan(c.x[spec.slot])
    return false
end

parsed_condition(spec::ConditionSpec, value::Float64, digits::UInt8) = ParsedCondition(
    spec.group,
    spec.label,
    value,
    digits,
    spec.phase,
    spec.org,
    spec.phase_org,
)

# Components named by a `RegNum` that may be a list, a lone object or absent.
orgs_of(x) = Int[jint(r, "nOrgNum") for r in jitems(jfield(x, "RegNum"))]

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

# First element of something that may be a list, a lone object or absent.
function first_item(x)
    for item in jitems(x)
        return item
    end
    return nothing
end

function parse_property(p, names)::Union{Nothing,ParsedProperty}
    group_key, group_obj = only_entry(jat(p, "Property-MethodID", "PropertyGroup"))
    group_key === nothing && return nothing
    raw = jstr(group_obj, "ePropName")
    isempty(raw) && return nothing
    method = jstr(group_obj, "eMethodName")
    method_text = isempty(method)
    method_text && (method = jstr(group_obj, "sMethodName"))
    label, spec = split_property_name(raw)
    unit = spec === nothing ? "" : spec.native
    qualifier, keeps_unit = presentation_qualifier(jstr(p, "ePresentation"))
    keeps_unit || (unit = "")
    uncertainty = first_item(jfield(p, "CombinedUncertainty"))
    extras = property_extras(p, names)
    presentation = jstr(p, "ePresentation")
    if !isempty(qualifier) || !keeps_unit
        # the label and the unit no longer say what was written: keep the original words
        push!(extras, "presentation" => presentation)
        push!(extras, "property_name" => String(raw))
    end
    evaluator = jstr(uncertainty, "sCombUncertEvaluator")
    isempty(evaluator) || push!(extras, "uncertainty_evaluator" => evaluator)
    evaluation = jstr(uncertainty, "sCombUncertEvalMethod")
    isempty(evaluation) || push!(extras, "uncertainty_evaluation_text" => evaluation)
    assessment = jnum(uncertainty, "nCombUncertAssessNum")
    isnan(assessment) || push!(extras, "uncertainty_assessment" => assessment)
    return ParsedProperty(
        jint(p, "nPropNumber"),
        String(label) * qualifier,
        unit,
        String(group_key),
        method,
        method_text && !isempty(method),
        jstr(jfield(p, "PropPhaseID"), "ePropPhase"),
        jnum(uncertainty, "nCombUncertLevOfConfid") / 100,
        jnum(uncertainty, "nCombCoverageFactor"),
        jstr(uncertainty, "eCombUncertEvalMethod"),
        extras,
        orgs_of(jfield(p, "Solvent")),
        orgs_of(jfield(p, "PropPhaseID")),
        orgs_of(jfield(p, "RefPhaseID")),
    )
end

# ----------------------------------------------------------------------------------
# Experiments
# ----------------------------------------------------------------------------------

# The phase of a temperature, a pressure or a composition has no column: it is kept as an
# extra of the experiment named `variable_phase:<what>`.
function note_phase!(extras::ExtraPairs, spec::ConditionSpec)
    isempty(spec.phase) && return nothing
    what =
        spec.role === :temperature ? "temperature" :
        spec.role === :pressure ? "pressure" :
        spec.role === :composition ? "composition:" * string(spec.slot) : ""
    isempty(what) && return nothing
    push!(extras, "variable_phase:" * what => spec.phase)
    spec.phase_org == 0 ||
        push!(extras, "variable_phase_org:" * what => Float64(spec.phase_org))
    return nothing
end

function parse_experiment(pm, names, path, skipped)::Union{Nothing,ParsedExperiment}
    number = jint(pm, "nPureOrMixtureDataNumber")
    components = collect(jitems(jfield(pm, "Component")))
    orgnums = Int[jorgnum(c) for c in components]
    samples = Int[jint(c, "nSampleNm") for c in components]
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
    constraints = ParsedCondition[]
    for c in jitems(jfield(pm, "Constraint"))
        id = jfield(c, "ConstraintID")
        phase_obj = jfield(c, "ConstraintPhaseID")
        phase = jstr(phase_obj, "eConstraintPhase")
        spec = condition_spec(
            jfield(id, "ConstraintType"),
            id,
            phase,
            jorgnum(phase_obj),
            orgnums,
            kinds,
            names,
        )
        value = jnum(c, "nConstraintValue")
        digits = digits_code(c, "nConstrDigits")
        note_phase!(extras, spec)
        if spec.role === :other
            push!(constraints, parsed_condition(spec, value, digits))
        else
            # temperature, pressure and compositions also fill the columns of every point;
            # the constraint itself is kept so that the export can write it back as one
            !isnan(value) &&
                is_free(base, spec) &&
                push!(constraints, parsed_condition(spec, value, digits))
            apply_condition!(base, spec, value, digits)
        end
    end

    specs = Dict{Int,ConditionSpec}()
    for v in jitems(jfield(pm, "Variable"))
        id = jfield(v, "VariableID")
        phase_obj = jfield(v, "VarPhaseID")
        phase = jstr(phase_obj, "eVarPhase")
        spec = condition_spec(
            jfield(id, "VariableType"),
            id,
            phase,
            jorgnum(phase_obj),
            orgnums,
            kinds,
            names,
        )
        specs[jint(v, "nVarNumber")] = spec
        note_phase!(extras, spec)
    end

    phase_list = ParsedPhase[
        ParsedPhase(jstr(ph, "ePhase"), orgs_of(ph)) for
        ph in jitems(jfield(pm, "PhaseID")) if !isempty(jstr(ph, "ePhase"))
    ]

    measurements = ParsedMeasurement[]
    for row in jitems(jfield(pm, "NumValues"))
        conditions = copy_conditions(base)
        for vv in jitems(jfield(row, "VariableValue"))
            spec = get(specs, jint(vv, "nVarNumber"), nothing)
            spec === nothing && continue
            apply_condition!(
                conditions,
                spec,
                jnum(vv, "nVarValue"),
                digits_code(vv, "nVarDigits"),
            )
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
                    digits_code(pv, "nPropDigits"),
                    conditions.temperature_digits,
                    conditions.pressure_digits,
                    conditions.x_digits,
                    conditions.others,
                ),
            )
        end
    end
    return ParsedExperiment(
        number,
        orgnums,
        kinds,
        samples,
        jstr(pm, "eExpPurpose"),
        properties,
        measurements,
        extras,
        constraints,
        phase_list,
    )
end

# ----------------------------------------------------------------------------------
# Article
# ----------------------------------------------------------------------------------

function compound_display_name(c::ParsedCompound)
    isempty(c.names) || return c.names[1]
    return isempty(c.formula) ? c.inchikey : c.formula
end

# Citation fields that have no column: kept as reference extras named `citation:<tag>`.
const CITATION_TEXT_TAGS = (
    "eType",
    "eSourceType",
    "sDocumentOrigin",
    "dateCit",
    "eLanguage",
    "urlCit",
    "sCASCit",
    "sIDNum",
    "sLocation",
)

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
    for tag in CITATION_TEXT_TAGS
        value = jstr(citation, tag)
        isempty(value) || push!(extras, "citation:" * tag => value)
    end
    trc = jfield(citation, "TRCRefID")
    for tag in ("yrYrPub", "sAuthor1", "sAuthor2", "nAuthorn")
        v = jfield(trc, tag)
        text = v isa AbstractString ? String(v) : v isa Real ? string(v) : ""
        isempty(text) || push!(extras, "citation:TRCRefID:" * tag => text)
    end
    abstract_text = jstr(citation, "sAbstract")
    isempty(abstract_text) || push!(extras, "abstract" => abstract_text)

    compounds = ParsedCompound[
        ParsedCompound(
            jorgnum(c),
            jstr(c, "sStandardInChIKey"),
            jstr(c, "sStandardInChI"),
            jstr(c, "sFormulaMolec"),
            jstrings(jfield(c, "sCommonName")),
            parse_samples(c),
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
