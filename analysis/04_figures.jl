# Paper figures (CairoMakie): mesh close-up at a hole, characteristic buckling modes (tri and quad),
# pre-buckling stress around a hole, CUFSM signature curve with all baseline and FE values.
#   julia --project=. 04_figures.jl [--tags=M1_mixed,M2_mixed] [--stress]
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Ferrite, CairoMakie, Serialization, Statistics, LinearAlgebra, Printf
const SBT = StudBucklingTools
CairoMakie.activate!(type = "png")
function getopt(name, default)
    i = findfirst(a -> startswith(a, "--$name="), ARGS)
    i === nothing ? default : split(ARGS[i], "=", limit = 2)[2]
end
tags = split(getopt("tags", "M1_mixed,M2_mixed"), ",")
tags = [t for t in tags if isfile(joinpath(@__DIR__, "results", "modes_$(t).jls"))]
row_label(tag) = startswith(tag, "M1") ? "5 mm mesh" : startswith(tag, "M2") ? "2.5 mm mesh" : tag
figdir = joinpath(@__DIR__, "figures"); resdir = joinpath(@__DIR__, "results")
alt = String[]
const PT_COL = 252.0      # single column width  3.5 in in pt
const PT_FULL = 540.0     # full text width       7.5 in in pt
set_theme!(fontsize = 8, font = "Arial", figure_padding = 2)
savefig(name, fig) = (save(joinpath(figdir, name * ".png"), fig; px_per_unit = 4); save(joinpath(figdir, name * ".pdf"), fig; pt_per_unit = 1))

# ── load models, dofs, modes ──────────────────────────────────────────────────
struct Loaded; m::StudModel; dh; n2d; modes; end
loaded = Dict{String,Loaded}()
for tg in tags
    modes = deserialize(joinpath(resdir, "modes_$(tg).jls"))
    m = SBT.load_model(joinpath(@__DIR__, "meshes", modes.model))
    dh, n2d = SBT.setup_dofs(m)
    @assert ndofs(dh) == modes.ndofs
    loaded[tg] = Loaded(m, dh, n2d, modes)
    println("$(tg): $(getncells(m.grid)) cells ($(m.element)), modes: ", join(["$(k) = $(round(modes.Pcr[findfirst(==(v), modes.scan_index)]/1000; digits = 2)) kN" for (k, v) in modes.characteristic], "; "))
end
mode_vec(ld, name) = (k = ld.modes.characteristic[name]; j = findfirst(==(k), ld.modes.scan_index); (ld.modes.Pcr[j], ld.modes.Φ[:, j], ld.modes.metrics[j]))
has_mode(ld, name) = haskey(ld.modes.characteristic, name)

# ── Figure 1: cross-section discretization and the web mesh at a hole (tri, quad) ─
function web_edges(m::StudModel, zlo, zhi)
    xs, ys, zs = SBT.nodes_xyz(m)
    segs = Point2f[]
    for (a, b) in SBT.edge_list(m)
        (xs[a] < 0.5 && xs[b] < 0.5 && zlo <= zs[a] <= zhi && zlo <= zs[b] <= zhi) || continue
        push!(segs, Point2f(zs[a], ys[a])); push!(segs, Point2f(zs[b], ys[b]))
    end
    return segs
end
let
    fig = Figure(size = (PT_FULL, 150))
    m1 = loaded[tags[1]].m
    ax0 = Axis(fig[1, 1]; aspect = DataAspect(), title = "(a) cross-section, $(length(m1.sec.X)) nodes", xlabel = "x [mm]", ylabel = "y [mm]")
    lines!(ax0, m1.sec.X, m1.sec.Y; color = :black, linewidth = 0.8)
    scatter!(ax0, m1.sec.X, m1.sec.Y; markersize = 3, color = :steelblue)
    zc = m1.hole.zc[1]
    ax = Axis(fig[1, 2]; aspect = DataAspect(), title = "(b) web face at a hole: structured quadrilaterals, triangular patch", xlabel = "z [mm]", ylabel = "y [mm]")
    linesegments!(ax, web_edges(m1, zc - 120, zc + 120); color = :black, linewidth = 0.3)
    xlims!(ax, zc - 120, zc + 120)
    colsize!(fig.layout, 1, Auto(0.3))
    savefig("fig_mesh_hole", fig)
    push!(alt, "fig_mesh_hole: (a) the 85-node centerline polyline of the 362S162-33 section with rounded corners; (b) the web face around one 38 by 102 mm stadium-shaped service hole, with structured quadrilateral strips outside the 150 mm patch and an unstructured triangular patch around the hole.")
