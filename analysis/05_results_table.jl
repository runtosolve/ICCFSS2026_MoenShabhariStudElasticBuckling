# Merge the shell FE characteristic modes (all available results/modes_*.jls) with the baselines into
# results/summary_table.csv and a Typst table fragment results/summary_table.typ for the paper.
#   julia --project=. 05_results_table.jl [--tags=M1_mixed,M2_mixed]
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Serialization, Printf

function getopt(name, default)
    i = findfirst(a -> startswith(a, "--$name="), ARGS)
    i === nothing ? default : split(ARGS[i], "=", limit = 2)[2]
end
resdir = joinpath(@__DIR__, "results")
tags = [t for t in split(getopt("tags", "M1_mixed,M2_mixed"), ",") if isfile(joinpath(resdir, "modes_$(t).jls"))]
b = deserialize(joinpath(resdir, "baselines.jls"))
M = Dict(t => deserialize(joinpath(resdir, "modes_$(t).jls")) for t in tags)
# all modes of each run from the CSV (the .jls keeps only a few vectors)
function read_modes(t)
    rows = NamedTuple[]
    for (k, line) in enumerate(eachline(joinpath(resdir, "modes_$(t).csv")))
        k == 1 && continue
        f = strip.(split(line, ","))
        push!(rows, (P = parse(Float64, f[2]) * 1000, class = f[6], rb = parse(Float64, f[7]), wf = parse(Float64, f[8]), fl = parse(Float64, f[9]),
                     hole_frac = parse(Float64, f[11]), ratio = parse(Float64, f[12]), hw_tip = parse(Int, f[14]), seg = (parse(Int, f[15]), parse(Int, f[16])), desc = f[17]))
    end
    return rows
end
R = Dict(t => read_modes(t) for t in tags)
pick(t, f) = (r = findfirst(f, R[t]); r === nothing ? NaN : R[t][r].P)
sel_rules = Dict(
    "Lowest local"          => r -> r.class == "local",
    "Local at holes"        => r -> r.ratio > 3.0,
    "Distortional clean"    => r -> r.class == "distortional" && r.fl > 0.85 && r.ratio < 0.7,
    "Distortional interaction" => r -> r.class == "distortional" && r.fl > 0.75 && r.ratio >= 0.9,
    "Global FT"             => r -> r.class == "global" && r.rb > 0.9,
    "Global weak-axis"      => r -> r.class == "global" && r.rb > 0.85 && r.desc == "weak-axis flexure")
getP(d, name) = haskey(sel_rules, name) ? pick(d.tag, sel_rules[name]) : NaN
c = b["csb_FE-matched"]
rows = [
    ("Local, lowest", "Lowest local", b["cufsm_local"].Pcr, "CUFSM gross-section signature minimum, $(round(Int, b["cufsm_local"].Lcr)) mm"),
    ("Local, gross section (CeeSectionBuckling)", "", c.Pcrl, "CeeSectionBuckling gross, $(round(Int, c.Lcrl)) mm"),
    ("Local at the holes (web strips)", "Local at holes", c.Pcrl_hole, "CeeSectionBuckling net section, $(round(Int, c.Lcrl_hole)) mm"),
    ("Distortional, 3 half-waves per segment", "Distortional clean", c.Pcrd_hole, "AISI S100 reduced web thickness, $(round(Int, c.Lcrd_hole)) mm"),
    ("Distortional, gross", "", c.Pcrd, "CeeSectionBuckling gross, $(round(Int, c.Lcrd)) mm; CUFSM at L/3 = 406 mm: $(round(b["cufsm_48in_m3"]/1000; digits = 2)) kN"),
    ("Distortional–hole interaction, 5 half-waves per segment", "Distortional interaction", NaN, "no finite strip counterpart"),
    ("Global, flexural-torsional", "Global FT", b["global_gross"].PFT, "analytical, gross section, KL = 1219 mm"),
    ("Global, weighted-average net", "", b["global_hole"].PFT, "analytical, AISI S100 weighted-average net properties"),
    ("Global, weak-axis flexure", "Global weak-axis", b["global_gross"].Pey, "analytical weak-axis flexure, gross"),
]
fmt(P) = isnan(P) ? "–" : @sprintf("%.2f (%.2f)", P/1000, P/N_PER_KIP)
fmtint(n) = (d = string(n); join([d[max(1, k-2):k] for k in length(d):-3:1] |> reverse, " "))
open(joinpath(resdir, "summary_table.csv"), "w") do io
    print(io, "mode"); for t in tags; print(io, ", $(t) kN, $(t) kips"); end; println(io, ", baseline kN, baseline kips, baseline note")
    for (name, key, Pb, note) in rows
        print(io, name)
        for t in tags
            P = key == "" ? NaN : getP(M[t], key)
            isnan(P) ? print(io, ", , ") : @printf(io, ", %.3f, %.3f", P/1000, P/N_PER_KIP)
        end
        isnan(Pb) ? print(io, ", , , $(note)\n") : @printf(io, ", %.3f, %.3f, %s\n", Pb/1000, Pb/N_PER_KIP, note)
    end
    println(io, "\nmodel, element, dofs, cells, assemble_K_s, static_solve_s, assemble_Kg_s, factorization_s, eigs_lowest_s, shift_invert_total_s")
    for t in tags
        d = M[t]; tm = d.timing
        @printf(io, "%s, %s, %d, , %.1f, %.1f, %.1f, %.1f, %.1f, %.1f\n", t, d.element, d.ndofs, tm["assemble_K"], tm["static_solve"], tm["assemble_Kg"], tm["factorization"], tm["eigs_lowest"], tm["shift_invert_total"])
    end
