# ThermoML export: the points of a selection as ThermoML documents, in the JSON form of the
# NIST/TRC archive (`name.thermoml.json`) and as the XML the standard defines (one
# `DataReport` per article, in the directory `name.thermoml/`).
#
# Both come from one tree (`JObject`) built in the order of the elements of the schema
# (ThermoML.xsd, version 4.0; the archive uses ThermoML 2.0 documents), so a document is
# valid against the schema when its XML form is. What the package does not keep is absent,
# not invented; the exceptions are said in the docstring of `export_points`:
#
# - a count of significant digits the source did not give is taken from the number as
#   written (the schema requires one);
# - a property without a method gets the free text "method not stated", because the schema
#   requires one;
# - the uncertainty of a point is always written; the evaluation of the property
#   (method, level of confidence, coverage factor) only when the method is known, because the
#   schema makes the method part of it (a warning counts what is left out).

const THERMOML_NAMESPACE = "http://www.iupac.org/namespaces/ThermoML"
const THERMOML_VERSION = (2, 0)

# ----------------------------------------------------------------------------------
# What the export needs besides the columns
# ----------------------------------------------------------------------------------

"""
Per-export state: the extra fields of the rows that are written (one scan of the sparse
table instead of one per article), the steps of the samples that are written, and counters
of what had to be derived or left out.
"""
mutable struct ThermomlContext
    ds::Dataset
    reference_extras::Dict{Int32,ExtraPairs}
    experiment_extras::Dict{Int32,ExtraPairs}
    row_extras::Dict{Int32,ExtraPairs}
    steps::Dict{Int32,Vector{Int32}}
    experiment_conditions::Dict{Int32,Vector{Int32}}   # constraints and phases
    row_conditions::Dict{Int32,Vector{Int32}}          # variables of the selected points
    derived_digits::Int
    levels_without_method::Int
end

function ThermomlContext(view::DataView)
    ds = view.dataset
    m, ex = ds.measurements, ds.experiments
    wanted_reference = falses(length(ds.references))
    wanted_experiment = falses(length(ex))
    wanted_row = falses(length(m))
    selected_row = falses(length(m))
    wanted_sample = falses(length(ds.samples))
    seen = Set{NTuple{4,Int32}}()
    for r in view.rows
        selected_row[r] = true
        e = m.experiment[r]
        if !wanted_experiment[e]
            wanted_experiment[e] = true
            wanted_reference[ex.reference[e]] = true
            for i = 1:Int(ex.ncomp[e])
                s = ex.samples[i][e]
                s == NO_ID || (wanted_sample[s] = true)
            end
        end
        key = (e, m.property[r], m.method[r], m.phase[r])
        key in seen || (push!(seen, key); wanted_row[r] = true)
    end

    context = ThermomlContext(
        ds,
        Dict{Int32,ExtraPairs}(),
        Dict{Int32,ExtraPairs}(),
        Dict{Int32,ExtraPairs}(),
        Dict{Int32,Vector{Int32}}(),
        Dict{Int32,Vector{Int32}}(),
        Dict{Int32,Vector{Int32}}(),
        0,
        0,
    )
    cd = ds.conditions
    for i in eachindex(cd.row)
        row = cd.row[i]
        if cd.scope[i] == 1
            wanted_experiment[row] &&
                push!(get!(Vector{Int32}, context.experiment_conditions, row), i)
        else
            selected_row[row] && push!(get!(Vector{Int32}, context.row_conditions, row), i)
        end
    end
    t = ds.extras
    for i in eachindex(t.row)
        code, row = t.scope[i], t.row[i]
        target =
            code == 1 ? (wanted_reference[row] ? context.reference_extras : nothing) :
            code == 3 ? (wanted_experiment[row] ? context.experiment_extras : nothing) :
            code == 4 ? (wanted_row[row] ? context.row_extras : nothing) : nothing
        target === nothing && continue
        value = t.text[i] == NO_ID ? t.number[i] : pool_string(ds.extra_texts, t.text[i])
        push!(get!(ExtraPairs, target, row), pool_string(ds.extra_keys, t.key[i]) => value)
    end
    ps = ds.purity_steps
    for i in eachindex(ps.sample)
        wanted_sample[ps.sample[i]] &&
            push!(get!(Vector{Int32}, context.steps, ps.sample[i]), i)
    end
    return context
end

function extra_value(pairs::Union{Nothing,ExtraPairs}, key::AbstractString)
    pairs === nothing && return nothing
    for k = length(pairs):-1:1
        pairs[k].first == key && return pairs[k].second
    end
    return nothing