end

# ── Figures 2–4: characteristic modes (column axis horizontal) ───────────────
"Deformed vertices in plot coordinates (z, x, y) so the column runs left to right."
function deformed_points(ld::Loaded, vec; amp = 0.25)
    m = ld.m; xs, ys, zs = SBT.nodes_xyz(m); nn = length(xs)
    d = [Point3f(vec[ld.n2d[i][1]], vec[ld.n2d[i][2]], vec[ld.n2d[i][3]]) for i in 1:nn]
    mag = norm.(d); mx = maximum(mag)
    sgn = sign(d[argmax(mag)][1]); sgn == 0 && (sgn = 1f0)
    sec_size = maximum(ys) - minimum(ys)
    s = Float32(amp * sec_size / mx * sgn)
    pts = [Point3f(zs[i] + s * d[i][3], xs[i] + s * d[i][1], ys[i] + s * d[i][2]) for i in 1:nn]
    return pts, Float32.(mag ./ mx)
end
function draw_mode!(ax, ld::Loaded, vec; amp = 0.25, zwin = nothing, wire = false)
    pts, mag = deformed_points(ld, vec; amp)
    F = SBT.face_matrix(ld.m)
    _, _, zs = SBT.nodes_xyz(ld.m)
    if zwin !== nothing
        keep = [all(zwin[1] - 1 <= zs[F[r, c]] <= zwin[2] + 1 for c in 1:3) for r in axes(F, 1)]
        F = F[keep, :]
    end
    used = falses(length(pts)); for v in F; used[v] = true; end
    newid = cumsum(used)
    F2 = newid[F]
    pts2 = pts[used]; mag2 = mag[used]
    mesh!(ax, pts2, F2; color = mag2, colormap = :viridis, colorrange = (0, 1), shading = NoShading)
    if wire
        segs = Point3f[]
        for (a, b) in SBT.edge_list(ld.m)
            (used[a] && used[b]) || continue
            push!(segs, pts[a]); push!(segs, pts[b])
        end
        linesegments!(ax, segs; color = (:black, 0.25), linewidth = 0.2)
    end
end
function mode_axis(fig, pos; title = "", azimuth = -0.5π + 0.25, elevation = 0.18)
    Label(fig[pos..., Top()], title; fontsize = 8, padding = (0, 0, 2, 0))
    ax = Axis3(fig[pos...]; aspect = :data, azimuth, elevation, viewmode = :fitzoom, perspectiveness = 0.0, protrusions = 0)
    hidedecorations!(ax); hidespines!(ax)
    return ax
end
function zwindow_of_max(ld::Loaded, vec; half = 230.0)
    _, _, zs = SBT.nodes_xyz(ld.m)
    nn = length(zs)
    mag = [hypot(vec[ld.n2d[i][1]], vec[ld.n2d[i][2]], vec[ld.n2d[i][3]]) for i in 1:nn]
    zc = zs[argmax(mag)]
    lo = clamp(zc - half, 0, ld.m.L - 2half)
    return (lo, lo + 2half)
end
labelP(P, mm) = @sprintf("%.2f kN (%.2f kips)", P/1000, P/N_PER_KIP)

# local mode close-up (single column): tri and quad stacked
let
    fig = Figure(size = (PT_COL, 175))
    for (j, tg) in enumerate(tags)
        ld = loaded[tg]; has_mode(ld, "Lowest local") || continue
        P, vec, mm = mode_vec(ld, "Lowest local")
        zw = zwindow_of_max(ld, vec)
        ax = mode_axis(fig, (j, 1); title = "$(row_label(tg)), " * labelP(P, mm) * @sprintf(", z = %.0f–%.0f mm", zw...), azimuth = -0.5π + 0.25, elevation = 0.18)
        draw_mode!(ax, ld, vec; amp = 0.2, zwin = zw, wire = true)
    end
    savefig("fig_mode_local", fig)
    push!(alt, "fig_mode_local: close-up of the lowest local buckling mode of the stud with the 5 mm mesh (top) and the 2.5 mm mesh (bottom); short half-wave web buckles between the holes, colored by displacement magnitude.")
