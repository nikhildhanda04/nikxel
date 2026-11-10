// Runnable checks for the two bits of parsing behind meeting summaries:
// NikxelSettings.firstName (the fallback that stopped every user's notes from
// calling them "Nikhil") and MOMGenerator.stampedVersion (which decides when a
// cached prompt in ~/.nikxel/prompts/ is replaced by a newer shipped one).
//
//   swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/cun \
//     src/NikxelSettings.swift src/NoteExporter.swift src/MOMGenerator.swift src/UsageLog.swift \
//     src/CaptureMode.swift src/Diag.swift check_user_name.swift && /tmp/cun
import Foundation

@main struct Check {
    static func main() {
        func eq(_ full: String, _ account: String, _ want: String?, _ why: String) {
            let got = NikxelSettings.firstName(fullName: full, account: account)
            precondition(got == want, "\(why): firstName(\"\(full)\", \"\(account)\") = \(got ?? "nil"), want \(want ?? "nil")")
        }
        eq("Prince Choudhary", "prince", "Prince", "full name")
        eq("prince choudhary", "prince", "Prince", "lowercase full name is capitalized")
        eq("Priya", "psharma", "Priya", "single first name that isn't the login")
        eq("princechoudhary", "princechoudhary", nil, "bare login is not a name")
        eq("admin2", "admin2", nil, "digits mean it's an account, not a name")
        eq("jake@viziontools.com", "jake", nil, "email is not a name")
        eq("", "jake", nil, "empty full name")
        eq("  ", "jake", nil, "whitespace-only full name")
        eq("J Smith", "j", nil, "single-letter first name is an initial")
        func ver(_ text: String, _ want: Int?, _ why: String) {
            let got = MOMGenerator.stampedVersion(text)
            precondition(got == want, "\(why): stampedVersion = \(got.map(String.init) ?? "nil"), want \(want.map(String.init) ?? "nil")")
        }
        ver(MOMGenerator.promptVersionTag, MOMGenerator.promptVersion, "the tag we ship reads back as the version we ship")
        ver("<!-- nikxel-prompt v2 -->\nYou are generating...", 2, "older version")
        ver("<!-- nikxel-prompt v12 -->", 12, "two-digit version")
        ver("You are generating Minutes of Meeting", nil, "pre-versioning prompt falls through to the legacy markers")
        ver("<!-- nikxel-prompt v -->", nil, "missing number is not a version")
        ver("<!-- nikxel-prompt vX -->", nil, "non-numeric version")
        ver("<!-- nikxel-prompt v3", nil, "unterminated tag")
        precondition(MOMGenerator.promptVersionTag.contains("v\(MOMGenerator.promptVersion)"),
                     "shipped prompts must carry the current version")

        print("check_user_name: all cases pass")
    }
}
