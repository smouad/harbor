// swiftc -parse-as-library Harbor/Managers/PasswordManager/LoginCSV.swift scripts/tests/LoginCSVCheck.swift -o /tmp/lcc && /tmp/lcc
import Foundation

@main
struct LoginCSVCheck {
    static func main() {
        // Chrome, Arc and Dia: name,url,username,password,note
        let chrome = "name,url,username,password,note\nexample.com,https://example.com/login,me@example.com,s3cret,\n"
        precondition(LoginCSV.parse(chrome) == [.init(url: "https://example.com/login", username: "me@example.com", password: "s3cret")])

        // Quotes, commas, doubled quotes and a line break inside a field.
        let tricky = "name,url,username,password,note\n\"a, b\",https://x.io,\"u,ser\",\"pa\"\"ss\nword\",\"note\"\n"
        let rows = LoginCSV.parse(tricky)
        precondition(rows.count == 1 && rows[0].username == "u,ser" && rows[0].password == "pa\"ss\nword", "got \(rows)")

        // Bitwarden columns, Windows line endings, and a row with no password left out.
        let bitwarden = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\r\n,,login,Site,,,0,https://site.com,bob,pw1,\r\n,,login,Empty,,,0,https://empty.com,bob,,\r\n"
        let parsed = LoginCSV.parse(bitwarden)
        precondition(parsed == [.init(url: "https://site.com", username: "bob", password: "pw1")], "got \(parsed)")

        // 1Password: Title,Url,Username,Password
        precondition(LoginCSV.parse("Title,Url,Username,Password\nT,https://a.com,u,p\n").count == 1)
        // No usable header: nothing is guessed.
        precondition(LoginCSV.parse("a,b,c\n1,2,3\n").isEmpty)
        precondition(LoginCSV.parse("").isEmpty)
        print("LoginCSVCheck passed")
    }
}
