import Foundation

/// Short studio briefs bundled with the app. Each one points a feature of
/// the tool at a question from art and design practice, so learning the
/// software and developing a practice happen together. The same text feeds
/// the in-app Briefs screen and `cuardach briefs --markdown` (docs/briefs.md).
public struct StudioBrief: Sendable, Identifiable, Hashable {
    public enum Discipline: String, Sendable, CaseIterable {
        case fineArtMedia = "Fine Art Media"
        case productDesign = "Product Design"
        case communicationDesign = "Communication Design"
    }

    public var id: String
    public var title: String
    public var disciplines: [Discipline]
    public var prompt: String
    /// App features the brief exercises.
    public var uses: [String]
    /// Questions for a sketchbook, crit or reflective journal.
    public var reflect: [String]
    /// Starting points to look at. Kept to well-documented works and texts.
    public var lookAt: [String]
}

extension StudioBrief {
    public static let all: [StudioBrief] = [
        StudioBrief(
            id: "site-specific",
            title: "One place only",
            disciplines: [.fineArtMedia],
            prompt: "Make a work that could not exist anywhere else. Choose a spot on campus or in your neighbourhood, spend an hour there, then make something that depends on what is already present: a sound, a sightline, a history, a shadow at a certain hour. Pin it with a scan and, if you can, a location anchor.",
            uses: ["Scan anchor (site-precise)", "Pin to location", "Proximity-triggered audio", "Wall label and statement"],
            reflect: [
                "What does the work lose if it is moved ten metres? A kilometre?",
                "Who passes this spot without ever seeing your work, and does that matter?",
                "Is AR adding to the place, or competing with it?",
            ],
            lookAt: [
                "Janet Cardiff, Her Long Black Hair (2004), an audio walk in Central Park",
                "Miwon Kwon, One Place after Another: Site-Specific Art and Locational Identity (MIT Press, 2002)",
            ]
        ),
        StudioBrief(
            id: "one-to-one",
            title: "1:1 in context",
            disciplines: [.productDesign],
            prompt: "Take a product you are developing and set its real dimensions. Place it at true scale in three environments where it would actually live: a kitchen, a bus stop, a bedside. Capture a documentation photo in each. Then change one thing about the design based only on what you saw.",
            uses: ["Design size with scale lock", "Documentation capture", "Variants", "Crit notes"],
            reflect: [
                "What did you notice at 1:1 that the screen or the sketch hid?",
                "How did people around you react to an object that wasn't there?",
                "Which environment changed your mind, and why that one?",
            ],
            lookAt: [
                "Bill Buxton, Sketching User Experiences (2007), on prototypes as questions",
                "Dieter Rams, ten principles for good design",
            ]
        ),
        StudioBrief(
            id: "slow-looking",
            title: "Slow looking",
            disciplines: [.fineArtMedia, .communicationDesign],
            prompt: "Make a piece that only reveals itself to someone who stays. Use the dwell trigger so that the work changes after ten, thirty or sixty seconds of attention. Design for the person who gives up early as carefully as for the one who waits.",
            uses: ["Dwell trigger", "Show and hide with fades", "Sequenced actions"],
            reflect: [
                "How long will a stranger give your work? How do you know?",
                "Is the reward for waiting proportionate, surprising, or deliberately withheld?",
                "What does the work say to someone who walks away after five seconds?",
            ],
            lookAt: [
                "Shari Tishman, Slow Looking: The Art and Practice of Learning Through Observation (2018)",
                "Bill Viola's slow-motion video installations",
            ]
        ),
        StudioBrief(
            id: "after-dark",
            title: "After dark",
            disciplines: [.fineArtMedia, .communicationDesign],
            prompt: "Make a work that exists only at certain hours. Use a time window so it appears at dusk, at 3 a.m., or in the ten minutes when the morning commute peaks. Treat time as a material, as you would scale or colour.",
            uses: ["Time-window trigger", "Audio", "Location anchors"],
            reflect: [
                "Who is present at the hour you chose, and who is absent?",
                "What changes about safety, access and permission at night?",
                "How do you document a work that most people will never be there to see?",
            ],
            lookAt: [
                "Rafael Lozano-Hemmer's large-scale public light installations",
                "Nuit Blanche and other night-time public art festivals",
            ]
        ),
        StudioBrief(
            id: "variant-crit",
            title: "Three options, one decision",
            disciplines: [.productDesign, .communicationDesign],
            prompt: "Prepare three variants of one design (colour, material, finish, or form) and set them to cycle on tap. Invite three peers to the site and ask each to leave a crit note while standing where they would actually use the thing. Decide, and write the reason into the winning variant's note.",
            uses: ["Variants and cycle-variant action", "Spatial crit notes", "Exhibition catalogue export"],
            reflect: [
                "Did seeing the options in place change the ranking you had on screen?",
                "Which comment surprised you, and where was that person standing?",
                "What evidence would change your decision again?",
            ],
            lookAt: [
                "Colour, material and finish (CMF) practice in industrial design",
                "Design crit as a studio tradition: who speaks, in what order, and why",
            ]
        ),
        StudioBrief(
            id: "accessible",
            title: "Without looking",
            disciplines: [.fineArtMedia, .productDesign, .communicationDesign],
            prompt: "Make an experience that someone can follow with the screen turned away. Write a description for every element, record an audio description for the key piece, and use spatial sound to guide people. Test it with VoiceOver on, then with someone who uses it every day.",
            uses: ["Descriptions for VoiceOver", "Audio description", "Spatial audio", "Proximity triggers"],
            reflect: [
                "What did writing the description reveal about what the work actually is?",
                "Which design decisions helped everyone, not only blind and low-vision players?",
                "Who did you test with, and what did they teach you?",
            ],
            lookAt: [
                "Microsoft Inclusive Design Toolkit",
                "Audio description practice in museums and theatre",
            ]
        ),
        StudioBrief(
            id: "counter-monument",
            title: "Monument / counter-monument",
            disciplines: [.fineArtMedia, .communicationDesign],
            prompt: "Choose a statue, plaque or memorial and make a virtual response that sits beside it. You may answer, extend, question or mourn. You may not deface it. Write a short statement about your right to speak in that place, and who else should have that right.",
            uses: ["Location anchor", "Object or marker anchor", "Wall label and statement"],
            reflect: [
                "Whose permission matters for a work no one can touch?",
                "How would the people the monument commemorates, or omits, read your work?",
                "Does an invisible layer change public space, or only your phone?",
            ],
            lookAt: [
                "Jochen Gerz and Esther Shalev-Gerz, Monument Against Fascism, Hamburg-Harburg (1986)",
                "MoMAR (2018), an unauthorised AR exhibition staged in MoMA's Jackson Pollock gallery",
            ]
        ),
        StudioBrief(
            id: "hunt-for-others",
            title: "A hunt for someone else",
            disciplines: [.communicationDesign, .productDesign],
            prompt: "Design a short hunt for children aged 7 to 14 at a real site, with a teacher or parent present. Every element needs a printed marker as well as a scan. Write clues that work without much reading. Run it with real players and watch without helping.",
            uses: ["Printed marker sheets", "Found count", "Hidden elements unlocked by set state", "Completion message"],
            reflect: [
                "Where did players get stuck, and was it the clue, the site or the technology?",
                "What did you do about safety: roads, crowds, attention while walking?",
                "What did the children enjoy that you hadn't designed?",
            ],
            lookAt: [
                "Wayfinding and signage systems in museums and parks",
                "Play research: why rules, discovery and collection motivate children",
            ]
        ),
        StudioBrief(
            id: "provenance",
            title: "Know your sources",
            disciplines: [.fineArtMedia, .productDesign, .communicationDesign],
            prompt: "Build a piece using only your own work and openly licensed assets. Record the creator, source and licence of every element. Export the catalogue and check that its credits table would satisfy each licence if the piece were shown publicly, or sold.",
            uses: ["Credits and licences", "Validator notes", "Exhibition catalogue export"],
            reflect: [
                "What is the practical difference between CC BY, CC BY-NC and CC BY-ND for your piece?",
                "Which asset was hardest to trace, and what does that tell you about the platform you got it from?",
                "How would you want your own work credited if someone built on it?",
            ],
            lookAt: [
                "Creative Commons licence chooser and licence deeds",
                "Your institution's guidance on copyright in student work",
            ]
        ),
    ]
}

extension StudioBrief {
    /// Markdown rendering, used to generate docs/briefs.md.
    public static func markdown(_ briefs: [StudioBrief] = all) -> String {
        var s = "# Studio briefs\n\nGenerated by `cuardach briefs --markdown`. The same briefs appear in the app under Library → Briefs.\n"
        for b in briefs {
            s += "\n## \(b.title)\n\n*\(b.disciplines.map(\.rawValue).joined(separator: " · "))*\n\n\(b.prompt)\n\n"
            s += "**Uses:** \(b.uses.joined(separator: ", "))\n\n**Reflect**\n\n"
            s += b.reflect.map { "- \($0)\n" }.joined()
            s += "\n**Look at**\n\n" + b.lookAt.map { "- \($0)\n" }.joined()
        }
        return s
    }
}
