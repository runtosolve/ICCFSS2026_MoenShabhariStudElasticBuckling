# Standalone browser viewer (Bonito + WGLMakie) of the characteristic buckling modes for the tri and quad models.
#   julia --project=. 06_viewer_export.jl [--tags=M1_mixed] [--out=../viewer/index.html] [--amp=0.25]
# Each mode gets its own 3D figure with an amplitude slider (-1 … 1 × amp × section size); drag to orbit, scroll to zoom.
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, Ferrite, Serialization, Statistics, LinearAlgebra, Printf
using WGLMakie, Bonito
const SBT = StudBucklingTools
WGLMakie.activate!()
function getopt(name, default)
    i = findfirst(a -> startswith(a, "--$name="), ARGS)
    i === nothing ? default : split(ARGS[i], "=", limit = 2)[2]
end
tags = split(getopt("tags", "M1_mixed"), ",")
out_html = abspath(joinpath(@__DIR__, getopt("out", "../viewer/index.html")))
amp = parse(Float64, getopt("amp", "0.25"))
resdir = joinpath(@__DIR__, "results")
b = deserialize(joinpath(resdir, "baselines.jls"))
mode_names = ["Lowest local", "Local at holes", "Lowest distortional", "Global 1"]

blocks = Any[]
rows = Any[]
for tg in tags
    modes = deserialize(joinpath(resdir, "modes_$(tg).jls"))
    m = SBT.load_model(joinpath(@__DIR__, "meshes", modes.model))
    dh, n2d = SBT.setup_dofs(m)
    xs, ys, zs = SBT.nodes_xyz(m); nn = length(xs)
    sec_size = maximum(ys) - minimum(ys)
    F = SBT.face_matrix(m)
    X0 = [Point3f(zs[i], xs[i], ys[i]) for i in 1:nn]           # column axis horizontal
    elname = "$(startswith(tg, "M1") ? "5 mm" : "2.5 mm") mesh"
    push!(blocks, DOM.h2("$(elname): $(getnnodes(m.grid)) nodes, $(modes.nquad) quadrilaterals + $(modes.ntri) triangles, $(ndofs(dh)) dofs"))
    for name in mode_names
        haskey(modes.characteristic, name) || continue
        j = findfirst(==(modes.characteristic[name]), modes.scan_index)
        P = modes.Pcr[j]; vec = modes.Φ[:, j]; mm = modes.metrics[j]
        d = [Point3f(vec[n2d[i][3]], vec[n2d[i][1]], vec[n2d[i][2]]) for i in 1:nn]
        mag = norm.(d); mx = maximum(mag)
        sgn = sign(d[argmax(mag)][2]); sgn == 0 && (sgn = 1f0)
        d .*= Float32(amp * sec_size / mx * sgn); mag ./= mx
        lbl = @sprintf("%s: P_cr = %.2f kN (%.2f kips), f_cr = %.1f MPa (%.2f ksi)%s", name, P/1000, P/N_PER_KIP, P/modes.A, P/modes.A/MPA_PER_KSI,
                       mm.class == "global" ? " — " * mm.global_desc : @sprintf(" — lip half-waves per 48 in: %d / %d", mm.hw_tip_seg...))
        push!(rows, (elname, name, P, mm))
        pos = [X0[i] + d[i] for i in 1:nn]                       # static deformed shape (amplitude = amp × section depth) keeps the page small
        fig = Figure(size = (1000, 360))
        ax = LScene(fig[1, 1]; show_axis = false)
        mesh!(ax, pos, F; color = Float32.(mag), colormap = :viridis, colorrange = (0f0, 1f0), shading = NoShading)
        cam = cameracontrols(ax.scene)
        center = Vec3f(m.L / 2, mean(xs), mean(ys))
        update_cam!(ax.scene, cam, center + Vec3f(-0.45m.L, -1.1m.L, 0.35m.L), center)
        push!(blocks, DOM.div(DOM.h3(lbl), fig; style = "margin-bottom: 20px;"))
    end
end
header = DOM.div(
    DOM.h1("362S162-33 stud column with SFIA service holes — elastic buckling modes"),
    DOM.p("L = 96 in (2438 mm), uniform compression, pinned warping-free ends, braced at midheight (Lx = Ly = Lt = 48 in); 1.5 × 4 in holes at 12, 36, 60, 84 in. " *
          "Ferrite.jl with QuadShellFiniteElement.jl in the structured flats and TriShellFiniteElement.jl in the patches around the holes. Companion to Moen and Shabhari, ICCFSS 2026."; style = "color:#444;"),
    DOM.p(@sprintf("Reference values: CUFSM gross local %.2f kN, distortional %.2f kN; net-section local %.2f kN; reduced-thickness distortional %.2f kN; analytical flexural-torsional (KL = 48 in) %.2f kN.",
                   b["cufsm_local"].Pcr/1000, b["cufsm_dist"].Pcr/1000, b["csb_FE-matched"].Pcrl_hole/1000, b["csb_FE-matched"].Pcrd_hole/1000, b["global_gross"].PFT/1000); style = "color:#444; font-size: 13px;"),
    DOM.p("Drag in a plot to orbit, scroll to zoom, right-drag to pan. Colour = normalized displacement magnitude; deformation scaled to $(amp) × section depth. The Pluto notebook in the repository adds an amplitude slider and a live solve."; style = "color:#666; font-size: 13px;"))
table = DOM.table(DOM.thead(DOM.tr(DOM.th("model"), DOM.th("mode"), DOM.th("P_cr [kN]"), DOM.th("P_cr [kips]"), DOM.th("class"), DOM.th("rigid-body fraction"))),
                  DOM.tbody([DOM.tr(DOM.td(r[1]), DOM.td(r[2]), DOM.td(@sprintf("%.2f", r[3]/1000)), DOM.td(@sprintf("%.2f", r[3]/N_PER_KIP)), DOM.td(r[4].class), DOM.td(@sprintf("%.2f", r[4].rb_frac))) for r in rows]...);
                  style = "border-collapse: collapse; font-family: monospace; font-size: 13px; margin: 12px 0;")
css = DOM.style("table td, table th { padding: 2px 12px; text-align: right; border-bottom: 1px solid #ddd; } table td:first-child, table td:nth-child(2) { text-align: left; }")
app = App() do session
    dom = DOM.div(css, header, table, blocks...; style = "font-family: Helvetica, Arial, sans-serif; margin: 0 16px; max-width: 1100px;")
    return dom
end
tmp = joinpath(mktempdir(), "index.html")
Bonito.export_static(tmp, app)
mkpath(dirname(out_html)); cp(tmp, out_html; force = true)
println("Wrote $(out_html) ($(round(filesize(out_html)/1e6; digits = 1)) MB)")
