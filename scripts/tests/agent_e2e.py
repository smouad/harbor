#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
#
# End-to-end checks for the agent tools, against a running copy started with
# scripts/tests/agent-copy.sh (hands-off: nothing here sends OS input or takes the screen).
#
#   scripts/tests/agent-copy.sh all && python3 -I scripts/tests/agent_e2e.py [--report out.json] [-k name]
#
# Serves scripts/tests/agent-fixtures on a free local port and asserts what the page itself saw
# (trusted events, values, files, dialogs), not just what the tool said.
#
# The vault check types a real secret when the copy's vault has one. Harbor reads only items it
# saved itself without a prompt, so add them in the copy's Settings > Developer > Agent Vault:
# e2e_password on 127.0.0.1, and e2e_wrong_site on example.org. Without them it is skipped.

import argparse
import base64
import functools
import http.server
import json
import os
import re
import socketserver
import sys
import threading
import time
import traceback
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "agent-fixtures")
BUNDLE = os.environ.get("HARBOR_AGENT_BUNDLE", "com.mouad.harbor.agent")
PORT = int(os.environ.get("HARBOR_AGENT_PORT", "47911"))
FILES = os.environ.get("HARBOR_AGENT_FILES", "/tmp/harbor-agent-files")
TOKEN = open(os.path.expanduser(f"~/Library/Application Support/{BUNDLE}/dev-mcp-token")).read().strip()


# MARK: - Plumbing

class ToolError(Exception):
    pass


class Skip(Exception):
    """The environment cannot run this check (say, a keychain waiting on a prompt)."""


