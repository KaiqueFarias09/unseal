# ALTO test fixtures

Generated ALTO documents used by the ALTO import tests. Both files were
produced by Tesseract 5.5.3 (`brew install tesseract`, 2026-10-17) in ALTO
output mode over pages rendered from this repository's own DjVu fixtures
with `ddjvu` (DjVuLibre 3.5.29):

- `goody-page2-tesseract.xml` — page 2 of
  `test/resources/djvu/goody-twoshoes.djvu` (public domain), rendered
  `ddjvu -format=tiff -page=2`, then `tesseract page2.tiff out alto`.
  SHA-256 `b5f8a690925be85b2164cb5a88975a2d7ee522ca42a957978193c0a70510b34e`.
- `cyrillic-page1-tesseract.xml` — page 1 of
  `test/resources/djvu/cyrillic.djvu` (public domain), rendered
  `ddjvu -format=tiff -page=1`, then `tesseract page1.tiff out alto`.
  SHA-256 `f28d54fdb0449c33271f45f2452bf6f59003ea11b7fec968ee5d30b4ced460fd`.

Both declare the ALTO 3 namespace (`ns-v3#`), `MeasurementUnit=pixel`, and
`processingSoftware` Tesseract 5.5.3. Both validate against the pinned
official schema `alto-3-1.xsd`
(SHA-256 `846ed72f4b2fce6d5343c439ef4c7a22d678b0192245003b619aef230b99b3bd`,
from the ALTO schema repository mirror of loc.gov) with
`xmllint --nonet --schema` plus an XML catalog resolving the ALTO xlink
import to the LOC `xlink.xsd` (retrieved from the Internet Archive copy of
`https://www.loc.gov/standards/xlink/xlink.xsd`). The generation commands
recorded here re-run the validation in the B01 oracle gate; the OCR text
content itself is Tesseract's own output and the tests read its structure,
not its accuracy.
