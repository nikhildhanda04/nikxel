// Checks the summary-template files: seeding, comment stripping, the legacy
// summary_style.txt migration, naming, reset and delete.
//
// Runs against the real ~/.nikxel/templates/ -- homeDirectoryForCurrentUser
// ignores $HOME, so there is no faking it. It only ever touches the shipped
// templates (which the app seeds anyway) and its own "check-*" scratch ones,
// and it puts the selected template back when it's done.
//
//   swiftc -parse-as-library -o /tmp/cst check_summary_templates.swift \
//     src/SummaryTemplates.swift src/NikxelSettings.swift src/NoteExporter.swift \
//     src/MOMGenerator.swift src/UsageLog.swift src/CaptureMode.swift src/Diag.swift
import Foundation

@main
struct CheckSummaryTemplates {
    static func main() {
        let fm = FileManager.default
        let selectedBefore = NikxelSettings.summaryTemplate
        let legacy = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nikxel/summary_style.txt")

        // --- Seeding -----------------------------------------------------
        SummaryTemplates.seedIfMissing()
        for t in SummaryTemplates.shipped {
            assert(SummaryTemplates.exists(t.slug), "\(t.slug) was not seeded")
        }

        // Default must contribute nothing: it is all comments, so picking it
        // leaves the shipped prompt untouched.
        assert(SummaryTemplates.instructions(in: "default").isEmpty,
               "Default must add nothing to the prompt")
        NikxelSettings.summaryTemplate = "default"
        assert(NikxelSettings.summaryStyleInstruction.isEmpty,
               "Default must produce no HOUSE STYLE block")

        // Every role template must actually say something.
        for slug in ["developer", "project-manager", "hr", "co-founder"] {
            let text = SummaryTemplates.instructions(in: slug)
            assert(!text.isEmpty, "\(slug) has no instructions")
            // Instructions legitimately name sections ("Add a '## Technical
            // Context' section"), so the test is that no LINE starts with #.
            assert(!text.components(separatedBy: .newlines)
                     .contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") },
                   "\(slug) leaked a comment line into the prompt")
            NikxelSettings.summaryTemplate = slug
            let instr = NikxelSettings.summaryStyleInstruction
            assert(instr.contains("HOUSE STYLE"), "\(slug) produced no HOUSE STYLE block")
            assert(instr.contains(text), "\(slug)'s instructions did not reach the prompt")
            // The guards the house style must never be able to override.
            assert(instr.contains("Never invent content"), "\(slug) lost the no-invention guard")
            assert(instr.contains("## Action Items"), "\(slug) lost the Google-heading guard")
        }

        // Role templates should differ from each other, or the whole feature
        // is decorative.
        let dev = SummaryTemplates.instructions(in: "developer")
        let hr = SummaryTemplates.instructions(in: "hr")
        assert(dev != hr)
        assert(dev.contains("Agent Prompts") && hr.contains("Drop the Agent Prompts"),
               "developer keeps agent prompts, HR drops them")

        // --- Seeding is never destructive ---------------------------------
        let devURL = SummaryTemplates.url(for: "developer")
        try? "My own edit.".write(to: devURL, atomically: true, encoding: .utf8)
        SummaryTemplates.seedIfMissing()
        assert(SummaryTemplates.instructions(in: "developer") == "My own edit.",
               "seeding overwrote an edited template")

        // --- Reset puts a shipped one back --------------------------------
        assert(SummaryTemplates.reset("developer"))
        assert(SummaryTemplates.instructions(in: "developer") == dev, "reset did not restore")
        assert(!SummaryTemplates.reset("nope-not-shipped"), "reset must refuse unknown slugs")

        // --- Naming --------------------------------------------------------
        assert(SummaryTemplates.slugify("Client Calls") == "client-calls")
        assert(SummaryTemplates.slugify("  Board / Investor  ") == "board-investor")
        assert(SummaryTemplates.slugify("1:1s") == "11s")
        assert(SummaryTemplates.slugify("!!!").isEmpty, "a name with nothing usable must slug to empty")
        assert(SummaryTemplates.displayName(for: "client-calls") == "Client Calls")
        assert(SummaryTemplates.displayName(for: "hr") == "HR", "shipped names win over derivation")
        assert(SummaryTemplates.displayName(for: "qa") == "QA", "short slugs read as acronyms")
        assert(SummaryTemplates.displayName(for: "project-manager") == "Project Manager")

        // --- Create / copy / delete -----------------------------------------
        SummaryTemplates.delete("check-scratch")
        SummaryTemplates.delete("check-copy")

        let slug = SummaryTemplates.create(named: "Check Scratch")
        assert(slug == "check-scratch", "got \(slug ?? "nil")")
        assert(SummaryTemplates.instructions(in: "check-scratch").isEmpty,
               "a blank new template is all comments, so it adds nothing yet")
        assert(SummaryTemplates.create(named: "Check Scratch") == nil, "duplicate names must be refused")
        assert(SummaryTemplates.create(named: "   ") == nil, "an empty name must be refused")

        let copy = SummaryTemplates.create(named: "Check Copy", copying: "hr")
        assert(copy == "check-copy")
        assert(SummaryTemplates.instructions(in: "check-copy") == hr,
               "copying must carry the source's instructions, not its comments")

        // Listing: shipped first in order, then user templates alphabetically.
        let listed = SummaryTemplates.available()
        let slugs = listed.map(\.slug)
        assert(Array(slugs.prefix(5)) == SummaryTemplates.shipped.map(\.slug), "shipped order wrong: \(slugs)")
        assert(slugs.contains("check-copy") && slugs.contains("check-scratch"))
        assert(slugs.firstIndex(of: "check-copy")! < slugs.firstIndex(of: "check-scratch")!,
               "user templates should be alphabetical")
        assert(!SummaryTemplates.isShipped("check-copy"))
        assert(SummaryTemplates.isShipped("hr"))

        // Deleting the active template falls back to Default rather than
        // leaving a selection that points at nothing.
        NikxelSettings.summaryTemplate = "check-copy"
        SummaryTemplates.delete("check-copy")
        assert(!SummaryTemplates.exists("check-copy"))
        assert(NikxelSettings.summaryTemplate == "default",
               "deleting the active template must fall back to Default")
        SummaryTemplates.delete("check-scratch")

        // --- Legacy summary_style.txt migration ------------------------------
        let hadLegacy = fm.fileExists(atPath: legacy.path)
        assert(!hadLegacy, "this check assumes no real summary_style.txt to protect")
        SummaryTemplates.delete("my-style")

        // All-comment legacy file: nothing was ever written, so just retire it.
        try? "# just the template\n# nothing written".write(to: legacy, atomically: true, encoding: .utf8)
        SummaryTemplates.seedIfMissing()
        assert(!fm.fileExists(atPath: legacy.path), "an empty legacy file should be removed")
        assert(!SummaryTemplates.exists("my-style"), "an empty legacy file should not become a template")

        // A legacy file with real content becomes "My Style" and is selected.
        try? "# header\nKeep it to three sentences.".write(to: legacy, atomically: true, encoding: .utf8)
        SummaryTemplates.seedIfMissing()
        assert(!fm.fileExists(atPath: legacy.path), "the legacy file should be removed after migrating")
        assert(SummaryTemplates.instructions(in: "my-style") == "Keep it to three sentences.",
               "got: \(SummaryTemplates.instructions(in: "my-style"))")
        assert(NikxelSettings.summaryTemplate == "my-style",
               "the migrated template must be the selected one, or the user silently loses their style")

        // --- Restore -----------------------------------------------------
        SummaryTemplates.delete("my-style")
        NikxelSettings.summaryTemplate = selectedBefore
        print("check_summary_templates: all assertions passed (selection restored to \"\(selectedBefore)\")")
    }
}