end

function extra_string(pairs, key)
    value = extra_value(pairs, key)
    return value isa String ? value : ""
end

# ----------------------------------------------------------------------------------
# Numbers
# ----------------------------------------------------------------------------------

"""
    significant_digits(x) -> Int

Significant digits of `x` as it is written (shortest round-trip form, trailing zeros of a
whole number not counted). The schema requires a count next to every value; this is the
count used when the source did not give one.
"""
function significant_digits(x::Real)
    (isfinite(x) && x != 0) || return 1
    text = lowercase(string(Float64(abs(x))))
    mantissa = first(split(text, 'e'))
    if occursin('.', mantissa)
        whole, fraction = split(mantissa, '.')
        fraction == "0" && (fraction = "")
        digits = lstrip(whole * fraction, '0')
        isempty(whole) || whole == "0" || (digits = whole * fraction)
        whole == "0" && (digits = lstrip(fraction, '0'))
        isempty(fraction) && (digits = rstrip(digits, '0'))
        return max(length(digits), 1)
    end
    return max(length(rstrip(lstrip(mantissa, '0'), '0')), 1)
end

function digits_or_derived!(context::ThermomlContext, stored::Integer, x::Real)
    stored != NO_DIGITS && return Int(stored)
    context.derived_digits += 1
    return significant_digits(x)
end

# A percentage stored as a fraction, written back without the noise of the division.
percent_value(x::Real) = round(100 * Float64(x); sigdigits = 12)

# ----------------------------------------------------------------------------------
# Citation and compounds
# ----------------------------------------------------------------------------------

function thermoml_citation(context::ThermomlContext, ref::Int32)
    citation = JObject()
    ref == NO_ID && return citation
    rf = context.ds.references
    extras = get(context.reference_extras, ref, nothing)
    text(tag) = extra_string(extras, "citation:" * tag)
    put!(name, value) = isempty(value) || add!(citation, name, value)
    # the TRC reference id needs all four parts in the schema; an incomplete one is left out
    trc_parts =
        [text("TRCRefID:" * tag) for tag in ("yrYrPub", "sAuthor1", "sAuthor2", "nAuthorn")]
    if all(!isempty, trc_parts)
        year, author1, author2, count = trc_parts
        add!(
            citation,
            "TRCRefID",
            JObject(
                "yrYrPub" => something(tryparse(Int, year), 0),
                "sAuthor1" => author1,
                "sAuthor2" => author2,
                "nAuthorn" => something(tryparse(Int, count), 0),
            ),
        )
    end
    put!("eType", text("eType"))
    put!("eSourceType", text("eSourceType"))
    put!("sDocumentOrigin", text("sDocumentOrigin"))
    isempty(rf.authors[ref]) || add!(citation, "sAuthor", Any[a for a in rf.authors[ref]])
    put!("sPubName", rf.journal[ref])
    rf.year[ref] > 0 && add!(citation, "yrPubYr", Int(rf.year[ref]))
    put!("dateCit", text("dateCit"))
    put!("sTitle", rf.title[ref])
    put!("sAbstract", extra_string(extras, "abstract"))
    keywords = extra_string(extras, "keywords")
    isempty(keywords) ||
        add!(citation, "sKeyword", Any[String(k) for k in split(keywords, "; ")])
    put!("eLanguage", text("eLanguage"))
    put!("sDOI", rf.doi[ref])
    put!("urlCit", text("urlCit"))
    put!("sCASCit", text("sCASCit"))
    put!("sIDNum", text("sIDNum"))
    put!("sLocation", text("sLocation"))
    put!("sVol", rf.volume[ref])
    put!("sPage", rf.pages[ref])
    return citation
end

# `analysis` and `purification` of a step: the enumerated methods, then the free text.
function method_lists!(
    o::JObject,
    enum_name,
    text_name,
    names::Vector{String},
    text::String,
)
    isempty(names) || add!(o, enum_name, Any[n for n in names])
    isempty(text) || add!(o, text_name, Any[text])
    return o
end

