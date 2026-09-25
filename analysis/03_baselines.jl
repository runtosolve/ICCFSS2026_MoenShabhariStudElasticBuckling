# Baseline elastic buckling values for the 362S162-33 stud (N, mm):
#   (a) CUFSM.jl signature curve of the gross section (same centerline polyline as the shell models)
#   (b) CeeSectionBuckling.jl: Pcrl, Pcrd gross; Pcrl,hole (net-section CUFSM, Moen & Schafer) and
#       Pcrd,hole (AISI S100 Appendix 2 reduced web thickness) — the RunToSolve MRI / Scottsdale procedure
#   (c) classical global buckling for Lx = Ly = Lt = 48 in, gross and AISI S100 weighted-average net properties
#   julia --project=. 03_baselines.jl
include(joinpath(@__DIR__, "stud_buckling_tools.jl"))
using .StudBucklingTools, CUFSM, CeeSectionBuckling, SectionProperties, BucklingModeIdentification, Printf, Serialization, Statistics
const CSB = CeeSectionBuckling
E = 200000.0; ν = 0.30; G = E / (2(1 + ν)); t = 0.0346 * 25.4
L_col = 96 * 25.4; L_br = 48 * 25.4
hole_w = 1.5 * 25.4; hole_ℓ = 4.0 * 25.4; hole_spacing = 24 * 25.4
n_holes = 4; L_h_total = n_holes * hole_ℓ
out = joinpath(@__DIR__, "results")
res = Dict{String,Any}()

# ── (a) CUFSM signature curve, gross section, unit reference stress ───────────
sec = section_362S162_33(; k = 2)
X, Y = sec.X, sec.Y; ns = length(X); A = sec.A
node = hcat(1:ns, X, Y, ones(ns), ones(ns), ones(ns), ones(ns), ones(ns))            # [# x y dofx dofy dofz dofq stress=1 MPa]
elem = hcat(1:ns-1, 1:ns-1, 2:ns, fill(t, ns-1), fill(100.0, ns-1))
prop = [100.0 E E ν ν G]
sig_L = collect(20.0:5.0:2500.0)
t0 = time()
curve, _ = CUFSM.strip(prop, node, elem, sig_L, [], [], 2)
fcr = [curve[i][1, 2] for i in eachindex(sig_L)]
println("CUFSM signature curve: $(length(sig_L)) half-wavelengths in $(round(time() - t0; digits = 1)) s")
open(joinpath(out, "cufsm_signature.csv"), "w") do io
    println(io, "half_wavelength_mm, fcr_MPa, Pcr_kN")
    for i in eachindex(sig_L); @printf(io, "%.1f, %.4f, %.5f\n", sig_L[i], fcr[i], fcr[i] * A / 1000); end
end
minima = [i for i in 2:length(fcr)-1 if fcr[i] < fcr[i-1] && fcr[i] < fcr[i+1]]
for i in minima
    @printf("  signature minimum at %.0f mm: f_cr = %.3f MPa, P_cr = %.3f kN (%.3f kips)\n", sig_L[i], fcr[i], fcr[i]*A/1000, fcr[i]*A/N_PER_KIP)
end
res["cufsm_local"] = (Lcr = sig_L[minima[1]], Pcr = fcr[minima[1]] * A)
res["cufsm_dist"]  = (Lcr = sig_L[minima[2]], Pcr = fcr[minima[2]] * A)
# S-S member of length 48 in: minimum over half-wave numbers m of the single-half-wave curve at L_br/m
Lm = [L_br / m for m in 1:60]
cm, _ = CUFSM.strip(prop, node, elem, Lm, [], [], 2)
fm = [cm[i][1, 2] for i in eachindex(Lm)]
res["cufsm_48in"] = (m = collect(1:60), L = Lm, Pcr = fm .* A)
@printf("  CUFSM S-S 48 in: m = 1 (global): %.3f kN; minimum over m: %.3f kN at m = %d\n", fm[1]*A/1000, minimum(fm)*A/1000, argmin(fm))
# distortional at 48 in: m = 2 and 3 half-waves (Lcrd ≈ 460 mm)
res["cufsm_48in_m2"] = fm[2] * A; res["cufsm_48in_m3"] = fm[3] * A
@printf("  CUFSM at L/2 = %.1f mm: %.3f kN; at L/3 = %.1f mm: %.3f kN\n", Lm[2], fm[2]*A/1000, Lm[3], fm[3]*A/1000)
res["A"] = A; res["sig_L"] = sig_L; res["sig_fcr"] = fcr

