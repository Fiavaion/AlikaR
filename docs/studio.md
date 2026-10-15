# Studio features

The PRD sets out what Cuardach must do to replace Aero. The Studio features go further, toward what art and design students need from a tool like this: ways to present, credit, critique, evaluate and document work, and ideas that broaden what they think AR can be for. Each is a small, optional part of the manifest, so none of them complicates the core format or the MVP.

## For every discipline

**Wall labels and statements.** Every experience can carry a statement, and every element a gallery-style label: title, maker, year, medium, dimensions, statement and a plain-language description. Writing a label is part of making the work. It forces decisions about what the piece is, and the catalogue and the player's About screen show it the way a gallery would.

**Descriptions for VoiceOver, and audio description.** Each element can have a short description and a recorded audio description. The validator nudges authors who leave these out. Accessibility becomes a material to design with, not a compliance step at the end (see the brief *Without looking*).

**Credits and licences.** Every asset records its creator, source and licence. The validator and catalogue flag NC, ND and all-rights-reserved material, and anything with an unknown licence. Students build on downloaded scans, models and sounds all the time; this makes attribution routine, and teaches the practical difference between CC BY, NC and ND before it matters for a degree show or a commission.

**Spatial crit.** A lecturer or peer opens the student's file, walks the site, and leaves notes (question, suggestion, strength or issue) floating where they stood, beside the element they are about. The student resolves each one with a reply, and the catalogue can include the crit record for assessment. It works without a server: the file goes back and forth by AirDrop.

**Documentation capture.** Site-specific and AR work is ephemeral. The camera button takes a clean still (no editing UI, crit notes or ghosts) straight to Photos, and the record button makes a screen recording to trim and save. These are the images that end up in portfolios and degree-show archives.

**Exhibition catalogue.** One tap produces a self-contained web page: cover, statement, how to visit and how precisely things are placed, each work's label and interactions in plain English, a credits table, and optionally the crit record. It serves as the hand-in document, the handout and the portfolio page, and it prints cleanly.

**Remix.** Any experience someone has shared can be copied into "My experiences" to take apart and rebuild. The copy credits the original. It is how lecturers can hand out worked examples, and how students learn from each other.

## For Fine Art Media

**Dwell.** A behaviour can wait until the viewer has kept the work in view for a set time, optionally from within a set distance. Attention becomes the trigger. Work can reward slow looking, withhold itself, or change only for those who stay.

**Time windows.** A behaviour can fire only between two local times, wrapping past midnight if needed: a piece that appears at dusk, a sound that plays only during the morning commute. Time becomes a site-specific material alongside place.

**Text in space.** A text element is a line of words that floats in place and turns to face the reader: titles, poems, instructions, testimony.

**Sound.** Proximity-triggered and looping spatial sound, inherited from Aero, combine with dwell and time windows for audio walks in the tradition of Janet Cardiff.

## For Product Design

**True size.** An element can carry its real dimensions in millimetres. "Scale model to these dimensions" fixes models exported in centimetres or inches, and "Lock at 1:1" disables pinch-scaling, so the object sits in the kitchen, at the bus stop or by the bed exactly as big as it would be. The inspector shows measured dimensions throughout.

**Variants.** An element can hold several assets: colourways, materials, finishes, iterations. A tap cycles through them, or a behaviour selects one. Each variant has a note recording why it exists, so the CMF rationale travels with the file and appears in the catalogue. Combined with spatial crit, a group can compare options where the product would actually be used.

**Import honesty.** Before a model is placed, the import sheet reports triangle count, file size, animations, missing textures and unsupported glTF extensions, and catches models exported at the wrong scale. Asset optimisation becomes visible rather than a mystery.

## For Communication Design

**Hunts and wayfinding.** Hidden elements can be unlocked by finding others (`setState: visible`). There is a found count, a completion message and an overview map. Printed marker sheets carry the element's name and a QR code. Designing a hunt for children, with clue writing, signage and safety, is a complete communication-design project (see the brief *A hunt for someone else*).

**Posters as interfaces.** Every printed marker is a designed artefact: the pattern ARKit tracks, plus the work's name and a QR code that opens the experience. Teaching how a poster can be both a sign and an interface is a natural extension.

## Studio briefs

Nine short briefs, available in the app (Library → Studio briefs) and in [briefs.md](briefs.md). Each pairs a feature with a question from practice and gives reflection prompts and references. They are starting points for lecturers to adapt, not a curriculum.

| Brief | Disciplines | Features |
| --- | --- | --- |
| One place only | Fine Art Media | Scan and location anchors, proximity audio, statement |
| 1:1 in context | Product Design | True size, documentation capture, variants, crit |
| Slow looking | Fine Art, Communication | Dwell, fades, sequencing |
| After dark | Fine Art, Communication | Time windows, sound, location |
| Three options, one decision | Product, Communication | Variants, spatial crit, catalogue |
| Without looking | All | Descriptions, audio description, spatial sound |
| Monument / counter-monument | Fine Art, Communication | Location and marker anchors, statement |
| A hunt for someone else | Communication, Product | Markers, found count, unlocks, completion |
| Know your sources | All | Credits and licences, validator, catalogue |