end
# local buckling at the holes (web strips beside a hole), close-up: tri and quad stacked
let
    fig = Figure(size = (PT_COL, 175))
    for (j, tg) in enumerate(tags)
        ld = loaded[tg]; has_mode(ld, "Local at holes") || continue
        P, vec, mm = mode_vec(ld, "Local at holes")
        zw = zwindow_of_max(ld, vec)
        ax = mode_axis(fig, (j, 1); title = "$(row_label(tg)), " * labelP(P, mm) * @sprintf(", z = %.0f–%.0f mm", zw...), azimuth = -0.5π + 0.25, elevation = 0.18)
        draw_mode!(ax, ld, vec; amp = 0.2, zwin = zw, wire = true)
    end
    savefig("fig_mode_local_hole", fig)
    push!(alt, "fig_mode_local_hole: close-up of the lowest buckling mode localized at a service hole with the 5 mm mesh (top) and the 2.5 mm mesh (bottom); the two web strips beside the hole bow out of plane, colored by displacement magnitude.")
end
# distortional and global modes, one 48 in braced segment (full width): tri and quad stacked
for (name, fname, desc) in (("Lowest distortional", "fig_mode_distortional", "distortional"), ("Global 1", "fig_mode_global", "global"))
    fig = Figure(size = (PT_FULL, 160))
    for (j, tg) in enumerate(tags)
        ld = loaded[tg]; has_mode(ld, name) || continue
        P, vec, mm = mode_vec(ld, name)
        extra = desc == "global" ? " — $(mm.global_desc)" : @sprintf(" — %d lip half-waves per segment", mm.hw_tip_seg[1])
        ax = mode_axis(fig, (j, 1); title = "$(row_label(tg)), " * labelP(P, mm) * extra, azimuth = -0.5π + 0.25, elevation = 0.15)
        draw_mode!(ax, ld, vec; amp = desc == "global" ? 0.6 : 0.35, zwin = (0.0, ld.m.L / 2))
    end
    savefig(fname, fig)
    push!(alt, "$(fname): the lowest $(desc) buckling mode over the lower 48 inch braced segment of the stud with the 5 mm mesh (top) and the 2.5 mm mesh (bottom), column axis horizontal, deformation exaggerated and colored by displacement magnitude.")
end

