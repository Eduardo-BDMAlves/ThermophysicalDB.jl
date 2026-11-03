# Merging parsed articles into the global Dataset. This part is sequential: it interns
# strings, deduplicates compounds and references, and appends rows in file order, so the
# identifiers a build produces are reproducible regardless of the thread count.

"Bookkeeping of one build, returned next to the dataset."
mutable struct BuildReport
    articles::Int
    experiments::Int
    reaction_blocks::Int
    failed::Vector{String}
    skipped::Vector{String}
end

BuildReport() = BuildReport(0, 0, 0, String[], String[])

const MEASUREMENT_SCOPE = scope_code(:measurement)

# Extras converted once to identifiers, so a property with 500 points interns its keys
# a single time instead of 500.
const PreparedExtra = Tuple{UInt8,Float64,Int32}

function prepare_extras(ds::Dataset, pairs::ExtraPairs)
    prepared = PreparedExtra[]
    for (key, value) in pairs
        key_id = extra_key_code(ds, key)
        if value isa String
            push!(prepared, (key_id, NaN, intern!(ds.extra_texts, value)))
        elseif !isnan(value)
            push!(prepared, (key_id, value, NO_ID))
        end
    end
    return prepared
end

function push_prepared!(ex::ExtraTable, code::UInt8, row::Integer, prepared)
    for (key_id, number, text_id) in prepared
        push!(ex.scope, code)
        push!(ex.row, Int32(row))
        push!(ex.key, key_id)
        push!(ex.number, number)
        push!(ex.text, text_id)
    end
    return nothing
end

function intern_all!(pool::StringPool, labels::Vector{String})
    return Int32[intern!(pool, l) for l in labels]
end

# Add one parsed sample with its steps and summary; returns the row of the sample.
function ingest_sample!(
    ds::Dataset,
    reference::Integer,
    compound::Integer,
    sample::ParsedSample,
)
    t = ds.samples
    before = length(t)
    id = add_sample!(
        t;
        reference,
        compound,
        number = sample.number,
        origin = intern!(ds.origins, sample.origin),
        status = intern!(ds.statuses, sample.status),
    )
    length(t) == before && return id    # the same sample was already added
    for step in sample.steps
        add_purity_step!(
            ds.purity_steps;
            sample = id,
            step = step.step,
            mass = step.mass,
            mole = step.mole,
            volume = step.volume,
            unknown = step.unknown,
            digits = step.digits,
            water_mass = step.water_mass,
            water_mole = step.water_mole,
            halide_mass = step.halide_mass,
            halide_mole = step.halide_mole,
            analysis = intern_all!(ds.analyses, step.analysis),
            analysis_text = intern!(ds.extra_texts, step.analysis_text),
            purification = intern_all!(ds.purifications, step.purification),
            purification_text = intern!(ds.extra_texts, step.purification_text),
        )
    end
    summary = summarize_purity(sample.steps)
    t.nsteps[id] = UInt8(min(length(sample.steps), 255))
    t.purity[id] = summary.purity
    t.purity_kind[id] = UInt8(summary.kind)
    t.purity_initial[id] = summary.initial
    t.purity_initial_kind[id] = UInt8(summary.initial_kind)
    t.water[id] = summary.water
    t.purity_basis[id] = UInt8(summary.basis)
    append!(t.analysis[id], intern_all!(ds.analyses, summary.analysis))
    append!(t.purification[id], intern_all!(ds.purifications, summary.purification))
    return id
end

# The compounds of a solvent or of a phase, as the positions in the compound table.
function ids_text(orgs::AbstractVector{Int}, compound_ids)
    ids = Int32[get(compound_ids, o, NO_ID) for o in orgs]
    filter!(!=(NO_ID), ids)
    return join(ids, ",")
end

function property_extras_with_ids(p::ParsedProperty, compound_ids)
    extras = copy(p.extras)
    for (key, orgs) in (
        "solvent_ids" => p.solvent_orgs,
        "phase_ids" => p.phase_orgs,
        "reference_phase_ids" => p.reference_phase_orgs,
    )
        text = ids_text(orgs, compound_ids)
        isempty(text) || push!(extras, key => text)
    end
    return extras
end

function add_phase_condition!(ds::Dataset, experiment, phase::String, component)
    add_condition!(
        ds.conditions;
        scope = :experiment,
        row = experiment,
        role = :phase,
        label = intern!(ds.condition_labels, phase),
        component,
    )
    return nothing
end

function add_parsed_condition!(
    ds::Dataset,
    scope::Symbol,
    row,
    role::Symbol,
    c::ParsedCondition,
    compound_ids,
)
    add_condition!(
        ds.conditions;
        scope,
        row,
        role,
        group = intern!(ds.condition_groups, c.group),
        label = intern!(ds.condition_labels, c.label),
        value = c.value,
        digits = c.digits,
        phase = intern!(ds.phases, c.phase),
        component = c.org == 0 ? NO_ID : get(compound_ids, c.org, NO_ID),
        phase_component = c.phase_org == 0 ? NO_ID : get(compound_ids, c.phase_org, NO_ID),
    )
    return nothing