# ── (b) CeeSectionBuckling: gross and hole values (MRI / Scottsdale procedure) ──
mat = CSB.Material(E, ν)
r_fe = 1.3634 - t / 2                 # inside radius matching the shell-model centerline corner radius (tangent length 1.3634 mm)
r_sfia = 2.82194                      # SFIA design inside radius, 33 mil
for (label, r_in) in (("FE-matched", r_fe), ("SFIA", r_sfia))
    dims = CSB.Dimensions(t, 12.7, 41.3, 92.1, r_in)
    local t0 = time()
    Pl  = CSB.calculate_Pcrℓ(dims, mat)
    Pd  = CSB.calculate_Pcrd(dims, mat)
    Plh = CSB.calculate_Pcrℓ_net_section(dims, mat, hole_w)
    Pdh = CSB.calculate_Pcrd_net_section(dims, mat, hole_ℓ)
    println("\nCeeSectionBuckling ($(label) inside radius r = $(round(r_in; digits = 3)) mm), $(round(time() - t0; digits = 1)) s:")
    for (nm, S) in (("Pcrl gross", Pl), ("Pcrd gross", Pd), ("Pcrl,hole (net section)", Plh), ("Pcrd,hole (reduced tr)", Pdh))
        R = S.results
        meth = R.identification === nothing ? "" : string(R.identification.method)
        @printf("  %-26s Rcr = %10.3f N = %7.3f kN (%6.3f kips), Lcr = %7.1f mm  [%s]\n", nm, R.Rcr, R.Rcr/1000, R.Rcr/N_PER_KIP, R.Lcr, meth)
    end
    res["csb_$(label)"] = (r = r_in,
        Pcrl = Pl.results.Rcr, Lcrl = Pl.results.Lcr, Pcrd = Pd.results.Rcr, Lcrd = Pd.results.Lcr,
        Pcrl_hole = Plh.results.Rcr, Lcrl_hole = Plh.results.Lcr, Pcrd_hole = Pdh.results.Rcr, Lcrd_hole = Pdh.results.Lcr,
        sweep_gross_L = Pl.results.identification.lengths, sweep_gross_R = Pl.results.identification.curve,
        sweep_net_L = Plh.results.identification.lengths, sweep_net_R = Plh.results.identification.curve,
        sweep_d_L = Pd.results.identification.lengths, sweep_d_R = Pd.results.identification.curve)
    if label == "FE-matched"
        # reduced web thickness per AISI S100 Appendix 2 (tr = t (1 - Lh/Lcrd)^(1/3)), reported for the paper
        Lcrd = Pd.results.Lcr
        res["tr"] = t * (1 - hole_ℓ / Lcrd)^(1/3)
        @printf("  reduced web thickness tr = %.4f mm (t = %.4f, Lh = %.1f, Lcrd = %.1f)\n", res["tr"], t, hole_ℓ, Lcrd)
    end
end

# ── (c) Classical global buckling, Lx = Ly = Lt = 48 in ───────────────────────
function global_loads(sp, Lx, Ly, Lt)
    A = sp.A; Ixx = sp.Ixx; Iyy = sp.Iyy; J = sp.J; Cw = sp.Cw
    xo = sp.xs - sp.xc; yo = sp.ys - sp.yc
    ro2 = xo^2 + yo^2 + (Ixx + Iyy) / A
    Pex = π^2 * E * Ixx / Lx^2; Pey = π^2 * E * Iyy / Ly^2       # Ixx: bending about the horizontal axis (deflection in y, along the web); Iyy: deflection in x
    Pt  = (G * J + π^2 * E * Cw / Lt^2) / ro2
    Psym, Pother, o = abs(yo) < abs(xo) ? (Pex, Pey, xo) : (Pey, Pex, yo)   # symmetry axis is horizontal (yo ≈ 0): torsion couples with Pex
    β = 1 - o^2 / ro2
    PFT = ((Psym + Pt) - sqrt((Psym + Pt)^2 - 4β * Psym * Pt)) / (2β)
    return (; A, Ixx, Iyy, J, Cw, xo, yo, ro2, Pex, Pey, Pt, PFT, Pflex_other = Pother, Pcre = min(PFT, Pother))
