// Runnable check for NikxelSettings.firstName — the fallback that stopped
// every user's meeting notes from calling them "Nikhil".
//   swiftc -parse-as-library -o /tmp/cun src/NikxelSettings.swift check_user_name.swift && /tmp/cun
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
        print("check_user_name: all cases pass")
    }
}