end
# Typst fragment
open(joinpath(resdir, "summary_table.typ"), "w") do io
    ncol = 2 + length(tags)
    println(io, "#table(")
    println(io, "  columns: (1.6fr, " * join(fill("1fr", length(tags)), ", ") * ", 1fr),")
    println(io, "  align: (left, " * join(fill("center", length(tags)), ", ") * ", center),")
    heads = ["[*Buckling mode*]"; ["[*shell FE, $(startswith(t, "M1") ? "5 mm" : "2.5 mm") mesh* \\ kN (kips)]" for t in tags]; "[*Finite strip / analytical* \\ kN (kips)]"]
    println(io, "  " * join(heads, ", ") * ",")
    for (name, key, Pb, note) in rows
        cells = ["[$(name)]"; ["[$(key == "" ? "–" : fmt(getP(M[t], key)))]" for t in tags]; "[$(fmt(Pb))]"]
        println(io, "  " * join(cells, ", ") * ",")
    end
    println(io, ")")
end
# timing table (Typst)
open(joinpath(resdir, "timing_table.typ"), "w") do io
    println(io, "#table(")
    println(io, "  columns: (1.4fr, " * join(fill("1fr", length(tags)), ", ") * "),")
    println(io, "  align: (left, " * join(fill("center", length(tags)), ", ") * "),")
    println(io, "  [*Step*], " * join(["[*$(startswith(t, "M1") ? "5 mm" : "2.5 mm") mesh*]" for t in tags], ", ") * ",")
    println(io, "  [Degrees of freedom], " * join(["[$(fmtint(M[t].ndofs))]" for t in tags], ", ") * ",")
    for (label, key) in (("Assemble elastic stiffness", "assemble_K"), ("Static solve", "static_solve"), ("Membrane stresses", "stresses"), ("Assemble geometric stiffness", "assemble_Kg"),
                         ("Cholesky factorization of K", "factorization"), ("12 lowest modes (ARPACK)", "eigs_lowest"), ("13 shift-and-invert windows, 40 modes each", "shift_invert_total"))
        println(io, "  [$(label)], " * join(["[$(@sprintf("%.0f", M[t].timing[key]))]" for t in tags], ", ") * ",")
    end
    println(io, ")")
end
println("Tags: ", tags)
for (name, key, Pb, note) in rows
    print(rpad(name, 32)); for t in tags; print(rpad(key == "" ? "–" : fmt(getP(M[t], key)), 18)); end; println(rpad(fmt(Pb), 18), note)
end
