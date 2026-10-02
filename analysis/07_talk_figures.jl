# Talk figure: the lowest global mode over the FULL 96 in member (5 mm mesh), for presentation/deck/data/fig_mode_global_full.png
#   julia --project=. 07_talk_figures.jl
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Ferrite, CairoMakie, Serialization, Statistics, LinearAlgebra, Printf
const SBT = StudBucklingTools
CairoMakie.activate!(type = "png")
set_theme!(fontsize = 8, font = "Arial", figure_padding = 2)
resdir = joinpath(@__DIR__, "results")
modes = deserialize(joinpath(resdir, "modes_M1_mixed.jls"))
m = SBT.load_model(joinpath(@__DIR__, "meshes", modes.model))
dh, n2d = SBT.setup_dofs(m)
struct Loaded; m::StudModel; dh; n2d; modes; end
ld = Loaded(m, dh, n2d, modes)
mode_vec(ld, name) = (k = ld.modes.characteristic[name]; j = findfirst(==(k), ld.modes.scan_index); (ld.modes.Pcr[j], ld.modes.Φ[:, j], ld.modes.metrics[j]))
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

P, vec, mm = mode_vec(ld, "Global 1")
fig = Figure(size = (540.0, 105))
ax = mode_axis(fig, (1, 1); title = @sprintf("5 mm mesh, %.2f kN (%.2f kips), full 96 in member, brace at midheight (z = 48 in)", P/1000, P/SBT.N_PER_KIP), azimuth = -0.5π + 0.25, elevation = 0.15)
draw_mode!(ax, ld, vec; amp = 0.6)
# mark the brace plane
_, _, zs = SBT.nodes_xyz(m)
out = joinpath(@__DIR__, "..", "..", "presentation", "deck", "data", "fig_mode_global_full.png")
save(out, fig; px_per_unit = 4); println("saved ", normpath(out))
