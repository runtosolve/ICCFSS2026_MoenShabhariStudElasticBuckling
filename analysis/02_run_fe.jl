# Eigenbuckling of the 96 in 362S162-33 stud with SFIA service holes, braced at midheight.
#   julia --project=. 02_run_fe.jl --model=meshes/stud96_M1_mixed.jls [--brace=corners_x|corners|affine|none] [--Cs_tri=0.2] [--Cs_quad=0.1]
#                                  [--nev=12] [--shifts=14,16,18,20,28,31,34,37,40,43,50,55,60] [--nev_shift=40] [--tag=M1_tri]
# Outputs (results/): modes_<tag>.csv (every mode found + metrics), modes_<tag>.jls (characteristic modes for figures/viewer),
#                     summary_<tag>.txt (model size, timings, characteristic loads)
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Ferrite, LinearAlgebra, SparseArrays, Statistics, Serialization, Printf
const SBT = StudBucklingTools
BLAS.set_num_threads(Sys.CPU_THREADS ÷ 2)
function getopt(name, default)
    i = findfirst(a -> startswith(a, "--$name="), ARGS)
    i === nothing ? default : split(ARGS[i], "=", limit = 2)[2]
end
model_path = abspath(joinpath(@__DIR__, getopt("model", "meshes/stud96_M1_tri.jls")))
brace      = Symbol(getopt("brace", "corners_x"))
nev        = parse(Int, getopt("nev", "12"))
shifts_kN  = parse.(Float64, split(getopt("shifts", "14,16,18,20,28,31,34,37,40,43,50,55,60"), ","))
nev_shift  = parse(Int, getopt("nev_shift", "40"))
E = 200000.0; ν = 0.30
t = 0.0346 * 25.4

m = SBT.load_model(model_path)
Cs_tri  = parse(Float64, getopt("Cs_tri", string(SBT.TSFE.DEFAULT_SHEAR_RELAXATION)))
Cs_quad = parse(Float64, getopt("Cs_quad", string(SBT.QSFE.DEFAULT_SHEAR_RELAXATION)))
Cs = "tri $(Cs_tri), quad $(Cs_quad)"
tag = getopt("tag", m.tag * (brace == :corners_x ? "" : "_$(brace)"))
out = joinpath(@__DIR__, "results")
ntri = count(c -> c isa Ferrite.Triangle, m.grid.cells); nquad = getncells(m.grid) - ntri
println("Model $(m.tag): $(m.element) shells, $(getnnodes(m.grid)) nodes, $(getncells(m.grid)) cells ($(nquad) quadrilaterals, $(ntri) triangles), L = $(m.L) mm, dz = $(round(m.dz; digits = 3)) mm, holes at z = $(m.hole.zc) mm")
println("Shear relaxation Cs = $(Cs); brace = $(brace)")

timing = Dict{String,Float64}()
dh, node_to_dofs = SBT.setup_dofs(m)
println("Dofs: $(ndofs(dh))")
ch = SBT.constraints(m, dh, node_to_dofs; brace)
println("Constraints: $(length(ch.prescribed_dofs)) prescribed dofs")
t0 = time(); K = SBT.assemble_K(m, dh, ch, E, ν, t; Cs_tri, Cs_quad); timing["assemble_K"] = time() - t0
println("Assemble K: $(round(timing["assemble_K"]; digits = 1)) s")
F = SBT.end_loads(m, dh, node_to_dofs)
apply!(K, F, ch)
t0 = time(); u = K \ F; apply!(u, ch); timing["static_solve"] = time() - t0
println("Static solve: $(round(timing["static_solve"]; digits = 1)) s")
A = m.sec.A
shortening = mean(u[node_to_dofs[m.sid[s, 1]][3]] for s in 1:length(m.sec.X)) - mean(u[node_to_dofs[m.sid[s, end]][3]] for s in 1:length(m.sec.X))
println("Axial shortening under P_ref = 1 N: $(shortening) mm  (gross PL/EA = $(m.L / (E * A)) mm)")