function thermoml_purity_step(context::ThermomlContext, i::Integer)
    ds = context.ds
    ps = ds.purity_steps
    step = JObject("nStep" => Int(ps.step[i]))
    purification = pool_strings(ds.purifications, ps.purification[i])
    purification_text = pool_string(ds.extra_texts, ps.purification_text[i])
    method_lists!(step, "ePurifMethod", "sPurifMethod", purification, purification_text)
    function put!(name, x, stored)
        isnan(x) && return nothing
        percent = percent_value(x)
        add!(step, name, percent)
        add!(step, name * "Digits", digits_or_derived!(context, stored, percent))
        return nothing
    end
    # the stored count belongs to the first purity the step states (mass, mole, volume,
    # unspecified, as the parser reads them); the schema lists mole before mass
    stated = (ps.mass[i], ps.mole[i], ps.volume[i], ps.unknown[i])
    first_stated = something(findfirst(!isnan, stated), 0)
    kept(kind) = kind == first_stated ? ps.digits[i] : NO_DIGITS
    put!("nPurityMol", ps.mole[i], kept(2))
    put!("nPurityMass", ps.mass[i], kept(1))
    put!("nPurityVol", ps.volume[i], kept(3))
    put!("nUnknownPerCent", ps.unknown[i], kept(4))
    put!("nWaterMassPerCent", ps.water_mass[i], NO_DIGITS)
    put!("nWaterMolPerCent", ps.water_mole[i], NO_DIGITS)
    put!("nHalideMolPerCent", ps.halide_mole[i], NO_DIGITS)
    put!("nHalideMassPerCent", ps.halide_mass[i], NO_DIGITS)
    analysis = pool_strings(ds.analyses, ps.analysis[i])
    analysis_text = pool_string(ds.extra_texts, ps.analysis_text[i])
    method_lists!(step, "eAnalMeth", "sAnalMeth", analysis, analysis_text)
    return step
end

function thermoml_sample(context::ThermomlContext, s::Integer)
    ds = context.ds
    st = ds.samples
    sample = JObject("nSampleNm" => Int(st.number[s]))
    origin = pool_string(ds.origins, st.origin[s])
    isempty(origin) || add!(sample, "eSource", origin)
    status = pool_string(ds.statuses, st.status[s])
    isempty(status) || add!(sample, "eStatus", status)
    steps = get(context.steps, Int32(s), Int32[])
    isempty(steps) || add!(
        sample,
        "purity",
        Any[
            thermoml_purity_step(context, i) for
            i in sort(steps; by = i -> ds.purity_steps.step[i])
        ],
    )
    return sample
end

# ----------------------------------------------------------------------------------
# Properties
# ----------------------------------------------------------------------------------

"One ThermoML `Property` of an experiment: the identifying key and what the block needs."
struct PropertyVariant
    property::Int32
    method::Int32
    phase::Int32
    level::Float64
    coverage::Float64
    unc_method::Int32
    number::Int
    row::Int32          # a row that shows the property-level extras
end

function strip_qualifier(label::AbstractString)
    endswith(label, ']') || return String(label)
    i = findlast(" [", label)
    return i === nothing ? String(label) : String(SubString(label, 1, first(i) - 1))
end

function property_name(pr::PropertyTable, property::Integer, extras)
    raw = extra_string(extras, "property_name")
    isempty(raw) || return raw
    label, unit = pr.label[property], pr.unit[property]
    return isempty(unit) ? label : string(label, ", ", unit)
end

# The component a property is about, as a local compound number, or 0.
function property_component(ctx::ThermomlContext, e::Integer, local_number, extras)
    name = extra_string(extras, "property_component")
    isempty(name) && return 0
    ds, ex = ctx.ds, ctx.ds.experiments
    for i = 1:Int(ex.ncomp[e])
        c = ex.components[i][e]
        ct = ds.compounds
        (name in ct.names[c] || name == ct.formula[c] || name == ct.inchikey[c]) &&
            return local_number[c]
    end
    return 0
end

# `RegNum` elements for compounds stored as the text "id,id" (positions in the compound table).
function reg_nums(text::AbstractString, local_number)
    list = Any[]
    isempty(text) && return list
    for part in split(text, ',')
        n = get(local_number, parse(Int32, part), 0)
        n == 0 || push!(list, JObject("nOrgNum" => n))
    end
    return list
end

# The schema allows one `RegNum` in a phase of a property: the first compound is kept.
function phase_object(name, phase, text, local_number)
    o = JObject(name => phase)
    regnum = reg_nums(text, local_number)
    isempty(regnum) || add!(o, "RegNum", first(regnum))
    return o
end

