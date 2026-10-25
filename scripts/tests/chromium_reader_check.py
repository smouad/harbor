"""Builds a Chromium-style profile with independently encrypted values (hashlib + openssl), then has
ChromiumReader read it back. Run: python3 -I scripts/tests/chromium_reader_check.py"""
import hashlib, json, os, shutil, sqlite3, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASSWORD = "peanuts-test"
KEY = hashlib.pbkdf2_hmac("sha1", PASSWORD.encode(), b"saltysalt", 1003, 16)

def encrypt(plain: bytes) -> bytes:
    out = subprocess.run(["openssl", "enc", "-aes-128-cbc", "-K", KEY.hex(), "-iv", "20" * 16],
                         input=plain, capture_output=True, check=True).stdout
    return b"v10" + out

def webkit_time(unix: float) -> int:
    return int((unix + 11644473600) * 1_000_000)

def build(user_data: str):
    os.makedirs(f"{user_data}/Default/Network")
    os.makedirs(f"{user_data}/Profile 1")
    json.dump({"profile": {"info_cache": {"Default": {"name": "Personal"}, "Profile 1": {"name": "Work"}}}},
              open(f"{user_data}/Local State", "w"))
    # Cookies, database version 24: the plain value starts with SHA-256 of the host.
    db = sqlite3.connect(f"{user_data}/Default/Network/Cookies")
    db.execute("CREATE TABLE meta (key TEXT, value TEXT)")
    db.execute("INSERT INTO meta VALUES ('version', '24')")
    db.execute("""CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, path TEXT,
        expires_utc INTEGER, is_secure INTEGER, is_httponly INTEGER, samesite INTEGER, has_expires INTEGER)""")
    host = ".example.com"
    enc = encrypt(hashlib.sha256(host.encode()).digest() + b"session-token-123")
    future = webkit_time(4_000_000_000)
    past = webkit_time(1_000_000_000)
    db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?)", (host, "sid", "", enc, "/", future, 1, 1, 1, 1))
    db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?)", ("plain.test", "theme", "dark", b"", "/", 0, 0, 0, -1, 0))
    db.execute("INSERT INTO cookies VALUES (?,?,?,?,?,?,?,?,?,?)", (host, "old", "x", b"", "/", past, 0, 0, -1, 1))
    db.commit(); db.close()
    # Passwords, one blocked site and one empty entry.
    db = sqlite3.connect(f"{user_data}/Default/Login Data")
    db.execute("CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER)")
    db.execute("INSERT INTO logins VALUES (?,?,?,0)", ("https://shop.example.com/login", "me@example.com", encrypt(b'p,"ss\nword')))
    db.execute("INSERT INTO logins VALUES (?,?,?,1)", ("https://never.example.com/", "", encrypt(b"nope")))
    db.execute("INSERT INTO logins VALUES (?,?,?,0)", ("https://empty.example.com/", "u", b""))
    db.commit(); db.close()
    # History
    db = sqlite3.connect(f"{user_data}/Default/History")
    db.execute("CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT)")
    db.execute("CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER)")
    db.execute("INSERT INTO urls VALUES (1, 'https://example.com/a', 'A'), (2, 'chrome://settings', 'S'), (3, 'https://example.com/b', 'B'), (4, 'https://old.example.com/', 'Old')")
    import time
    now = time.time()
    # a: two days ago, a non-web page, b: an hour ago, and one visit a month ago that an import leaves out
    for i, (u, t) in enumerate([(1, now - 2 * 86400), (2, now - 100), (3, now - 3600), (4, now - 30 * 86400)]):
        db.execute("INSERT INTO visits VALUES (?,?,?)", (i + 1, u, webkit_time(t)))
    db.commit(); db.close()
    # Bookmarks
    json.dump({"roots": {
        "bookmark_bar": {"type": "folder", "name": "Bookmarks bar", "children": [
            {"type": "url", "name": "Site", "url": "https://site.test/"},
            {"type": "folder", "name": "Reading", "children": [{"type": "url", "name": "Post", "url": "https://blog.test/p"}]},
            {"type": "folder", "name": "Empty", "children": []}]},
        "other": {"type": "folder", "name": "Other", "children": []}}}, open(f"{user_data}/Default/Bookmarks", "w"))

def main():
    work = tempfile.mkdtemp(prefix="harbor-chromium-check-")
    user_data = f"{work}/User Data"
    build(user_data)
    binary = f"{work}/check"
    subprocess.run(["swiftc", "-parse-as-library", f"{ROOT}/Harbor/Managers/ImportManager/Chromium.swift",
                    f"{ROOT}/scripts/tests/ChromiumReaderCheck.swift", "-o", binary], check=True)
    out = json.loads(subprocess.run([binary, user_data, PASSWORD], capture_output=True, text=True, check=True).stdout)

    assert out["profiles"] == ["Default=Personal", "Profile 1=Work"], out["profiles"]
    cookies = {(c["domain"], c["name"]): c for c in out["cookies"]}
    sid = cookies[(".example.com", "sid")]
    assert sid["value"] == "session-token-123", sid          # decrypted, hash prefix dropped
    assert sid["secure"] and sid["httpOnly"] and not sid["session"], sid
    assert cookies[("plain.test", "theme")]["value"] == "dark" and cookies[("plain.test", "theme")]["session"]
    assert (".example.com", "old") not in cookies             # expired
    assert len(out["logins"]) == 1, out["logins"]             # blocked and empty ones left out
    assert out["logins"][0] == {"url": "https://shop.example.com/login", "user": "me@example.com", "pass": 'p,"ss\nword'}
    assert out["csv"].splitlines()[0] == "name,url,username,password,note"
    assert '"p,""ss\nword"' in out["csv"], out["csv"]          # quoted, with doubled quotes
    assert [h["url"] for h in out["history"]] == ["https://example.com/b", "https://example.com/a"], out["history"]   # newest first, web pages, last week only
    assert out["bookmarks"] == [{"folder": "Bookmarks bar", "items": [
        {"page": "Site", "url": "https://site.test/"},
        {"folder": "Reading", "items": [{"page": "Post", "url": "https://blog.test/p"}]}]}], out["bookmarks"]
    assert out["wrongKeyCookies"] == 0 and out["wrongKeyLogins"] == 0   # a wrong key yields nothing
    print("chromium reader ok:", len(out["cookies"]), "cookies,", len(out["logins"]), "login,", len(out["history"]), "visits")

try:
    main()
finally:
    for leftover in [d for d in os.listdir(tempfile.gettempdir()) if d.startswith('harbor-chromium-check-')]:
        shutil.rmtree(os.path.join(tempfile.gettempdir(), leftover), ignore_errors=True)
