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
const PreparedExtra = Tuple{Int32,Float64,Int32}

function prepare_extras(ds::Dataset, pairs::ExtraPairs)
    prepared = PreparedExtra[]
    for (key, value) in pairs
        key_id = intern!(ds.extra_keys, key)
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
    for c in article.compounds
        (isempty(c.inchikey) && isempty(c.names)) && continue
        compound_ids[c.org_num] = add_compound!(
            ds.compounds;
            inchikey = c.inchikey,
            inchi = c.inchi,
            formula = c.formula,
            names = c.names,
        )
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
        )
        for (key, value) in pe.extras
            add_extra!(ds, :experiment, experiment, key, value)
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
        phase_ids = Int32[intern!(ds.phases, p.phase) for p in pe.properties]
        prepared = [prepare_extras(ds, p.extras) for p in pe.properties]

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
                unc_level = isnan(m.unc) ? NaN : pe.properties[k].level,
                temperature = m.temperature,
                pressure = m.pressure,
                composition = m.composition,
            )
            push_prepared!(ds.extras, MEASUREMENT_SCOPE, row, prepared[k])
            if m.extras !== nothing
                for (key, value) in m.extras
                    add_extra!(ds, :measurement, row, key, value)
                end
            end
        end
    end
    return nothing
end