function thermoml_property(
    context::ThermomlContext,
    e::Integer,
    variant::PropertyVariant,
    local_number,
)
    ds = context.ds
    pr = ds.properties
    extras = get(context.row_extras, variant.row, nothing)
    group = pool_string(ds.groups, pr.group[variant.property])
    isempty(group) && (group = "Property")
    named = JObject("ePropName" => property_name(pr, variant.property, extras))
    method = pool_string(ds.methods, variant.method)
    if isempty(method)
        # the schema wants a method for every property; say that none was given
        add!(named, "sMethodName", "method not stated")
    else
        free = haskey(ds.method_texts.index, method)
        add!(named, free ? "sMethodName" : "eMethodName", method)
    end
    method_id = JObject("PropertyGroup" => JObject(group => named))
    component = property_component(context, e, local_number, extras)
    component == 0 || add!(method_id, "RegNum", JObject("nOrgNum" => component))
    p = JObject("nPropNumber" => variant.number, "Property-MethodID" => method_id)
    phase = pool_string(ds.phases, variant.phase)
    isempty(phase) || add!(
        p,
        "PropPhaseID",
        phase_object("ePropPhase", phase, extra_string(extras, "phase_ids"), local_number),
    )
    presentation = extra_string(extras, "presentation")
    add!(p, "ePresentation", isempty(presentation) ? "Direct value, X" : presentation)
    reference_state = extra_string(extras, "reference_state")
    isempty(reference_state) || add!(p, "eRefStateType", reference_state)
    for (key, name) in (
        ("reference_temperature_K", "nRefTemp"),
        ("reference_pressure_kPa", "nRefPressure"),
    )
        x = extra_value(extras, key)
        if x isa Float64
            add!(p, name, x)
            add!(p, name * "Digits", digits_or_derived!(context, NO_DIGITS, x))
        end
    end
    reference_phase = extra_string(extras, "reference_phase")
    isempty(reference_phase) || add!(
        p,
        "RefPhaseID",
        phase_object(
            "eRefPhase",
            reference_phase,
            extra_string(extras, "reference_phase_ids"),
            local_number,
        ),
    )
    solvent = reg_nums(extra_string(extras, "solvent_ids"), local_number)
    isempty(solvent) || add!(p, "Solvent", JObject("RegNum" => solvent))
    standard_state = extra_string(extras, "standard_state")
    isempty(standard_state) || add!(p, "eStandardState", standard_state)
    unc_method = pool_string(ds.unc_methods, variant.unc_method)
    if isempty(unc_method)
        # the schema ties the level of confidence and the coverage factor to the method
        isnan(variant.level) && isnan(variant.coverage) ||
            (context.levels_without_method += 1)
    else
        assessment = extra_value(extras, "uncertainty_assessment")
        u = JObject(
            "nCombUncertAssessNum" =>
                assessment isa Float64 ? round(Int, assessment) : 1,
        )
        evaluator = extra_string(extras, "uncertainty_evaluator")
        isempty(evaluator) || add!(u, "sCombUncertEvaluator", evaluator)
        add!(u, "eCombUncertEvalMethod", unc_method)
        text = extra_string(extras, "uncertainty_evaluation_text")
        isempty(text) || add!(u, "sCombUncertEvalMethod", text)
        isnan(variant.coverage) || add!(u, "nCombCoverageFactor", variant.coverage)
        isnan(variant.level) ||
            add!(u, "nCombUncertLevOfConfid", round(100 * variant.level; sigdigits = 12))
        add!(p, "CombinedUncertainty", u)
    end
    return p
end

# ----------------------------------------------------------------------------------
# One article
# ----------------------------------------------------------------------------------

function variable_object(
    number,
    type_name,
    type_value,
    component = 0,
    phase = "",
    phase_component = 0,
)
    id = JObject("VariableType" => JObject(type_name => type_value))
    component == 0 || add!(id, "RegNum", JObject("nOrgNum" => component))
    v = JObject("nVarNumber" => number, "VariableID" => id)
    if !isempty(phase)
        p = JObject("eVarPhase" => phase)
        phase_component == 0 || add!(p, "RegNum", JObject("nOrgNum" => phase_component))
        add!(v, "VarPhaseID", p)
    end
    return v
end

# The compound stored as the extra `key` of an experiment, as a local number, or 0.
function extra_compound(extras, key, local_number)
    id = extra_value(extras, key)
    id isa Float64 || return 0
    return get(local_number, Int32(round(id)), 0)
end

# `RegNum` elements for compounds of the dataset, numbered as in the article.
function reg_nums(ids::AbstractVector{Int32}, local_number)
    list = Any[]
    for c in ids
        n = get(local_number, c, 0)
        n == 0 || push!(list, JObject("nOrgNum" => n))
    end
    return list
end