t0 = time(); S = SBT.membrane_stresses(m, dh, u, E, ν, t); timing["stresses"] = time() - t0
σzz, xc, yc, zc = SBT.sigma_zz_normalized(m, dh, S, 1.0 / A)
println("\nNormalized σ_zz / (P/A) by element rows (uniform compression = -1.00):")
println("   z range [mm]          min      mean     max     (web elements: min / max)")
for (lo, hi, name) in ((0.0, 2m.dz, "end"), (140.0, 160.0, "bulk"), (m.hole.zc[1] - m.dz, m.hole.zc[1] + m.dz, "hole 1 centre"),
                       (m.hole.zc[1] - 60, m.hole.zc[1] - 50, "hole 1 end"), (m.L/2 - m.dz, m.L/2 + m.dz, "brace"), (m.L - 2m.dz, m.L, "end"))
    idx = findall(lo .<= zc .<= hi); isempty(idx) && continue
    web = idx[xc[idx] .< 0.5]
    @printf("   %6.1f–%6.1f %-13s %7.3f  %7.3f  %7.3f   (%7.3f / %7.3f)\n", lo, hi, name, minimum(σzz[idx]), mean(σzz[idx]), maximum(σzz[idx]),
            isempty(web) ? NaN : minimum(σzz[web]), isempty(web) ? NaN : maximum(σzz[web]))
end

t0 = time(); Kg = SBT.assemble_Kg(m, dh, ch, S, t); timing["assemble_Kg"] = time() - t0
println("Assemble Kg: $(round(timing["assemble_Kg"]; digits = 1)) s")

# ── lowest modes ──
println("\nLowest $(nev) modes:")
λ0, V0, tm = SBT.eigs_lowest(K, Kg; nev)
timing["factorization"] = tm.lu; timing["eigs_lowest"] = tm.eigs
# ── shift-and-invert windows ──
pairs = Any[(λ0, V0)]
t0 = time()
for s in shifts_kN
    λs, Vs = SBT.eigs_shift(K, Kg, s * 1000; nev = nev_shift)
    push!(pairs, (λs, Vs))
end
timing["shift_invert_total"] = time() - t0
λ, Φ = SBT.merge_modes(pairs...)
for k in eachindex(Φ); apply!(Φ[k], ch); end          # recover affine-constrained dofs
println("$(length(λ)) distinct modes between $(round(λ[1]/1000; digits = 3)) and $(round(λ[end]/1000; digits = 3)) kN")

metrics = SBT.classify_modes(m, dh, node_to_dofs, Φ)
SBT.print_modes(λ, metrics; max_local = 10)
SBT.write_modes_csv(joinpath(out, "modes_$(tag).csv"), λ, metrics, A)

# ── characteristic modes ──
first_idx(f) = findfirst(f, eachindex(λ))
# characteristic modes: clean representatives (strict thresholds) plus the first mixed modes for the record
k_local      = first_idx(k -> metrics[k].class == "local")
k_local_hole = first_idx(k -> metrics[k].hole_ratio > 3.0)                                            # clearly localized at a hole
k_local_hole_first = first_idx(k -> metrics[k].class == "local-hole")                                 # first mode the classifier calls local-hole
k_dist       = first_idx(k -> metrics[k].class == "distortional" && metrics[k].fl > 0.85 && metrics[k].hole_ratio < 0.7)   # clean 3-half-wave-per-segment mode
k_dist_mixed = first_idx(k -> metrics[k].class == "distortional")
k_glob       = first_idx(k -> metrics[k].class == "global" && metrics[k].rb_frac > 0.9)
k_glob_mixed = first_idx(k -> metrics[k].class == "global")
k_glob_weak  = first_idx(k -> metrics[k].class == "global" && metrics[k].rb_frac > 0.85 && metrics[k].global_desc == "weak-axis flexure")
sel = [(k_local, "Lowest local"), (k_local_hole, "Local at holes"), (k_local_hole_first, "Local at holes (first classified)"),
       (k_dist, "Lowest distortional"), (k_dist_mixed, "Distortional (mixed, first classified)"),
       (k_glob, "Global 1"), (k_glob_mixed, "Global (mixed, first classified)"), (k_glob_weak, "Global weak-axis")]