end

function ingest!(ds::Dataset, article::ParsedArticle, source::Integer, report::BuildReport)
    report.articles += 1
    if !isempty(article.error)
        push!(report.failed, article.path * ": " * article.error)
        return nothing
    end
    report.reaction_blocks += article.reaction_blocks
    append!(report.skipped, article.skipped)

    reference = add_reference!(
        ds.references;
        doi = article.doi,
        title = article.title,
        journal = article.journal,
        year = article.year,
        volume = article.volume,
        pages = article.pages,
        authors = article.authors,
        source,
    )
    for (key, value) in article.extras
        add_extra!(ds, :reference, reference, key, value)
    end

    compound_ids = Dict{Int,Int32}()
    sample_ids = Dict{Tuple{Int,Int},Int32}()
    for c in article.compounds
        (isempty(c.inchikey) && isempty(c.names)) && continue
        compound = add_compound!(
            ds.compounds;
            inchikey = c.inchikey,
            inchi = c.inchi,
            formula = c.formula,
            names = c.names,
        )
        compound_ids[c.org_num] = compound
        for sample in c.samples
            sample_ids[(c.org_num, sample.number)] =
                ingest_sample!(ds, reference, compound, sample)
        end
    end

    for pe in article.experiments
        components = Int32[get(compound_ids, o, NO_ID) for o in pe.orgnums]
        if any(==(NO_ID), components)
            push!(
                report.skipped,
                "$(article.path), system $(pe.number): a component has no usable identity",
            )
            continue
        end
        report.experiments += 1
        experiment = add_experiment!(
            ds.experiments;
            reference,
            components,
            kinds = Int32[intern!(ds.kinds, k) for k in pe.kinds],
            source,
            number = pe.number,
            samples = Int32[
                get(sample_ids, (o, n), NO_ID) for (o, n) in zip(pe.orgnums, pe.samples)
            ],
            purpose = intern!(ds.purposes, pe.purpose),
        )
        for (key, value) in pe.extras
            if startswith(key, "variable_phase_org:")
                # stored as the compound of the dataset, not the number in the article
                id = get(compound_ids, round(Int, value), NO_ID)
                id == NO_ID || add_extra!(
                    ds,
                    :experiment,
                    experiment,
                    "variable_phase_component:" *
                    key[(length("variable_phase_org:")+1):end],
                    Float64(id),
                )
            else
                add_extra!(ds, :experiment, experiment, key, value)
            end
        end
        for ph in pe.phases
            if isempty(ph.orgs)
                add_phase_condition!(ds, experiment, ph.phase, NO_ID)
            else
                for o in ph.orgs
                    add_phase_condition!(
                        ds,
                        experiment,
                        ph.phase,
                        get(compound_ids, o, NO_ID),
                    )
                end
            end
        end
        for c in pe.constraints
            add_parsed_condition!(ds, :experiment, experiment, :constraint, c, compound_ids)
        end

        property_ids = Int32[
            add_property!(
                ds.properties,
                p.label,
                p.unit;
                group = intern!(ds.groups, p.group),
            ) for p in pe.properties
        ]
        method_ids = Int32[intern!(ds.methods, p.method) for p in pe.properties]
        for p in pe.properties
            p.method_text && intern!(ds.method_texts, p.method)
        end
        phase_ids = Int32[intern!(ds.phases, p.phase) for p in pe.properties]
        unc_method_ids = Int32[intern!(ds.unc_methods, p.unc_method) for p in pe.properties]
        evaluator_ids = Int32[intern!(ds.evaluators, p.evaluator) for p in pe.properties]
        prepared = [
            prepare_extras(ds, property_extras_with_ids(p, compound_ids)) for
            p in pe.properties
        ]

        for m in pe.measurements
            k = Int(m.property)
            row = add_measurement!(
                ds.measurements;
                experiment,
                property = property_ids[k],
                value = m.value,
                method = method_ids[k],
                phase = phase_ids[k],
                unc = m.unc,
                unc_k = isnan(m.unc) ? NaN : pe.properties[k].coverage,
                unc_level = isnan(m.unc) ? NaN : pe.properties[k].level,
                unc_method = isnan(m.unc) ? NO_ID : unc_method_ids[k],
                evaluator = evaluator_ids[k],
                assessment = pe.properties[k].assessment,
                digits = m.digits,
                temperature_digits = m.temperature_digits,
                pressure_digits = m.pressure_digits,
                composition_digits = m.composition_digits,
                temperature = m.temperature,
                pressure = m.pressure,
                composition = m.composition,
            )
            push_prepared!(ds.extras, MEASUREMENT_SCOPE, row, prepared[k])
            if m.conditions !== nothing
                for c in m.conditions
                    add_parsed_condition!(ds, :measurement, row, :variable, c, compound_ids)
                end
            end
        end
    end
    return nothing
end
