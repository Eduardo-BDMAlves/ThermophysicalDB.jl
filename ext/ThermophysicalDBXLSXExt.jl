# Writes the sheets that `export_points` builds. Loaded when the user runs `using XLSX`.
module ThermophysicalDBXLSXExt

using ThermophysicalDB: ThermophysicalDB
using XLSX: XLSX

function ThermophysicalDB.write_xlsx(
    path::String,
    sheets::Vector{ThermophysicalDB.SheetSpec},
)
    isfile(path) && rm(path)
    XLSX.openxlsx(path; mode = "w") do book
        for (k, (name, (columns, names))) in enumerate(sheets)
            sheet = k == 1 ? book[1] : XLSX.addsheet!(book, name)
            k == 1 && XLSX.rename!(sheet, name)
            XLSX.writetable!(sheet, columns, names)
        end
    end
    return nothing
end

end # module