function thermoml_experiment(
    context::ThermomlContext,
    e::Integer,
    rs::Vector{Int32},
    number::Integer,
    local_number,
)
    ds = context.ds
    m, ex = ds.measurements, ds.experiments
    n = Int(ex.ncomp[e])
    extras = get(context.experiment_extras, Int32(e), nothing)
    block = JObject("nPureOrMixtureDataNumber" => number)
    components = Any[]
    for i = 1:n
        o = JObject("RegNum" => JObject("nOrgNum" => local_number[ex.components[i][e]]))
        s = ex.samples[i][e]
        s == NO_ID || add!(o, "nSampleNm", Int(ds.samples.number[s]))
        push!(components, o)
    end
    add!(block, "Component", components)
    purpose = pool_string(ds.purposes, ex.purpose[e])
    isempty(purpose) || add!(block, "eExpPurpose", purpose)
    for (name, key) in (
        ("sCompiler", "compiler"),
        ("sContributor", "contributor"),
        ("dateDateAdded", "date_added"),
    )
        value = extra_string(extras, key)
        isempty(value) || add!(block, name, value)
    end

    # properties: one per (property, method, phase), split further when the evaluation of
    # the uncertainty differs between the points
    variants = PropertyVariant[]
    by_key = Dict{NTuple{3,Int32},Vector{Int}}()
    variant_of_row = Vector{Int}(undef, length(rs))
    for (j, r) in enumerate(rs)
        key = (m.property[r], m.method[r], m.phase[r])
        list = get!(Vector{Int}, by_key, key)
        has_unc = !isnan(m.unc[r])
        found = 0
        for v in list
            variant = variants[v]
            if !has_unc
                found = v
                break
            elseif variant.unc_method == NO_ID
                variants[v] = PropertyVariant(
                    variant.property,
                    variant.method,
                    variant.phase,
                    m.unc_level[r],
                    m.unc_k[r],
                    m.unc_method[r],
                    variant.number,
                    variant.row,
                )
                found = v
                break
            elseif variant.unc_method == m.unc_method[r] &&
                   isequal(variant.level, m.unc_level[r]) &&
                   isequal(variant.coverage, m.unc_k[r])
                found = v
                break
            end
        end
        if found == 0
            push!(
                variants,
                PropertyVariant(
                    key[1],
                    key[2],
                    key[3],
                    has_unc ? m.unc_level[r] : NaN,
                    has_unc ? m.unc_k[r] : NaN,
                    has_unc ? m.unc_method[r] : NO_ID,
                    length(variants) + 1,
                    r,
                ),
            )
            found = length(variants)
            push!(list, found)
        end
        variant_of_row[j] = found
    end
    add!(
        block,
        "Property",
        Any[thermoml_property(context, e, variant, local_number) for variant in variants],
    )

    # phases of the system (with the components they are stated for), from the conditions
    cd = ds.conditions
    conditions = get(context.experiment_conditions, Int32(e), Int32[])
    phases = Tuple{String,Int32}[]
    for i in conditions
        cd.role[i] == 3 || continue
        name = pool_string(ds.condition_labels, cd.label[i])
        isempty(name) && continue
        entry = (name, cd.component[i])
        entry in phases || push!(phases, entry)
    end
    if isempty(phases)
        names = String[]
        phase_text = extra_string(extras, "phases")
        isempty(phase_text) || append!(names, split(phase_text, "; "))
        if isempty(names)
            for variant in variants
                p = pool_string(ds.phases, variant.phase)
                isempty(p) || p in names || push!(names, p)
            end
        end
        append!(phases, (name, NO_ID) for name in names)
    end
    if !isempty(phases)
        # one `PhaseID` per phase and component: the schema allows a single `RegNum` in each
        objects = Any[]
        for (name, component) in phases
            o = JObject("ePhase" => name)
            number = component == NO_ID ? 0 : get(local_number, component, 0)
            number == 0 || add!(o, "RegNum", JObject("nOrgNum" => number))
            push!(objects, o)
        end
        add!(block, "PhaseID", objects)
    end

    # constraints: held fixed for the whole experiment
    constraints = Any[]
    for i in conditions
        (cd.role[i] == 1 && cd.group[i] != NO_ID) || continue
        id = JObject(
            "ConstraintType" => JObject(
                pool_string(ds.condition_groups, cd.group[i]) =>
                    pool_string(ds.condition_labels, cd.label[i]),
            ),
        )
        component = cd.component[i] == NO_ID ? 0 : get(local_number, cd.component[i], 0)
        component == 0 || add!(id, "RegNum", JObject("nOrgNum" => component))
        c = JObject("nConstraintNumber" => length(constraints) + 1, "ConstraintID" => id)
        phase = pool_string(ds.phases, cd.phase[i])
        if !isempty(phase)
            o = JObject("eConstraintPhase" => phase)
            pc =
                cd.phase_component[i] == NO_ID ? 0 :
                get(local_number, cd.phase_component[i], 0)
            pc == 0 || add!(o, "RegNum", JObject("nOrgNum" => pc))
            add!(c, "ConstraintPhaseID", o)
        end
        add!(c, "nConstraintValue", cd.value[i])
        add!(c, "nConstrDigits", digits_or_derived!(context, cd.digits[i], cd.value[i]))
        push!(constraints, c)
    end
    isempty(constraints) || add!(block, "Constraint", constraints)

    # variables: only the conditions the points have
    # (what a constraint states is not repeated as a variable of every point)
    kinds = String[pool_string(ds.kinds, ex.kinds[i][e]) for i = 1:n]
    fixed_T = fixed_P = false
    fixed_x = falses(n)
    for i in conditions
        (cd.role[i] == 1 && cd.group[i] != NO_ID) || continue
        group = pool_string(ds.condition_groups, cd.group[i])
        label = pool_string(ds.condition_labels, cd.label[i])
        if group == "eTemperature" && label == "Temperature, K"
            fixed_T = true
        elseif group == "ePressure" && label == "Pressure, kPa"
            fixed_P = true
        elseif group == "eComponentComposition"
            for k = 1:n
                if cd.component[i] == ex.components[k][e] && label == kinds[k]
                    fixed_x[k] = true
                end
            end
        end
    end
    has_T = !fixed_T && any(r -> !isnan(m.temperature[r]), rs)
    has_P = !fixed_P && any(r -> !isnan(m.pressure[r]), rs)
    has_x = Bool[
        !fixed_x[i] && !isempty(kinds[i]) && any(r -> !isnan(m.composition[i][r]), rs)
        for i = 1:n
    ]
    variables = Any[]
    var_T = var_P = 0
    var_x = zeros(Int, n)
    if has_T
        var_T = length(variables) + 1
        push!(
            variables,
            variable_object(
                var_T,
                "eTemperature",
                "Temperature, K",
                0,
                extra_string(extras, "variable_phase:temperature"),
                extra_compound(
                    extras,
                    "variable_phase_component:temperature",
                    local_number,
                ),
            ),
        )
    end
    if has_P
        var_P = length(variables) + 1
        push!(
            variables,
            variable_object(
                var_P,
                "ePressure",
                "Pressure, kPa",
                0,
                extra_string(extras, "variable_phase:pressure"),
                extra_compound(extras, "variable_phase_component:pressure", local_number),
            ),
        )
    end
    for i = 1:n
        has_x[i] || continue
        var_x[i] = length(variables) + 1
        push!(
            variables,
            variable_object(
                var_x[i],
                "eComponentComposition",
                kinds[i],
                local_number[ex.components[i][e]],
                extra_string(extras, "variable_phase:composition:" * string(i)),
                extra_compound(
                    extras,
                    "variable_phase_component:composition:" * string(i),
                    local_number,
                ),
            ),
        )
    end
    # the other variables, numbered after those, in the order they first appear
    other_number = Dict{NTuple{5,Int32},Int}()
    for r in rs, i in get(context.row_conditions, r, Int32[])
        cd.group[i] == NO_ID && continue
        key =
            (cd.group[i], cd.label[i], cd.component[i], cd.phase[i], cd.phase_component[i])
        haskey(other_number, key) && continue
        number = length(variables) + 1
        other_number[key] = number
        component = key[3] == NO_ID ? 0 : get(local_number, key[3], 0)
        push!(
            variables,
            variable_object(
                number,
                pool_string(ds.condition_groups, key[1]),
                pool_string(ds.condition_labels, key[2]),
                component,
                pool_string(ds.phases, key[4]),
                key[5] == NO_ID ? 0 : get(local_number, key[5], 0),
            ),
        )
    end
    isempty(variables) || add!(block, "Variable", variables)

    numvalues = Any[]
    for (j, r) in enumerate(rs)
        values = Any[]
        function put_variable!(number, x, digits)
            return push!(
                values,
                JObject(
                    "nVarNumber" => number,
                    "nVarValue" => x,
                    "nVarDigits" => digits_or_derived!(context, digits, x),
                ),
            )
        end
        has_T &&
            !isnan(m.temperature[r]) &&
            put_variable!(var_T, m.temperature[r], m.temperature_digits[r])
        has_P &&
            !isnan(m.pressure[r]) &&
            put_variable!(var_P, m.pressure[r], m.pressure_digits[r])
        for i = 1:n
            (has_x[i] && !isnan(m.composition[i][r])) || continue
            put_variable!(var_x[i], m.composition[i][r], m.composition_digits[i][r])
        end
        for i in get(context.row_conditions, r, Int32[])
            cd.group[i] == NO_ID && continue
            key = (
                cd.group[i],
                cd.label[i],
                cd.component[i],
                cd.phase[i],
                cd.phase_component[i],
            )
            put_variable!(other_number[key], cd.value[i], cd.digits[i])
        end
        variant = variants[variant_of_row[j]]
        pv = JObject(
            "nPropNumber" => variant.number,
            "nPropValue" => m.value[r],
            "nPropDigits" => digits_or_derived!(context, m.digits[r], m.value[r]),
        )
        if !isnan(m.unc[r])
            extras_row = get(context.row_extras, variant.row, nothing)
            assessment = extra_value(extras_row, "uncertainty_assessment")
            add!(
                pv,
                "CombinedUncertainty",
                JObject(
                    "nCombUncertAssessNum" =>
                        assessment isa Float64 ? round(Int, assessment) : 1,
                    "nCombExpandUncertValue" => m.unc[r],
                ),
            )
        end
        row = JObject()
        isempty(values) || add!(row, "VariableValue", values)
        add!(row, "PropertyValue", Any[pv])
        push!(numvalues, row)
    end
    add!(block, "NumValues", numvalues)
    return block
