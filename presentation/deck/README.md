# deckmd

Markdown in, slide deck out. A tiny, dependency-free slide system in plain
Julia: edit one Markdown file, get a themeable HTML deck that presents from
`file://`, exports to PDF, compiles to a single self-contained file, and
deploys to GitHub Pages with one command.

**Live demo (this repo's `slides.md`, deployed by this repo's `publish.jl`):**
https://kristofferc.github.io/deckmd/

No npm, no LaTeX install, no framework — the whole compiler is ~450 lines of
stdlib-only Julia, and KaTeX is vendored so math works offline.

**To start a new deck: use this repo as a template** (or clone it), delete the
demo content in `slides.md`, and write.

## The loop

```
julia serve.jl        # then open http://localhost:8383/
```

Edit **`slides.md`** and save — the browser rebuilds and reloads itself,
staying on the slide you're looking at. A syntax error shows up as an overlay
on the slide (with the slide number); fix it and the overlay clears. The
server also picks up edits to `template.html` and `data/*.js`.

Without the server: `julia build.jl` and reload `deck.html` by hand — it
works straight from `file://`, fully offline, which is also how you present.

| file | role |
| --- | --- |
| `slides.md` | the content you edit — slides separated by `---` |
| `serve.jl` | dev server: rebuild-on-save + live reload (stdlib only) |
| `build.jl` | Markdown → HTML compiler (no dependencies) |
| `template.html` | all CSS + the deck JS engine — edit to change the look |
| `publish.jl` | build the single file + push it to GitHub Pages |
| `data/*.js` | figure data — regenerate with `julia data/generate.jl` |
| `scripts/qr.jl` | generate `data/qr.svg` for a URL (temp env, QRCoders.jl) |
| `vendor/katex/` | vendored KaTeX so `$math$` works offline |
| `deck.html` | **generated** output — never edit |

## Syntax

Slides are separated by `---`. Within a slide (colons after `@keys` optional):

```markdown
@eyebrow Component · table          small caps line above the heading
# Measured totals                   the heading
@kicker A muted subtitle            under the heading
@layout title | center              special layouts (title page, centered)
@chips a | b | c                    pill chips row
@keys <kbd>→</kbd> next             small footer line (raw HTML)

+ stepped bullet (fragment)         - always-visible bullet
  - nested bullet (indent a - or +)
  ~ muted sub-line for the bullet above

**bold** *italic* `code` ==highlight== [text](url) :github: :mail:
$\varepsilon_1^2 = 0$ inline and $$ H_{ij} = \dots $$ display math (KaTeX)

| a | b |                           pipe table, auto-wrapped in a panel
| --- | --- |
| x | ==2.3×== |                    ==cell== colors the payoff column
?> caption text                     figure caption (after tables/figures)

!big 4.39×                          giant number

@gap                                vertical spacer (24px); @gap 40 or @gap 2em

```julia title="..." sub="..."      code card; also ```diff, ```diff2 and ```julia>
hessian!(H, f, x, cfg)  #!hl          #!hl spotlights a line
```                                 (julia> renders REPL prompts,
@pills good:0 B | bad:slow | note    diff2 renders a side-by-side diff)
```

`lang | some caption` inside a fence info line is shorthand for `title="..."`.

Layout containers:

```markdown
::: cols            two columns, split by  :: col  (or +++)
::: panel Title     boxed panel with an optional title
::: fragment        click-to-reveal block (steps like a + bullet)
:::                 closes a container
```

Figures:

```markdown
@fig cells v d1*4 = label           colored cell strips (classes = palette);
                                    also inline mid-text via @fig{...}
@fig svg data/qr.svg                inline an SVG file (stays in --single)
```

Raw HTML is the escape hatch: any line starting with `<` passes through, and
`~~~ … ~~~` fences pass whole blocks through untouched. Charts read
`window.DECK_DATA.*` from `data/*.js` (see `data/generate.jl` and the chart
JS at the bottom of `template.html` — a grouped bar chart and a log–log line
chart ship as examples). Everything is implemented in `build.jl`; extending
the syntax is fair game.

## Presenting

`→`/`←` navigate (fragments step first), `f` fullscreen, `t` light/dark,
`Home`/`End` jump, the URL hash deep-links a slide. On touch screens: tap the
right/left edge or swipe.

- `julia build.jl --pdf` emits **`deck.pdf`** (one slide per page, light
  theme, fragments shown) via headless Chrome — install Chrome/Chromium.
- `julia build.jl --single` emits **`deck-single.html`**: KaTeX, fonts,
  figure data, and images all inlined — one ~1 MB file with no other
  requirements, for mailing or hosting anywhere.

## Deploying

```
julia publish.jl              # → https://<user>.github.io/<repo>/
julia publish.jl mytalk       # → https://<user>.github.io/<repo>/mytalk/
```

Builds the single file and force-pushes it as `index.html` on an orphan
`gh-pages` branch of `origin`; the first push auto-enables GitHub Pages.
The branch only ever holds generated output.

## Theming

All colors are CSS custom properties at the top of `template.html`, defined
for light and dark (the deck follows the system theme; `t` toggles). Slide
size is fixed 1280×720 and scaled to fit the window, so layout is identical
on every screen, in print, and on Pages.