sel = [(k, n) for (k, n) in sel if k !== nothing]
keep = unique(vcat([k for (k, _) in sel], 1:min(6, length(λ))))
sort!(keep)
serialize(joinpath(out, "modes_$(tag).jls"),
          (tag = tag, model = basename(model_path), element = m.element, Cs = Cs, Cs_tri = Cs_tri, Cs_quad = Cs_quad, brace = brace, ndofs = ndofs(dh), ntri = ntri, nquad = nquad,
           Pcr = λ[keep], Φ = hcat(Φ[keep]...), metrics = metrics[keep], scan_index = keep,
           characteristic = Dict(n => k for (k, n) in sel), timing = timing, A = A))

open(joinpath(out, "summary_$(tag).txt"), "w") do io
    println(io, "362S162-33 stud, L = 96 in (2438.4 mm), uniform compression, pinned warping-free ends, braced at midheight (Lx = Ly = Lt = 48 in)")
    println(io, "SFIA service holes $(m.hole.w) x $(m.hole.ℓ) mm at z = $(m.hole.zc) mm")
    println(io, "Ferrite.jl + QuadShellFiniteElement.jl ($(nquad) quadrilaterals) + TriShellFiniteElement.jl ($(ntri) triangles); $(getnnodes(m.grid)) nodes, $(getncells(m.grid)) shells, $(ndofs(dh)) dofs, dz = $(round(m.dz; digits = 3)) mm, section nodes = $(length(m.sec.X))")
    println(io, "E = $(E) MPa, ν = $(ν), t = $(t) mm, A = $(A) mm²; Cs = $(Cs); brace = $(brace)")
    println(io, "Timings [s]: " * join(["$(k) = $(round(v; digits = 2))" for (k, v) in sort(collect(timing))], ", "))
    println(io, "\nname, scan_index, Pcr_N, Pcr_kN, Pcr_kips, fcr_MPa, fcr_ksi, class, rb_frac, fl, wf, hole_frac, hole_ratio, hw_web, hw_tip, hw_tip_seg1, hw_tip_seg2, global_description")
    for (k, n) in sel
        mm = metrics[k]
        @printf(io, "%s, %d, %.3f, %.4f, %.4f, %.3f, %.4f, %s, %.3f, %.3f, %.3f, %.3f, %.2f, %d, %d, %d, %d, %s\n", n, k, λ[k], λ[k]/1000, λ[k]/N_PER_KIP, λ[k]/A, λ[k]/A/MPA_PER_KSI,
                mm.class, mm.rb_frac, mm.fl, mm.wf, mm.hole_frac, mm.hole_ratio, mm.hw_web, mm.hw_tip, mm.hw_tip_seg[1], mm.hw_tip_seg[2], mm.global_desc)
    end
end
println("\n══ Characteristic modes ($(tag)) ══")
for (k, n) in sel
    @printf("  %-32s P_cr = %8.3f kN (%6.3f kips), f_cr = %7.2f MPa (%6.2f ksi)  [scan #%d, hole_frac %.2f, hole_ratio %.2f, lip half-waves %d]\n",
            n, λ[k]/1000, λ[k]/N_PER_KIP, λ[k]/A, λ[k]/A/MPA_PER_KSI, k, metrics[k].hole_frac, metrics[k].hole_ratio, metrics[k].hw_tip)
end
println("Saved results/modes_$(tag).csv, modes_$(tag).jls, summary_$(tag).txt")