end

"""
    thermoml_article(context, ref, rows) -> JObject

One ThermoML document (`DataReport`) with the points `rows` of the reference `ref`.
Compounds are numbered per article, as in the archive; a point is a row of `NumValues`.
"""
function thermoml_article(context::ThermomlContext, ref::Int32, rows::Vector{Int32})
    ds = context.ds
    m, ex, ct = ds.measurements, ds.experiments, ds.compounds

    by_experiment = Dict{Int32,Vector{Int32}}()
    order = Int32[]
    for r in rows
        e = m.experiment[r]
        bucket = get!(by_experiment, e) do
            push!(order, e)
            Int32[]
        end
        push!(bucket, r)
    end

    local_number = Dict{Int32,Int}()
    compound_order = Int32[]
    samples_of = Dict{Int32,Vector{Int32}}()
    for e in order, i = 1:Int(ex.ncomp[e])
        c = ex.components[i][e]
        if !haskey(local_number, c)
            push!(compound_order, c)
            local_number[c] = length(compound_order)
        end
        s = ex.samples[i][e]
        if s != NO_ID
            list = get!(Vector{Int32}, samples_of, c)
            s in list || push!(list, s)
        end
    end
    compounds = Any[]
    for c in compound_order
        o = JObject("RegNum" => JObject("nOrgNum" => local_number[c]))
        isempty(ct.inchi[c]) || add!(o, "sStandardInChI", ct.inchi[c])
        isempty(ct.inchikey[c]) || add!(o, "sStandardInChIKey", ct.inchikey[c])
        isempty(ct.names[c]) || add!(o, "sCommonName", Any[s for s in ct.names[c]])
        isempty(ct.formula[c]) || add!(o, "sFormulaMolec", ct.formula[c])
        list = get(samples_of, c, Int32[])
        isempty(list) || add!(
            o,
            "Sample",
            Any[
                thermoml_sample(context, s) for
                s in sort(list; by = s -> ds.samples.number[s])
            ],
        )
        push!(compounds, o)
    end

    blocks = Any[
        thermoml_experiment(context, e, by_experiment[e], k, local_number) for
        (k, e) in enumerate(order)
    ]
    article = JObject(
        "Version" => JObject(
            "nVersionMajor" => THERMOML_VERSION[1],
            "nVersionMinor" => THERMOML_VERSION[2],
        ),
        "Citation" => thermoml_citation(context, ref),
    )
    add!(article, "Compound", compounds)
    add!(article, "PureOrMixtureData", blocks)
    return article