# ── Figure 5: signature curve with baselines and shell FE values ─────────────
let
    b = deserialize(joinpath(resdir, "baselines.jls"))
    A = b["A"]
    fig = Figure(size = (PT_COL, 240))
    ax = Axis(fig[1, 1]; xscale = log10, xlabel = "half-wavelength [mm]", ylabel = "P_cr [kN]", xticks = ([20, 50, 100, 200, 500, 1000, 2500], ["20", "50", "100", "200", "500", "1000", "2500"]))
    lines!(ax, b["sig_L"], b["sig_fcr"] .* A ./ 1000; color = :black, linewidth = 1, label = "CUFSM, gross section")
    c = b["csb_FE-matched"]
    scatter!(ax, [c.Lcrl, c.Lcrd], [c.Pcrl, c.Pcrd] ./ 1000; marker = :circle, markersize = 7, color = :black, label = "gross local and distortional minima")
    scatter!(ax, [c.Lcrl_hole], [c.Pcrl_hole] ./ 1000; marker = :utriangle, markersize = 8, color = :firebrick, label = "net-section local (hole)")
    scatter!(ax, [c.Lcrd_hole], [c.Pcrd_hole] ./ 1000; marker = :dtriangle, markersize = 8, color = :firebrick, label = "reduced-t distortional (hole)")
    scatter!(ax, [1219.2], [b["global_gross"].PFT] ./ 1000; marker = :diamond, markersize = 8, color = :black, label = "flexural-torsional, KL = 48 in")
    scatter!(ax, [1219.2], [b["global_hole"].PFT] ./ 1000; marker = :diamond, markersize = 8, color = :firebrick, label = "flexural-torsional, net properties")
    cols = Dict("M1" => :royalblue, "M2" => :darkorange)
    for tg in tags
        ld = loaded[tg]; el = tg[1:2]
        xs_ = Float64[]; ys_ = Float64[]
        for (name, hw) in (("Lowest local", :local), ("Local at holes", :hole), ("Lowest distortional", :dist), ("Global 1", :glob))
            has_mode(ld, name) || continue
            P, vec, mm = mode_vec(ld, name)
            Lhw = hw == :local ? c.Lcrl : hw == :hole ? c.Lcrl_hole :
                  hw == :dist  ? (mm.hw_tip_seg[1] > 0 ? ld.m.L / 2 / mm.hw_tip_seg[1] : c.Lcrd) : 1219.2
            push!(xs_, Lhw); push!(ys_, P / 1000)
        end
        scatter!(ax, xs_, ys_; marker = el == "M1" ? :rect : :xcross, markersize = 8, color = get(cols, el, :gray), strokewidth = 0.5,
                 label = "shell FE, $(row_label(tg))")
    end
    ylims!(ax, 0, 80); xlims!(ax, 20, 2600)
    Legend(fig[2, 1], ax; labelsize = 6.5, framevisible = false, nbanks = 2, rowgap = 2, colgap = 8, patchsize = (8, 8), tellwidth = false, tellheight = true, orientation = :vertical)
    savefig("fig_signature_curve", fig)
    push!(alt, "fig_signature_curve: CUFSM finite strip signature curve of the gross 362S162-33 section (critical load versus half-wavelength) with markers for the local and distortional minima, the net-section and reduced-thickness hole values, the analytical global load at 48 in, and the shell finite element results for the perforated stud with the 5 mm and 2.5 mm meshes.")
end

# ── Figure 6 (optional, --stress): pre-buckling σ_zz around a hole (tri model, recomputed) ─
if "--stress" in ARGS
    ld = loaded[tags[1]]; m = ld.m
    E = 200000.0; ν = 0.3; t = m.sec.t
    ch = SBT.constraints(m, ld.dh, ld.n2d; brace = ld.modes.brace)
    K = SBT.assemble_K(m, ld.dh, ch, E, ν, t)
    F = SBT.end_loads(m, ld.dh, ld.n2d); apply!(K, F, ch); u = K \ F; apply!(u, ch)
    S = SBT.membrane_stresses(m, ld.dh, u, E, ν, t)
    σzz, xc, yc, zc = SBT.sigma_zz_normalized(m, ld.dh, S, 1.0 / m.sec.A)
    z0 = m.hole.zc[1]
    xs, ys, zs = SBT.nodes_xyz(m)
    fig = Figure(size = (PT_COL, 120))
    ax = Axis(fig[1, 1]; aspect = DataAspect(), xlabel = "z [mm]", ylabel = "y [mm]", title = "σ_zz / (P/A) on the web face")
    polys = Vector{Point2f}[]; cols = Float64[]
    for (c, cell) in enumerate(m.grid.cells)
        (xc[c] < 0.5 && z0 - 120 <= zc[c] <= z0 + 120) || continue
        push!(polys, [Point2f(zs[q], ys[q]) for q in cell.nodes]); push!(cols, -σzz[c])
    end
    poly!(ax, polys; color = cols, colormap = :viridis, colorrange = (0, 2), strokewidth = 0)
    Colorbar(fig[1, 2], limits = (0, 2), colormap = :viridis, label = "compression / (P/A)", width = 6)
    xlims!(ax, z0 - 120, z0 + 120)
    savefig("fig_stress_hole", fig)
    push!(alt, "fig_stress_hole: normalized longitudinal compressive membrane stress on the web face around a service hole under the unit reference load, showing the stress flowing around the hole into the web strips beside it and the flanges, with values near 1.0 away from the hole.")
end

open(joinpath(figdir, "alt_text.md"), "w") do io
    for a in alt; println(io, "- ", a); end
end
println("Figures written to $(figdir)")