end
sp_g = SectionProperties.open_thin_walled(X, Y, fill(t, ns - 1))
g = global_loads(sp_g, L_br, L_br, L_br)
println("\nGross section: A = $(round(g.A; digits = 2)) mm², Ixx = $(round(g.Ixx/1e4; digits = 3)) cm⁴, Iyy = $(round(g.Iyy/1e4; digits = 3)) cm⁴, J = $(round(g.J; digits = 2)) mm⁴, Cw = $(round(g.Cw; digits = 0)) mm⁶, xo = $(round(g.xo; digits = 2)) mm")
@printf("Global, KL = 48 in (gross): P_ex = %.2f kN, P_ey = %.2f kN, P_t = %.2f kN, P_FT = %.2f kN  -> P_cre = %.3f kN (%.3f kips)\n", g.Pex/1000, g.Pey/1000, g.Pt/1000, g.PFT/1000, g.Pcre/1000, g.Pcre/N_PER_KIP)
res["global_gross"] = g

# AISI S100 weighted-average net properties: hole of width hole_w centred on the web (zero-thickness net-section polyline)
y_mid = (Y[first(sec.web_range)] + Y[last(sec.web_range)]) / 2
Xn, Yn, tn = BucklingModeIdentification.zero_thickness_hole(X, Y, t, y_mid - hole_w / 2, y_mid + hole_w / 2)
sp_n = SectionProperties.open_thin_walled(Xn, Yn, tn)
# Cw of the net section: the two halves act independently (each an open section) — sum of the halves
ih = findfirst(i -> tn[i] < 0.5t, eachindex(tn))              # zero-thickness strip index
sp_h1 = SectionProperties.open_thin_walled(Xn[1:ih], Yn[1:ih], tn[1:ih-1])
sp_h2 = SectionProperties.open_thin_walled(Xn[ih+1:end], Yn[ih+1:end], tn[ih+1:end])
Cw_net = sp_h1.Cw + sp_h2.Cw
frac = L_h_total / L_col
avg(g_, n_) = g_ - (g_ - n_) * frac
sp_avg = (A = avg(sp_g.A, sp_n.A), Ixx = avg(sp_g.Ixx, sp_n.Ixx), Iyy = avg(sp_g.Iyy, sp_n.Iyy), J = avg(sp_g.J, sp_n.J),
          Cw = avg(sp_g.Cw, Cw_net), xc = sp_g.xc, yc = sp_g.yc, xs = sp_g.xs, ys = sp_g.ys)
gh = global_loads(sp_avg, L_br, L_br, L_br)
println("Net section: A = $(round(sp_n.A; digits = 2)) mm², Ixx = $(round(sp_n.Ixx/1e4; digits = 3)) cm⁴, Iyy = $(round(sp_n.Iyy/1e4; digits = 3)) cm⁴, J = $(round(sp_n.J; digits = 2)) mm⁴, Cw,net (two halves) = $(round(Cw_net; digits = 0)) mm⁶; hole length fraction = $(round(frac; digits = 4))")
@printf("Global, KL = 48 in (weighted average, AISI S100): P_ex = %.2f kN, P_ey = %.2f kN, P_t = %.2f kN, P_FT = %.2f kN -> P_cre,hole = %.3f kN (%.3f kips)\n", gh.Pex/1000, gh.Pey/1000, gh.Pt/1000, gh.PFT/1000, gh.Pcre/1000, gh.Pcre/N_PER_KIP)
res["global_hole"] = gh
res["net_props"] = (A = sp_n.A, Ixx = sp_n.Ixx, Iyy = sp_n.Iyy, J = sp_n.J, Cw_net = Cw_net, frac = frac)