def rpc(method, params=None, timeout=45):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}).encode()
    request = urllib.request.Request(f"http://127.0.0.1:{PORT}/mcp", body,
                                     {"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    reply = json.load(urllib.request.urlopen(request, timeout=timeout))
    if "error" in reply:
        raise ToolError(reply["error"].get("message"))
    return reply["result"]


def call(tool, args=None, expect_error=False):
    """The tool's result: parsed JSON (untrusted wrapper removed), text, or images."""
    result = rpc("tools/call", {"name": tool, "arguments": args or {}})
    texts = [c["text"] for c in result["content"] if c["type"] == "text"]
    images = [base64.b64decode(c["data"]) for c in result["content"] if c["type"] == "image"]
    text = "\n".join(texts)
    if result.get("isError") and not expect_error:
        raise ToolError(f"{tool}: {text}")
    if expect_error:
        assert result.get("isError"), f"{tool} should have failed: {text[:300]}"
        return text
    if images:
        return {"images": images, "text": text}
    inner = re.search(r"<untrusted_page_content[^>]*>\n(.*)\n</untrusted_page_content>", text, re.S)
    payload = inner.group(1) if inner else text
    try:
        return json.loads(payload)
    except ValueError:
        return payload


def page(code):
    """Runs code in the agent page's own world and returns the value."""
    return call("evaluate", {"code": code})


def wait_job(job, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        state = call("job_wait", {"job": job, "timeout": 20})
        if state["state"] != "running":
            return state
    raise AssertionError(f"job {job} still running after {timeout}s")


class Fixtures(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


# The User-Agent header of the last page request for each fixture path (Harbor's own fetches,
# such as the favicon finder reading the page, are left out).
SEEN_AGENTS = {}


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        agent = self.headers.get("User-Agent", "")
        if agent.startswith("Mozilla/"):
            SEEN_AGENTS[self.path.split("?")[0]] = agent
        super().do_GET()


def serve_fixtures():
    handler = functools.partial(QuietHandler, directory=FIXTURES)
    server = Fixtures(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}"


# MARK: - Tests

BASE = ""
TESTS = []


def test(fn):
    TESTS.append(fn)
    return fn


def open_page(name):
    """Opens a fixture in the Agent space's current tab, or a tab of its own when that one is a task's."""
    try:
        return call("read", {"url": f"{BASE}/{name}"})
    except ToolError as error:
        if "belongs to task" not in str(error):
            raise
        call("createTab", {"url": f"{BASE}/{name}"})
        return call("read", {"url": f"{BASE}/{name}"})


@test
def tools_are_listed():
    names = {t["name"] for t in rpc("tools/list")["tools"]}
    for name in ["observe", "act", "read", "crawl", "upload", "screenshot", "dialogs", "jobs", "job_wait",
                 "task_start", "task_handoff", "approval_wait", "secrets", "record_start", "recipe_run",
                 "recipe_repair", "schedule", "watch", "extract", "ocr", "site_tools", "site_tool_call", "evaluate", "tabs", "identity"]:
        assert name in names, f"missing {name}"
    assert "executeJavaScript" not in names


@test
def agent_pages_switch_to_chrome_where_turned_away():
    # Safari by default: a Chrome user agent on WebKit trips bot checks (Google's).
    SEEN_AGENTS.pop("/article.html", None)
    open_page("article.html")
    assert "Version/" in SEEN_AGENTS.get("/article.html", "") and "Chrome/" not in SEEN_AGENTS["/article.html"], SEEN_AGENTS
    # identity switches one page, client hints included, and back.
    try:
        result = call("identity", {"as": "chrome", "reload": True})
        assert "Chrome/" in result["userAgent"] and "Chrome/" in SEEN_AGENTS["/article.html"], (result, SEEN_AGENTS)
        seen = page("return { brands: navigator.userAgentData?.brands?.map(b => b.brand), vendor: navigator.vendor }")
        assert "Google Chrome" in seen["brands"] and seen["vendor"] == "Google Inc.", seen
    finally:
        call("identity", {"as": "default", "reload": True})
    assert "Chrome/" not in SEEN_AGENTS["/article.html"], SEEN_AGENTS
    assert page("return navigator.userAgentData === undefined || !navigator.userAgentData.brands"), "shim ran under Safari"
    # A page that says the browser is not supported is opened again as Chrome (localhost, so what
    # Harbor learns for that site leaves the other fixtures alone).
    turned_away = BASE.replace("127.0.0.1", "localhost") + "/unsupported.html"
    page_read = call("read", {"url": turned_away})
    assert "Welcome to the app" in page_read["markdown"], page_read["markdown"][:200]
    assert "Chrome/" in SEEN_AGENTS["/unsupported.html"], SEEN_AGENTS


@test
def extensions_run_in_agent_tabs():
    open_page("article.html")
    mark = page("return document.documentElement.dataset.harborTestExtension || null")
    if mark is None and os.environ.get("HARBOR_AGENT_CONFIG") == "Release":
        raise Skip("a Release copy installs no test extension")
    assert mark == "ran", f"the test extension's content script did not run: {mark}"


@test
def person_tabs_follow_the_setting():
    try:
        listing = call("tabs")
    except ToolError as error:
        assert "not let agents use their tabs" in str(error), error
        call("read", {"tab": "current"}, expect_error=True)
        return
    # Runs before the task tests: taking a task over brings the Agent space up in the window.
    tabs = [t for w in listing["windows"] for t in w["tabs"]]
    if not tabs:
        raise Skip("the copy's window has no tab of its own")
    target = next((t for t in tabs if t.get("current")), tabs[0])
    if listing["access"] == "ask":
        held = call("read", {"tab": target["id"]})
        assert held.get("needs_approval"), held
        return
    assert listing["access"] == "always", listing
    seen = call("read", {"tab": target["id"], "url": f"{BASE}/article.html"})
    assert "crawl" in str(seen), str(seen)[:300]
    after = call("tabs")
    entry = next(t for w in after["windows"] for t in w["tabs"] if t["id"] == target["id"])
    assert entry.get("url", "").endswith("/article.html"), entry
    # The Agent space's own tab is untouched, and a task cannot be combined with a person's tab.
    call("read", {"tab": target["id"], "task": "t_none"}, expect_error=True)


@test
def read_gives_markdown():
    result = open_page("article.html")
    md = result["markdown"]
    assert md.startswith("# Harbor Agent"), md[:80]
    assert "**native**" in md and "*trusted*" in md
    assert "- Observe\n  - Refs" in md, "nested list keeps its indent"
    assert "1. First\n2. Second" in md
    assert "```swift\nlet x = 1\nprint(x)\n```" in md, "code keeps its lines"
    assert "| Tool | Kind |" in md and "| crawl | job |" in md
    assert "Footer text" not in md and "Home" not in md, "page chrome is left out"
    linked = call("read", {"links": True})
    assert any(link["href"].endswith("/list.html") for link in linked["links"])


@test
def observe_lists_controls_with_stable_refs():
    open_page("form.html")
    first = call("observe")["elements"]
    by_name = {e["name"]: e for e in first}
    assert by_name["Full name"]["role"] == "textbox"
    assert by_name["Password"]["type"] == "password"
    assert by_name["Inside frame"]["role"] == "button", "same-origin frames are included"
    assert not any(e["role"] == "label" for e in first), "labels of visible controls are not listed twice"
    again = {e["name"]: e["ref"] for e in call("observe")["elements"]}
    assert again["Save draft"] == by_name["Save draft"]["ref"], "refs stay the same"


@test
def shadow_dom_is_read_and_driven():
    md = open_page("shadow.html")["markdown"]
    for text in ["Slotted post title", "Light body text", "Shadow-only credit line"]:
        assert text in md, md
    vote = next(e for e in call("observe")["elements"] if e["name"] == "Upvote")
    call("act", {"actions": [{"action": "click", "target": vote["ref"]}]})
    assert page("return document.getElementById('clicked').textContent") == "voted true"


@test
def scripts_wait_while_a_password_is_filled():
    # As a password manager extension would: a value Harbor did not type and cannot scrub.
    open_page("form.html")
    page("document.querySelector('#pw').value = 'hunter2'; return true")
    refused = call("evaluate", {"code": "return document.querySelector('#pw').value"}, expect_error=True)
    assert "password" in refused.lower() and "hunter2" not in refused, refused
    acted = call("act", {"actions": [{"action": "eval", "code": "return 1"}]}, expect_error=True)
    assert "password" in acted.lower(), acted
    open_page("article.html")
    assert page("return 1") == 1, "a new page lets scripts run again"


@test
def native_clicks_are_trusted():
    open_page("form.html")
    ref = next(e["ref"] for e in call("observe")["elements"] if e["name"] == "Save draft")
    call("act", {"actions": [{"action": "click", "target": ref}, {"action": "click", "target": "#far-btn"},
                             {"action": "click", "target": "text=Inside frame"}]})
    state = page("return {saved: window.saved, far: window.farClicked, inner: window.innerClicked,"
                 " trusted: events.filter(e => e.type === 'click').every(e => e.trusted)}")
    assert state == {"saved": 1, "far": True, "inner": True, "trusted": True}, state


@test
def typing_is_trusted_input():
    open_page("form.html")
    call("act", {"actions": [
        {"action": "fill", "target": "#name", "text": "Ada Lovelace"},
        {"action": "type", "target": "#name", "text": " Jr"},
        {"action": "fill", "target": "#notes", "text": "line one"},
        {"action": "type", "target": "#editor", "text": "rich"},
        {"action": "select", "target": "#country", "value": "Germany"},
        {"action": "check", "target": "#terms"},
    ]})
    state = page("return {name: document.getElementById('name').value, notes: document.getElementById('notes').value,"
                 " editor: document.getElementById('editor').textContent, country: document.getElementById('country').value,"
                 " terms: document.getElementById('terms').checked,"
                 " typed: events.filter(e => e.type === 'input' && e.id !== 'country').every(e => e.trusted)}")
    assert state == {"name": "Ada Lovelace Jr", "notes": "line one", "editor": "rich", "country": "de",
                     "terms": True, "typed": True}, state


@test
def keys_scroll_and_waits():
    open_page("form.html")
    result = call("act", {"actions": [
        {"action": "scroll", "target": "bottom"},
        {"action": "eval", "code": "return scrollY > 500", "as": "scrolled"},
        {"action": "scroll", "target": "top", "human": True},
        {"action": "fill", "target": "#q", "text": "hello"},
        {"action": "press", "key": "Enter", "target": "#q"},
        {"action": "waitForUrl", "url": "q=hello"},
        {"action": "waitFor", "target": "text=Harbor Agent"},
    ]})
    assert result["ok"] and result["vars"]["scrolled"] is True, result
    assert page("return location.search") == "?q=hello"


@test
def covered_targets_are_reported():
    open_page("form.html")
    page("showCover(); return true")
    text = call("act", {"actions": [{"action": "click", "target": "#covered"}]}, expect_error=True)
    assert "covers the target" in text, text
    assert page("return !!window.coveredClicked") is False


@test
def hover_reaches_script_handlers():
    open_page("form.html")
    call("act", {"actions": [{"action": "hover", "target": "#hover-target"}]})
    assert page("return document.getElementById('hover-state').textContent") == "hovered"


@test
def hover_applies_css_hover_styles():
    open_page("form.html")
    other, other_base = serve_fixtures()
    try:
        page(f"const link = document.createElement('link'); link.rel = 'stylesheet'; link.href = '{other_base}/hover.css';"
             " document.head.append(link); await new Promise(r => { link.onload = r; link.onerror = r; }); return true")
        outline = "return getComputedStyle(document.querySelector('#hover-target')).outlineColor"
        background = "return getComputedStyle(document.querySelector('#save')).backgroundColor"
        call("act", {"actions": [{"action": "hover", "target": "#hover-target"}]})
        assert page(outline) == "rgb(255, 0, 0)", page(outline)
        call("act", {"actions": [{"action": "hover", "target": "#save"}]})
        assert page(outline) != "rgb(255, 0, 0)", "the first element is no longer hovered"
        if os.environ.get("HARBOR_AGENT_CONFIG") == "Release":
            # Release fetches stylesheets from public hosts only, never 127.0.0.1.
            assert page(background) != "rgb(0, 128, 0)", "Release fetched a stylesheet from this Mac"
            return
        assert page(background) == "rgb(0, 128, 0)", "a :hover rule from another origin's stylesheet applies"
    finally:
        other.shutdown()


@test
def dialogs_are_answered_and_logged():
    open_page("form.html")
    call("act", {"actions": [{"action": "click", "target": "#dlg"}]})
    first = call("dialogs")
    kinds = [(e["kind"], e["answer"]) for e in first["entries"]][-3:]
    assert kinds == [("confirm", "dismissed"), ("prompt", "dismissed"), ("alert", "ok")], kinds
    call("dialogs", {"accept": True, "promptText": "agent007"})
    call("act", {"actions": [{"action": "click", "target": "#dlg"}]})
    assert page("return [window.confirmed, window.prompted]") == [True, "agent007"]


@test
def upload_uses_the_page_picker():
    os.makedirs(os.path.join(FILES, "uploads"), exist_ok=True)
    for name, body in [("a.txt", "hello harbor"), ("b.txt", "second")]:
        with open(os.path.join(FILES, "uploads", name), "w") as f:
            f.write(body)
    open_page("form.html")
    result = call("upload", {"target": "input[type=file]", "files": ["uploads/a.txt", "uploads/b.txt"]})
    assert result["files"] == ["a.txt", "b.txt"], result
    assert page("return window.files") == ["a.txt:12", "b.txt:6"]
    call("upload", {"target": "input[type=file]", "files": ["../../etc/hosts"]}, expect_error=True)
    no_input = call("upload", {"target": "#save", "files": ["uploads/a.txt"]}, expect_error=True)
    assert "did not take files dropped" in no_input, no_input
    # Any other path the person has waits for their OK, naming the file and the site.
    outside = os.path.join("/tmp", f"harbor-e2e-{os.getpid()}.txt")
    with open(outside, "w") as f:
        f.write("from tmp")
    try:
        held = call("upload", {"target": "input[type=file]", "files": [outside]})
        assert held.get("needs_approval") and outside in held["action"] and "127.0.0.1" in held["action"], held
    finally:
        os.remove(outside)
    # Never where keys and sign-ins live, however the path is written.
    for refused in ["~/.ssh/id_ed25519", "~/Library/Keychains/login.keychain-db", "/etc/hosts",
                    f"/.nofollow{os.path.expanduser('~')}/.zshrc", "~/Projects/app/.env"]:
        text = call("upload", {"target": "input[type=file]", "files": [refused]}, expect_error=True)
        assert "does not upload" in text, text


@test
def upload_drops_on_a_drop_zone():
    open_page("form.html")
    result = call("upload", {"target": "#dropzone", "files": ["uploads/a.txt", "uploads/b.txt"]})
    assert result.get("dropped") and result["files"] == ["a.txt", "b.txt"], result
    deadline = time.time() + 3
    while time.time() < deadline and not page("return window.dropped || null"):
        time.sleep(0.1)
    assert page("return window.dropped") == ["a.txt:12:hello", "b.txt:6:secon"], page("return window.dropped")


@test
def screenshots_full_page_and_marks():
    open_page("form.html")
    plain = call("screenshot", {"maxWidth": 800})["images"][0]
    assert plain[:2] == b"\xff\xd8", "a JPEG"
    full = call("screenshot", {"fullPage": True, "maxWidth": 600})["images"][0]
    assert len(full) > 1000
    marked = call("screenshot", {"marks": True})
    assert marked["images"] and "textbox \"Full name\"" in marked["text"]


@test
def ocr_reads_canvas_text():
    open_page("canvas.html")
    lines = [l["text"] for l in call("ocr")["lines"]]
    assert "INVOICE 4821" in lines, lines


@test
def webmcp_tools():
    open_page("webmcp.html")
    tools = {t["name"] for t in call("site_tools")["tools"]}
    assert tools == {"add_to_cart", "search_products"}, tools
    added = call("site_tool_call", {"name": "add_to_cart", "arguments": {"item": "apples", "qty": 3}})
    assert added["content"][0]["text"] == "Added 3 apples"
    assert page("return document.getElementById('cart').textContent") == "3 items"
    assert page("return document.modelContext === navigator.modelContext") is True


@test
def jobs_crawl_and_batch_read():
    job = call("crawl", {"url": f"{BASE}/list.html", "limit": 5, "dir": "e2e-crawl"})
    done = wait_job(job["job"])
    assert done["state"] == "done" and done["result"]["pages"] == 4, done
    index = [json.loads(l) for l in open(os.path.join(FILES, "e2e-crawl", "index.jsonl"))]
    assert {os.path.basename(i["url"]) for i in index} == {"list.html", "p1.html", "p2.html", "article.html"}
    batch = call("read", {"urls": [f"{BASE}/p1.html", f"{BASE}/p2.html"]})
    pages = wait_job(batch["job"])["result"]["pages"]
    assert [p.get("title") for p in pages] == ["Page 1", "Page 2"], pages
    cancelled = call("crawl", {"url": f"{BASE}/list.html", "limit": 50, "dir": "e2e-crawl2"})
    assert call("job_cancel", {"job": cancelled["job"]})["state"] == "cancelled"


@test
def tasks_scope_approvals_handoff_replay():
    task = call("task_start", {"title": "E2E task", "goal": "Fill in my name", "url": f"{BASE}/form.html",
                               "allowedOrigins": ["127.0.0.1"]})["task"]
    held = call("act", {"task": task, "actions": [{"action": "fill", "target": "#name", "text": "Ada"},
                                                  {"action": "click", "target": "#buy"}]})
    assert held["needs_approval"] and held["results"][1]["reason"] == "Spends money", held
    assert call("approval_wait", {"approval": held["needs_approval"], "timeout": 1})["decision"] == "pending"
    state = call("act", {"task": task, "actions": [{"action": "getText", "target": "#order-state"}]})
    assert state["results"][0]["value"] == "no order", "nothing happened before approval"
    buy = next(e for e in call("observe", {"task": task})["elements"] if e["name"] == "Place order")
    by_point = call("act", {"task": task, "actions": [{"action": "click", "x": buy["x"] + buy["w"] // 2, "y": buy["y"] + buy["h"] // 2}]})
    assert by_point["needs_approval"] and by_point["results"][0]["reason"] == "Spends money", "a click by position is judged too"
    blocked = call("act", {"task": task, "actions": [{"action": "navigate", "url": "https://example.com/"}]}, expect_error=True)
    assert "outside this task's allowed sites" in blocked
    call("task_start", {"title": "E2E", "confirm": "never"}, expect_error=True)
    steps = call("task_replay", {"task": task})["steps"]
    assert [s["tool"] for s in steps][:2] == ["act", "act"] and steps[0]["ok"] is False, steps[:2]
    call("task_handoff", {"task": task, "reason": "Sign in"})
    paused = call("act", {"task": task, "actions": [{"action": "click", "target": "#save"}]}, expect_error=True)
    assert "the person has control" in paused
    assert call("task_wait", {"task": task, "timeout": 1})["status"] == "needs_you"
    # The agent may give up on a step it handed over; the person's tab stays as it is.
    ended = call("task_end", {"task": task, "outcome": "failed", "summary": "No sign-in", "closeTab": True})
    assert ended["status"] == "failed"
    call("task_end", {"task": task, "outcome": "done"}, expect_error=True)
    removed = call("closeTabs", {"regular": True})
    refusal = call("observe", expect_error=True)
    assert "belongs to task" in refusal and "which has ended" in refusal, (refusal, removed)


@test
def calls_without_task_leave_task_tabs_alone():
    task = call("task_start", {"title": "E2E owner", "url": f"{BASE}/form.html"})["task"]
    call("task_handoff", {"task": task, "reason": "Look"})  # makes it the Agent space's current tab
    for tool, args in [("observe", {}), ("evaluate", {"code": "return 1"}), ("readPageContent", {})]:
        text = call(tool, args, expect_error=True)
        assert "belongs to task" in text, (tool, text)
    script = call("act", {"task": task, "actions": [{"action": "eval", "code": "return 1"}]}, expect_error=True)
    assert "the person has control" in script
    call("createTab", {"url": f"{BASE}/article.html"})
    assert call("evaluate", {"code": "return 2"}) == 2, "a tab of its own is free"


@test
def scripts_in_tasks_need_approval():
    task = call("task_start", {"title": "E2E scripts", "url": f"{BASE}/form.html"})["task"]
    held = call("act", {"task": task, "actions": [{"action": "eval", "code": "document.getElementById('buy').click(); return 1"}]})
    assert held["needs_approval"] and "Runs a script" in held["results"][0]["reason"], held
    state = call("act", {"task": task, "actions": [{"action": "getText", "target": "#order-state"}]})
    assert state["results"][0]["value"] == "no order", "the script did not run"
    call("task_end", {"task": task, "outcome": "done", "closeTab": True})


@test
def vault_metadata_only():
    names = {s["name"] for s in call("secrets")}
    assert all("value" not in s for s in call("secrets")), "never a value"
    if "e2e_password" not in names:
        raise Skip("no e2e_password in the copy's vault (see the header of this file)")
    if True:
        open_page("form.html")
        try:
            call("act", {"actions": [{"action": "fill", "target": "#pw", "text": "{{secret:e2e_password}}"}]})
        except ToolError as error:
            if "keychain" in str(error) or "may not read secret" in str(error):
                raise Skip(f"keychain unavailable: {str(error)[-120:]}")
            raise
        assert call("act", {"actions": [{"action": "getValue", "target": "#pw"}]})["results"][0]["value"] == "••••"
        refused = call("evaluate", {"code": "return document.getElementById('pw').value"}, expect_error=True)
        assert "scripts wait until the page changes" in refused, refused
        call("act", {"actions": [{"action": "eval", "code": "return 1"}]}, expect_error=True)
        text = call("act", {"actions": [{"action": "fill", "target": "#name", "text": "{{secret:e2e_wrong_site}}"}]}, expect_error=True)
        assert "not allowed on 127.0.0.1" in text
        smuggled = call("act", {"actions": [{"action": "eval", "code": "return '{{secret:e2e_password}}'", "as": "x"},
                                            {"action": "fill", "target": "#name", "text": "${vars.x}"}]}, expect_error=True)
        assert "must be written in the step" in smuggled or "scripts wait" in smuggled, smuggled
        open_page("article.html")
        assert page("return 3") == 3, "a new page lets scripts run again"
        unknown = call("act", {"actions": [{"action": "fill", "target": "#name", "text": "{{secret:nope_missing}}"}]}, expect_error=True)
        assert "No secret named nope_missing" in unknown


@test
def recipes_record_run_heal_repair():
    open_page("recipe.html")
    call("record_start", {"where": "agent"})
    call("act", {"actions": [{"action": "fill", "target": "#title", "text": "Buy milk"}, {"action": "click", "target": "#add"}]})
    time.sleep(1.5)
    recipe = call("record_stop", {"name": "e2e-note", "expose": True})
    assert recipe["vars"] == {"title": "Buy milk"} and [s["action"] for s in recipe["steps"]] == ["navigate", "fill", "click"], recipe
    # Exposed as its own tool.
    assert "recipe_e2e-note" in {t["name"] for t in rpc("tools/list")["tools"]}
    healed = dict(recipe, name="e2e-note-v2", expose=False)
    healed["steps"] = [dict(s) for s in recipe["steps"]] + [{"action": "getText", "target": "#notes", "as": "notes"}]
    healed["steps"][0]["url"] = f"{BASE}/recipe-v2.html"
    call("recipe_save", {"recipe": healed})
    run = wait_job(call("recipe_run", {"name": "e2e-note-v2", "vars": {"title": "Healed"}})["job"])
    assert run["state"] == "done" and run["result"]["healed"] and run["result"]["vars"]["notes"] == "Healed", run
    saved = call("recipe_show", {"name": "e2e-note-v2"})
    assert saved["steps"][1]["target"].startswith("role=textbox"), saved["steps"][1]
    call("recipe_save", {"recipe": {"name": "e2e-fix", "steps": [
        {"action": "navigate", "url": f"{BASE}/recipe.html"}, {"action": "fill", "target": "#title", "text": "Fixed"},
        {"action": "click", "target": "#gone"}, {"action": "getText", "target": "#notes", "as": "notes"}]}})
    job = call("recipe_run", {"name": "e2e-fix"})["job"]
    waiting = wait_job(job)
    assert waiting["state"] == "needs_repair" and waiting["repair"]["step"] == 3, waiting
    elements = json.loads(re.search(r">\n(.*)\n</untrusted", waiting["repair"]["elements"], re.S).group(1))
    ref = next(e["ref"] for e in elements if e["name"] == "Add note")
    call("recipe_repair", {"job": job, "target": ref})
    fixed = wait_job(job)
    assert fixed["state"] == "done" and fixed["result"]["vars"]["notes"] == "Fixed", fixed
    assert call("recipe_show", {"name": "e2e-fix"})["steps"][2]["target"] == '[data-testid="add-note"]'
    call("recipe_save", {"recipe": {"name": "show", "steps": [{"action": "reload"}]}}, expect_error=True)
    for name in ["e2e-note", "e2e-note-v2", "e2e-fix"]:
        call("recipe_delete", {"name": name})


@test
def recipe_control_flow():
    hooks = """
export function shout({ arg }) { return String(arg).toUpperCase(); }
export async function total({ vars }) { return vars.added.length; }
function spin() { while (true) {} }
"""
    steps = [
        {"action": "navigate", "url": f"{BASE}/recipe.html"},
        # Inputs reach the very first steps, before any set or loop.
        {"action": "fill", "target": "#title", "text": "${input.first}"},
        {"action": "getValue", "target": "#title", "as": "firstValue"},
        {"action": "set", "var": "added", "value": []},
        {"foreach": "${vars.items}", "as": "item", "steps": [
            {"when": "item.skip", "steps": [{"action": "log", "message": "skip ${item.name}"}], "else": [
                {"action": "call", "hook": "shout", "arg": "${item.name}", "as": "loud"},
                {"action": "fill", "target": "#title", "text": "${vars.loud}"},
                {"action": "click", "target": "#add"},
                {"action": "set", "var": "count", "expr": "vars.added.length + 1"},
                {"action": "eval", "code": "return [...document.querySelectorAll('#notes li')].map(li => li.textContent)", "as": "added"},
            ]},
        ]},
        {"action": "call", "hook": "total", "as": "total"},
        {"id": "again", "action": "set", "var": "rounds", "expr": "(vars.rounds || 0) + 1"},
        {"when": "vars.rounds < 3", "steps": [{"action": "goto", "target": "again"}]},
        {"action": "click", "target": "#missing", "timeout": 300, "onFail": "continue"},
        {"action": "click", "target": "#also-missing", "timeout": 300, "retry": {"times": 1, "delayMs": 50}, "onFail": "goto:end"},
        {"action": "log", "message": "never logged"},
        {"id": "end", "action": "snapshot", "as": "seen"},
    ]
    call("recipe_save", {"recipe": {"name": "e2e-flow", "hooks": hooks, "vars": {"first": "start", "items": [
        {"name": "milk"}, {"name": "eggs", "skip": True}, {"name": "tea"}]}, "steps": steps}})
    run = wait_job(call("recipe_run", {"name": "e2e-flow"})["job"])
    assert run["state"] == "done", run
    result = run["result"]
    assert result["vars"]["added"] == ["MILK", "TEA"], result["vars"]
    assert result["vars"]["firstValue"] == "start", result["vars"]
    assert result["vars"]["total"] == 2 and result["vars"]["rounds"] == 3 and result["vars"]["count"] == 2, result["vars"]
    assert "skip eggs" in result["log"] and "never logged" not in result["log"], result["log"]
    assert [f["step"].split(". ")[1] for f in result["failed"]] == ["click"], result["failed"]
    assert any(e.get("name") == "Add note" for e in result["vars"]["seen"]), result["vars"]["seen"][:3]
    # A hook that never returns is stopped; a step that names no hook or a goto to nowhere is refused.
    call("recipe_save", {"recipe": {"name": "e2e-spin", "hooks": hooks, "steps": [{"action": "call", "hook": "spin"}]}})
    started = time.time()
    spun = wait_job(call("recipe_run", {"name": "e2e-spin"})["job"], timeout=30)
    assert spun["state"] == "failed" and time.time() - started < 20, spun
    bad = call("recipe_save", {"recipe": {"name": "e2e-bad", "steps": [{"action": "goto", "target": "nowhere"},
                                                                        {"action": "call", "hook": "x"}]}}, expect_error=True)
    assert "names no step id" in bad and "call needs a hook" in bad, bad
    broken = call("recipe_save", {"recipe": {"name": "e2e-bad", "hooks": "function (", "steps": [{"action": "reload"}]}}, expect_error=True)
    assert "hooks do not run" in broken, broken
    for name in ["e2e-flow", "e2e-spin"]:
        call("recipe_delete", {"name": name})


@test
def linkedin_scrapers_and_sign_in():
    # The scrapers on pages shaped like LinkedIn's (the tools themselves only open linkedin.com).
    source = open(os.path.join(HERE, "..", "..", "Harbor", "Managers", "AgentKit", "Resources", "agent-linkedin.js")).read()
    open_page("linkedin-search.html")
    hits = page(source + "\nreturn await scrapeSearch()")["hits"]
    assert [h["profileUrl"] for h in hits] == ["https://www.linkedin.com/in/ada-lovelace/", "https://www.linkedin.com/in/grace-hopper/"], hits
    assert hits[0]["name"] == "Ada Lovelace" and hits[0]["headline"] == "Analyst at Analytical Engines", hits[0]
    assert hits[0]["location"] == "London, England, United Kingdom" and hits[0]["connectionDegree"] == "2nd", hits[0]
    open_page("linkedin-profile.html")
    profile = page(source + "\nreturn await scrapeProfile()")["profile"]
    assert profile["name"] == "Ada Lovelace" and profile["headline"] == "Writing the first program", profile
    assert profile["currentCompany"] == "Analytical Engines" and profile["currentSchool"] == "University of London", profile
    assert profile["location"] == "London, England, United Kingdom" and profile["followers"] == 1234, profile
    assert profile["connections"] == "500+ connections" and profile["latestPost"]["time"] == "2w", profile
    assert profile["latestPost"]["text"].startswith("Notes on the Analytical Engine"), profile["latestPost"]
    # Signed out, the tool says so rather than returning nothing.
    run = call("linkedin_search", {"query": "harbor browser"})
    if run["state"] == "running":
        run = wait_job(run["job"], timeout=60)
    if run["state"] == "done":
        raise Skip("the copy is signed in to LinkedIn; the signed-out message was not checked")
    assert run["state"] == "failed" and "sign in" in run["error"].lower(), run


@test
def watches_and_schedules():
    path = os.path.join(FIXTURES, "watch.html")
    original = open(path).read()
    try:
        open(path, "w").write(original.replace("VALUE", "19 EUR"))
        watch = call("watch", {"url": f"{BASE}/watch.html", "selector": "#price", "every": 5})["id"]
        first = wait_job(call("watch_check", {"id": watch})["job"])
        open(path, "w").write(original.replace("VALUE", "15 EUR"))
        second = wait_job(call("watch_check", {"id": watch})["job"])
        assert second["result"]["changed"] is True and "15 EUR" in second["result"]["sample"], (first, second)
        call("schedule", {"recipe": "nope", "every": 10}, expect_error=True)
        call("recipe_save", {"recipe": {"name": "e2e-sched", "steps": [{"action": "reload"}]}})
        call("schedule", {"recipe": "e2e-sched", "every": 2}, expect_error=True)
        made = call("schedule", {"recipe": "e2e-sched", "at": "07:30"})
        assert made["at"] == "07:30" and "T" in made["next"]
        for item in [watch, made["id"]]:
            call("unschedule", {"id": item})
        call("recipe_delete", {"name": "e2e-sched"})
    finally:
        open(path, "w").write(original)


@test
def schedules_fire_on_their_own():
    """Up to two minutes: a schedule for the next minute, and a new watch's first check."""
    if not os.environ.get("HARBOR_E2E_SLOW"):
        raise Skip("slow; set HARBOR_E2E_SLOW=1")
    call("recipe_save", {"recipe": {"name": "e2e-fire", "steps": [{"action": "navigate", "url": f"{BASE}/article.html"}]}})
    watch = None
    schedule = None
    try:
        watch = call("watch", {"url": f"{BASE}/watch.html", "selector": "body", "every": 60})["id"]
        at = time.strftime("%H:%M", time.localtime(time.time() + 60))
        schedule = call("schedule", {"recipe": "e2e-fire", "at": at})["id"]
        deadline = time.time() + 150
        kinds = set()
        while time.time() < deadline and not {"watch", "recipe"} <= kinds:
            kinds = {j["kind"] for j in call("jobs") if j["title"] in ("e2e-fire", f"{BASE}/watch.html") or j["kind"] == "watch"}
            time.sleep(5)
        assert {"watch", "recipe"} <= kinds, f"the scheduler started {kinds or 'nothing'}"
        run = next(j for j in call("jobs") if j["kind"] == "recipe" and j["title"] == "e2e-fire")
        assert wait_job(run["job"])["state"] == "done"
    finally:
        for item in [watch, schedule]:
            if item:
                call("unschedule", {"id": item})
        call("recipe_delete", {"name": "e2e-fire"})


@test
def extract_degrades_without_apple_intelligence():
    open_page("article.html")
    try:
        answer = call("extract", {"instruction": "List the tools in the table."})
        assert "read" in str(answer) and "crawl" in str(answer), answer
    except ToolError as error:
        assert "Apple Intelligence is not available" in str(error), error


# MARK: - Runner

def main():
    global BASE
    parser = argparse.ArgumentParser()
    parser.add_argument("-k", help="run tests whose name contains this")
    parser.add_argument("--report", help="write a JSON report of the results here")
    options = parser.parse_args()
    server, BASE = serve_fixtures()
    results = []
    for fn in TESTS:
        if options.k and options.k not in fn.__name__:
            continue
        started = time.time()
        try:
            fn()
            status, message = "passed", None
        except Skip as reason:
            status, message = "skipped", str(reason)
        except Exception as error:  # noqa: BLE001 — every failure is reported, the run goes on
            status, message = "failed", f"{type(error).__name__}: {error}\n{traceback.format_exc(limit=3)}"
        seconds = round(time.time() - started, 2)
        results.append({"name": fn.__name__, "status": status, "message": message, "seconds": seconds,
                        "file": "scripts/tests/agent_e2e.py"})
        mark = {"passed": "ok  ", "skipped": "skip", "failed": "FAIL"}[status]
        print(f"{mark} {fn.__name__} ({seconds}s)" + (f"\n     {message.splitlines()[0][:300]}" if message else ""))
    server.shutdown()
    if options.report:
        with open(options.report, "w") as f:
            json.dump(results, f, indent=2)
    failed = [r for r in results if r["status"] == "failed"]
    skipped = [r for r in results if r["status"] == "skipped"]
    print(f"{len(results) - len(failed) - len(skipped)}/{len(results)} passed, {len(skipped)} skipped")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
