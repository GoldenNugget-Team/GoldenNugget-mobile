# Icon sources

Artwork that `scripts/generate-*.py` turns into compiled icon assets. Kept out
of the bundle so the shipped `.app` only ever carries what `actool` produced.

## `scrapped-1024.png`

Opaque 1024x1024 master for the "Scrapped" alternate icon, expanded from a
180x180 source, so it exists to prove the alternate-icon *mechanism* rather than
to be the final artwork — the home screen will render it, but visibly soft.

It is committed because `scripts/generate-scrapped-appiconset.py` has to be
runnable: the generated `Assets.xcassets/ScrappedIcon.appiconset` is checked in
as the app's icon source, and the script is what regenerates it.

Replace this file with a real 1024x1024 master and re-run
`python3 scripts/generate-scrapped-appiconset.py`, then let
`.github/workflows/assets-car.yml` recompile `Assets.car`.

Do not add an alpha channel: iOS icons are composited on an opaque rounded
rectangle, and a transparent master is one of the ways the alternate has
rendered as a theme-aware blank.