serialize(joinpath(out, "baselines.jls"), res)
open(joinpath(out, "baselines.csv"), "w") do io
    println(io, "quantity, value_kN, value_kips, half_wavelength_mm, note")
    @printf(io, "CUFSM Pcrl gross, %.4f, %.4f, %.1f, signature curve minimum\n", res["cufsm_local"].Pcr/1000, res["cufsm_local"].Pcr/N_PER_KIP, res["cufsm_local"].Lcr)
    @printf(io, "CUFSM Pcrd gross, %.4f, %.4f, %.1f, signature curve minimum\n", res["cufsm_dist"].Pcr/1000, res["cufsm_dist"].Pcr/N_PER_KIP, res["cufsm_dist"].Lcr)
    @printf(io, "CUFSM global S-S 48 in (m = 1), %.4f, %.4f, %.1f, single half-wave over the braced length\n", fm[1]*A/1000, fm[1]*A/N_PER_KIP, L_br)
    @printf(io, "CUFSM 48 in m = 2, %.4f, %.4f, %.1f, two half-waves over the braced length\n", fm[2]*A/1000, fm[2]*A/N_PER_KIP, Lm[2])
    @printf(io, "CUFSM 48 in m = 3, %.4f, %.4f, %.1f, three half-waves over the braced length\n", fm[3]*A/1000, fm[3]*A/N_PER_KIP, Lm[3])
    for label in ("FE-matched", "SFIA")
        c = res["csb_$(label)"]
        @printf(io, "CSB Pcrl gross (%s r), %.4f, %.4f, %.1f,\n", label, c.Pcrl/1000, c.Pcrl/N_PER_KIP, c.Lcrl)
        @printf(io, "CSB Pcrd gross (%s r), %.4f, %.4f, %.1f,\n", label, c.Pcrd/1000, c.Pcrd/N_PER_KIP, c.Lcrd)
        @printf(io, "CSB Pcrl hole (%s r), %.4f, %.4f, %.1f, net section through the hole\n", label, c.Pcrl_hole/1000, c.Pcrl_hole/N_PER_KIP, c.Lcrl_hole)
        @printf(io, "CSB Pcrd hole (%s r), %.4f, %.4f, %.1f, AISI S100 reduced web thickness\n", label, c.Pcrd_hole/1000, c.Pcrd_hole/N_PER_KIP, c.Lcrd_hole)
    end
    @printf(io, "Analytical Pex gross, %.4f, %.4f, %.1f,\n", g.Pex/1000, g.Pex/N_PER_KIP, L_br)
    @printf(io, "Analytical Pey gross, %.4f, %.4f, %.1f,\n", g.Pey/1000, g.Pey/N_PER_KIP, L_br)
    @printf(io, "Analytical Pt gross, %.4f, %.4f, %.1f,\n", g.Pt/1000, g.Pt/N_PER_KIP, L_br)
    @printf(io, "Analytical PFT gross, %.4f, %.4f, %.1f,\n", g.PFT/1000, g.PFT/N_PER_KIP, L_br)
    @printf(io, "Analytical Pcre gross, %.4f, %.4f, %.1f, min(PFT and flexure about the non-symmetry axis)\n", g.Pcre/1000, g.Pcre/N_PER_KIP, L_br)
    @printf(io, "Analytical PFT weighted-average (holes), %.4f, %.4f, %.1f, AISI S100 net-section weighted average\n", gh.PFT/1000, gh.PFT/N_PER_KIP, L_br)
    @printf(io, "Analytical Pey weighted-average (holes), %.4f, %.4f, %.1f,\n", gh.Pey/1000, gh.Pey/N_PER_KIP, L_br)
    @printf(io, "Analytical Pcre weighted-average (holes), %.4f, %.4f, %.1f,\n", gh.Pcre/1000, gh.Pcre/N_PER_KIP, L_br)
end
println("Saved results/baselines.csv, baselines.jls, cufsm_signature.csv")