end

function articles_of(view::DataView)
    ds = view.dataset
    groups = Dict{Int32,Vector{Int32}}()
    for r in view.rows
        ref = ds.experiments.reference[ds.measurements.experiment[r]]
        push!(get!(Vector{Int32}, groups, ref), r)
    end
    return groups
end

function warn_thermoml(context::ThermomlContext)
    context.levels_without_method > 0 && @warn(
        "ThermoML export: the level of confidence or the coverage factor of some " *
        "properties was left out, because the schema requires the method that evaluated " *
        "the uncertainty and the dataset does not have it",
        properties = context.levels_without_method,
    )
    return nothing
end

# ----------------------------------------------------------------------------------
# JSON
# ----------------------------------------------------------------------------------

function write_points_thermoml(
    path::AbstractString,
    view::DataView;
    origin::Union{Nothing,DataOrigin} = origin_note(view),
)
    context = ThermomlContext(view)
    groups = articles_of(view)
    open(path, "w") do io
        write(io, "{\n")
        if origin !== nothing
            write(io, "  \"origin\": ")
            write_json(io, origin_object(origin), 1, 2)
            write(io, ",\n")
        end
        write(
            io,
            "  \"format\": \"ThermoML in the JSON form of the NIST/TRC archive: every entry of `articles` is a DataReport; the XML form is the same tree\",\n",
        )
        write(io, "  \"articles\": [")
        for (k, ref) in enumerate(sort!(collect(keys(groups))))
            write(io, k == 1 ? "\n    " : ",\n    ")
            write_json(io, thermoml_article(context, ref, groups[ref]), 2, 8)
        end
        write(io, "\n  ]\n}\n")
    end
    warn_thermoml(context)
    return nothing
end

# ----------------------------------------------------------------------------------
# XML
# ----------------------------------------------------------------------------------

function xml_escape(io::IO, s::AbstractString)
    for c in s
        if c == '&'
            write(io, "&amp;")
        elseif c == '<'
            write(io, "&lt;")
        elseif c == '>'
            write(io, "&gt;")
        elseif c == '"'
            write(io, "&quot;")
        elseif c < ' ' && c != '\n' && c != '\t' && c != '\r'
            write(io, ' ')
        else
            write(io, c)
        end
    end
    return nothing
end

function write_xml(io::IO, name::AbstractString, value::AbstractVector, depth::Int)
    for item in value
        write_xml(io, name, item, depth)
    end
    return nothing
end

function write_xml(io::IO, name::AbstractString, value::JObject, depth::Int)
    pad = "  "^depth
    if isempty(value.pairs)
        write(io, pad, '<', name, "/>\n")
        return nothing
    end
    write(io, pad, '<', name, ">\n")
    for (child, item) in value.pairs
        write_xml(io, child, item, depth + 1)
    end
    write(io, pad, "</", name, ">\n")
    return nothing
end

function write_xml(io::IO, name::AbstractString, value, depth::Int)
    write(io, "  "^depth, '<', name, '>')
    value isa AbstractString ? xml_escape(io, value) : print(io, value)
    write(io, "</", name, ">\n")
    return nothing
end

"The XML text of one article (`DataReport`), with `comment` as a comment at the top."
function thermoml_xml(article::JObject; comment::AbstractString = "")
    io = IOBuffer()
    write(io, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
    if !isempty(comment)
        write(io, "<!--\n")
        for line in split(comment, '\n')
            write(io, replace(line, "--" => "- -"), '\n')
        end
        write(io, "-->\n")
    end
    write(io, "<DataReport xmlns=\"", THERMOML_NAMESPACE, "\">\n")
    for (child, item) in article.pairs
        write_xml(io, child, item, 1)
    end
    write(io, "</DataReport>\n")
    return String(take!(io))
end

# A file name made from a DOI.
xml_file_name(doi::AbstractString, k::Integer) =
    isempty(doi) ? string("article-", k) : replace(doi, r"[^A-Za-z0-9._()-]" => "_")

"""
    write_points_thermoml_xml(directory, view; origin)

Write one ThermoML XML document per article of `view` into `directory`, named after the
DOI of the article (`10.1016_j.fluid.2013.07.008.xml`).
"""
function write_points_thermoml_xml(
    directory::AbstractString,
    view::DataView;
    origin::Union{Nothing,DataOrigin} = origin_note(view),
)
    context = ThermomlContext(view)
    groups = articles_of(view)
    mkpath(directory)
    comment = origin === nothing ? "" : join(notice_lines(), '\n')
    used = Set{String}()
    for (k, ref) in enumerate(sort!(collect(keys(groups))))
        article = thermoml_article(context, ref, groups[ref])
        name = xml_file_name(view.dataset.references.doi[ref], k)
        while name in used
            name *= "_"
        end
        push!(used, name)
        write(joinpath(directory, name * ".xml"), thermoml_xml(article; comment))
    end
    warn_thermoml(context)
    return nothing
end
