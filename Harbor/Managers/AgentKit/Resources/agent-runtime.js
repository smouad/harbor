// Harbor Agent Runtime
//
// Runs in the isolated HarborAgent content world, so the page can neither see nor patch it.
// Swift calls `__harborAgent.call(op, args)` through callAsyncJavaScript (AgentRuntime.swift).
// The DOM is shared with the page; JavaScript globals are not.
(() => {
    if (globalThis.__harborAgent) return;

    // MARK: - Element refs

    // A ref names one element for as long as it lives: observing again keeps the same refs, so
    // an agent's earlier ref still works after the page changed around it.
    let nextRef = 1;
    const refOf = new WeakMap();
    const byRef = new Map();

    function refFor(el) {
        let ref = refOf.get(el);
        if (!ref) {
            ref = "e" + nextRef++;
            refOf.set(el, ref);
        }
        byRef.set(ref, new WeakRef(el));
        return ref;
    }

    // Fields a vault secret was typed into. Their value never leaves this world, and they draw as
    // dots so screenshots and replay frames do not show it either.
    const secretFields = new WeakSet();
    let secretTyped = false;

    function elementForRef(ref) {
        const el = byRef.get(ref)?.deref();
        return el && el.isConnected ? el : null;
    }

    // MARK: - Roles and names

    const INTERACTIVE = [
        "a[href]", "button", "input:not([type=hidden])", "select", "textarea", "summary",
        "[role=button]", "[role=link]", "[role=checkbox]", "[role=radio]", "[role=tab]",
        "[role=menuitem]", "[role=menuitemcheckbox]", "[role=menuitemradio]", "[role=option]",
        "[role=switch]", "[role=combobox]", "[role=textbox]", "[role=searchbox]", "[role=slider]",
        "[role=spinbutton]", "[role=treeitem]", "[contenteditable=''], [contenteditable=true]",
        "[tabindex]:not([tabindex='-1'])", "[onclick]", "label[for]"
    ].join(",");

    const INPUT_ROLES = {
        button: "button", submit: "button", reset: "button", image: "button",
        checkbox: "checkbox", radio: "radio", range: "slider", number: "spinbutton",
        search: "searchbox", file: "button"
    };

    function roleOf(el) {
        const explicit = el.getAttribute("role");
        if (explicit) return explicit.split(" ")[0];
        const tag = el.tagName.toLowerCase();
        switch (tag) {
            case "a": return el.hasAttribute("href") ? "link" : "generic";
            case "button": case "summary": return "button";
            case "select": return el.multiple || el.size > 1 ? "listbox" : "combobox";
            case "textarea": return "textbox";
            case "input": return INPUT_ROLES[(el.type || "text").toLowerCase()] || "textbox";
            case "img": return "img";
            case "h1": case "h2": case "h3": case "h4": case "h5": case "h6": return "heading";
            case "label": return "label";
            default: return el.isContentEditable ? "textbox" : tag;
        }
    }

    function clean(s, max = 120) {
        s = (s || "").replace(/\s+/g, " ").trim();
        return s.length > max ? s.slice(0, max - 1) + "…" : s;
    }

    function labelText(el) {
        if (el.id) {
            const label = document.querySelector(`label[for="${CSS.escape(el.id)}"]`);
            if (label) return label.innerText;
        }
        return el.closest("label")?.innerText || "";
    }

    function nameOf(el) {
        const aria = el.getAttribute("aria-label");
        if (aria) return clean(aria);
        const labelledBy = el.getAttribute("aria-labelledby");
        if (labelledBy) {
            const text = labelledBy.split(/\s+/).map(id => document.getElementById(id)?.innerText || "").join(" ");
            if (text.trim()) return clean(text);
        }
        const tag = el.tagName.toLowerCase();
        if (tag === "input" || tag === "textarea" || tag === "select") {
            const type = (el.type || "").toLowerCase();
            if (["button", "submit", "reset"].includes(type) && el.value) return clean(el.value);
            return clean(labelText(el) || el.placeholder || el.title || el.name || "");
        }
        if (tag === "img") return clean(el.alt || el.title || "");
        const text = el.innerText || el.textContent || "";
        if (text.trim()) return clean(text);
        const img = el.querySelector("img[alt]");
        return clean(img?.alt || el.title || "");
    }

    function isVisible(el) {
        const rect = el.getBoundingClientRect();
        if (rect.width < 1 || rect.height < 1) return false;
        const style = getComputedStyle(el);
        return style.visibility !== "hidden" && style.display !== "none" && Number(style.opacity) > 0.01;
    }

    // Collects elements from the document and its same-origin frames, with each frame's offset
    // so rects come out in the top viewport.
    function collect(selector, root = document, offset = { x: 0, y: 0 }, out = []) {
        for (const el of root.querySelectorAll(selector)) out.push({ el, offset });
        for (const frame of root.querySelectorAll("iframe, frame")) {
            let doc = null;
            try { doc = frame.contentDocument; } catch { doc = null; }
            if (!doc) continue;
            const r = frame.getBoundingClientRect();
            collect(selector, doc, { x: offset.x + r.left + frame.clientLeft, y: offset.y + r.top + frame.clientTop }, out);
        }
        return out;
    }

    function frameOffset(el) {
        let x = 0, y = 0;
        let win = el.ownerDocument.defaultView;
        while (win && win !== window && win.frameElement) {
            const r = win.frameElement.getBoundingClientRect();
            x += r.left + win.frameElement.clientLeft;
            y += r.top + win.frameElement.clientTop;
            win = win.parent;
        }
        return { x, y };
    }

    function describe(el, offset = frameOffset(el)) {
        const r = el.getBoundingClientRect();
        const tag = el.tagName.toLowerCase();
        const d = { ref: refFor(el), role: roleOf(el), name: nameOf(el), tag };
        if (tag === "input") d.type = (el.type || "text").toLowerCase();
        if (tag === "a" && el.href) d.href = el.href;
        if ("value" in el && tag !== "button" && el.value) {
            d.value = d.type === "password" || secretFields.has(el) ? "••••" : clean(String(el.value), 200);
        }
        if (el.checked !== undefined && (d.type === "checkbox" || d.type === "radio")) d.checked = el.checked;
        else if (el.getAttribute("aria-checked")) d.checked = el.getAttribute("aria-checked") === "true";
        if (el.disabled || el.getAttribute("aria-disabled") === "true") d.disabled = true;
        d.x = Math.round(r.left + offset.x);
        d.y = Math.round(r.top + offset.y);
        d.w = Math.round(r.width);
        d.h = Math.round(r.height);
        if (d.y + d.h < 0 || d.y > innerHeight || d.x + d.w < 0 || d.x > innerWidth) d.offscreen = true;
        return d;
    }

    function observe({ filter = "", limit = 150, viewportOnly = false } = {}) {
        const needle = filter.toLowerCase();
        const seen = new Set();
        const elements = [];
        for (const { el, offset } of collect(INTERACTIVE)) {
            if (seen.has(el) || !isVisible(el)) continue;
            seen.add(el);
            // A label adds nothing beside its control; it stays when the control is hidden
            // (a styled checkbox), since then the label is what a person clicks.
            if (el.tagName === "LABEL" && el.control && isVisible(el.control)) continue;
            const d = describe(el, offset);
            if (viewportOnly && d.offscreen) continue;
            if (needle && !`${d.role} ${d.name} ${d.value || ""} ${d.href || ""}`.toLowerCase().includes(needle)) continue;
            elements.push(d);
            if (elements.length >= limit) break;
        }
        return { url: location.href, title: document.title, viewport: { w: innerWidth, h: innerHeight }, elements };
    }

    // MARK: - Targets

    // A target is a ref (e7), `xpath=…` or `//…`, `text=…`, `role=button[name="Save"]`, or CSS.
    function resolveAll(target) {
        target = String(target || "").trim();
        if (!target) return [];
        if (/^e\d+$/.test(target)) {
            const el = elementForRef(target);
            return el ? [el] : [];
        }
        if (target.startsWith("xpath=") || target.startsWith("//") || target.startsWith("(//")) {
            const expr = target.startsWith("xpath=") ? target.slice(6) : target;
            const result = document.evaluate(expr, document, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
            const out = [];
            for (let i = 0; i < result.snapshotLength; i++) out.push(result.snapshotItem(i));
            return out.filter(n => n.nodeType === 1);
        }
        if (target.startsWith("text=")) return byText(target.slice(5));
        const role = target.match(/^role=([\w-]+)(?:\[name=(?:"([^"]*)"|'([^']*)')\])?$/);
        if (role) {
            const wanted = (role[2] ?? role[3] ?? "").toLowerCase();
            return collect(INTERACTIVE + ",h1,h2,h3,h4,h5,h6,img").map(c => c.el)
                .filter(el => roleOf(el) === role[1] && (!wanted || nameOf(el).toLowerCase() === wanted) && isVisible(el));
        }
        try {
            return collect(target).map(c => c.el);
        } catch {
            return [];
        }
    }

    // Exact visible-name matches first, then the smallest element containing the text.
    function byText(text) {
        const needle = clean(text).toLowerCase();
        if (!needle) return [];
        const candidates = collect(INTERACTIVE).map(c => c.el).filter(isVisible);
        const exact = candidates.filter(el => nameOf(el).toLowerCase() === needle);
        if (exact.length) return exact;
        const partial = candidates.filter(el => nameOf(el).toLowerCase().includes(needle));
        if (partial.length) return partial;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        const hits = [];
        while (walker.nextNode()) {
            if (walker.currentNode.textContent.toLowerCase().includes(needle)) {
                const el = walker.currentNode.parentElement;
                if (el && isVisible(el)) hits.push(el);
            }
        }
        return hits;
    }

    function resolve(target) {
        const all = resolveAll(target);
        return all.find(isVisible) || all[0] || null;
    }

    function need(target) {
        const el = resolve(target);
        if (!el) throw new Error(`No element matches ${JSON.stringify(target)}`);
        return el;
    }

    // MARK: - Geometry for native input

    // Scrolls the element into view and returns the point to press, in top-viewport CSS pixels,
    // plus whether that point actually lands on the element (nothing covers it).
    function point({ target, x, y }) {
        if (target === undefined || target === null || target === "") {
            return { x, y, hit: true, viewport: { w: innerWidth, h: innerHeight } };
        }
        const el = need(target);
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        const r = el.getBoundingClientRect();
        const offset = frameOffset(el);
        const px = r.left + offset.x + r.width / 2;
        const py = r.top + offset.y + r.height / 2;
        let top = document.elementFromPoint(px, py);
        // Descend into same-origin frames to find what is really under the point.
        while (top && (top.tagName === "IFRAME" || top.tagName === "FRAME")) {
            let doc = null;
            try { doc = top.contentDocument; } catch { doc = null; }
            if (!doc) break;
            const fr = top.getBoundingClientRect();
            top = doc.elementFromPoint(px - fr.left - top.clientLeft, py - fr.top - top.clientTop);
        }
        const hit = !!top && (top === el || el.contains(top) || top.contains(el) || (el.tagName === "LABEL" && el.control === top));
        return {
            x: px, y: py, hit, covering: hit || !top ? undefined : describe(top),
            element: describe(el, offset), viewport: { w: innerWidth, h: innerHeight }
        };
    }

    // MARK: - DOM actions

    function setNativeValue(el, value) {
        const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype
            : el instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(proto, "value")?.set;
        if (setter) setter.call(el, value); else el.value = value;
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
    }

    function focusEditable(el) {
        if (el.tagName === "LABEL" && el.control) el = el.control;
        el.focus({ preventScroll: false });
        return el;
    }

    // Types through the editor, which reports the input as trusted (isTrusted: true), the way
    // a person's typing arrives. Falls back to the value setter when the editor refuses.
    function insertText({ target, text = "", clear = false, secret = false, host }) {
        const el = focusEditable(need(target));
        const doc = el.ownerDocument;
        if (secret) {
            // The page may have navigated since Harbor checked the site the secret is for.
            if (doc.location.hostname !== host) throw new Error(`The page is no longer on ${host}`);
            secretFields.add(el);
            secretTyped = true;
            if (el.type !== "password") el.style.setProperty("-webkit-text-security", "disc", "important");
        }
        if (clear) {
            if (typeof el.select === "function" && "value" in el) el.select();
            else doc.execCommand("selectAll");
        } else if ("value" in el && typeof el.setSelectionRange === "function") {
            try { el.setSelectionRange(el.value.length, el.value.length); } catch { /* not a text type */ }
        }
        const before = "value" in el ? el.value : el.textContent;
        const typed = text === "" ? (clear ? doc.execCommand("delete") : true) : doc.execCommand("insertText", false, text);
        const after = "value" in el ? el.value : el.textContent;
        if (!typed || (text !== "" && after === before)) {
            if ("value" in el) setNativeValue(el, clear ? text : before + text);
            else el.textContent = clear ? text : before + text;
            return { trusted: false };
        }
        return { trusted: true };
    }

    function select({ target, value }) {
        let el = need(target);
        if (el.tagName !== "SELECT") el = el.querySelector("select") || el;
        if (el.tagName !== "SELECT") throw new Error("Target is not a <select>");
        const wanted = (Array.isArray(value) ? value : [value]).map(String);
        let matched = 0;
        for (const option of el.options) {
            const on = wanted.includes(option.value) || wanted.includes(option.label) || wanted.includes(option.text.trim());
            if (on) matched++;
            if (el.multiple) option.selected = on;
            else if (on) { el.selectedIndex = option.index; break; }
        }
        if (!matched) throw new Error(`No option matches ${JSON.stringify(value)}`);
        el.dispatchEvent(new Event("input", { bubbles: true }));
        el.dispatchEvent(new Event("change", { bubbles: true }));
        return { value: el.value };
    }

    function checkedState(el) {
        if ("checked" in el && (el.type === "checkbox" || el.type === "radio")) return el.checked;
        const aria = el.getAttribute("aria-checked") ?? el.getAttribute("aria-pressed");
        return aria === "true";
    }

    let hovered = null;
    const documentToken = Math.random().toString(36).slice(2);

    // Counts trusted presses on a target's document, so Harbor can tell a native click landed.
    const pressCounts = new WeakMap();
    function armPress(doc) {
        if (pressCounts.has(doc)) return;
        pressCounts.set(doc, 0);
        doc.addEventListener("mousedown", e => { if (e.isTrusted) pressCounts.set(doc, pressCounts.get(doc) + 1); }, true);
    }

    function domClick(el) {
        const r = el.getBoundingClientRect();
        const opts = { bubbles: true, cancelable: true, composed: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, button: 0 };
        el.dispatchEvent(new PointerEvent("pointerdown", opts));
        el.dispatchEvent(new MouseEvent("mousedown", opts));
        el.dispatchEvent(new PointerEvent("pointerup", opts));
        el.dispatchEvent(new MouseEvent("mouseup", opts));
        el.click();
    }

    const ops = {
        observe,
        point,
        describe: ({ target }) => describe(need(target)),
        // Trusted presses seen so far on the target's document (starts watching on first call),
        // with this document's token: a new token means the page changed under the click.
        presses: ({ target }) => {
            const el = target ? resolve(target) : null;
            const doc = el ? el.ownerDocument : document;
            armPress(doc);
            return { count: pressCounts.get(doc), document: documentToken };
        },
        // For Swift code that works on the element itself inside this world (upload).
        resolveRef: ({ ref }) => need(ref),
        exists: ({ target, visible = true }) => {
            const el = resolve(target);
            return !!el && (!visible || isVisible(el));
        },
        insertText,
        select,
        // Resolves once the target appears (or goes away), watching DOM changes instead of polling.
        waitFor: ({ target, timeout = 10000, visible = true, gone = false }) => new Promise(done => {
            const ready = () => {
                const el = resolve(target);
                const present = !!el && (!visible || isVisible(el));
                return gone ? !present : present;
            };
            if (ready()) return done(true);
            let timer = 0;
            const observer = new MutationObserver(() => {
                if (!ready()) return;
                observer.disconnect();
                clearTimeout(timer);
                done(true);
            });
            observer.observe(document, { subtree: true, childList: true, attributes: true, characterData: true });
            timer = setTimeout(() => { observer.disconnect(); done(ready()); }, timeout);
        }),
        click: ({ target }) => { domClick(need(target)); return true; },
        setValue: ({ target, value = "", secret = false, host }) => {
            const el = focusEditable(need(target));
            if (secret) {
                if (el.ownerDocument.location.hostname !== host) throw new Error(`The page is no longer on ${host}`);
                secretFields.add(el);
                secretTyped = true;
                if (el.type !== "password") el.style.setProperty("-webkit-text-security", "disc", "important");
            }
            setNativeValue(el, String(value));
            return true;
        },
        // Whether a vault secret was typed in this document; Harbor holds scripts back until
        // the person approves or the page moves on.
        secretTyped: () => secretTyped,
        checked: ({ target }) => checkedState(need(target)),
        check: ({ target, on = true }) => {
            const el = need(target);
            if (checkedState(el) !== on) domClick(el);
            return checkedState(el);
        },
        focus: ({ target }) => { focusEditable(need(target)); return true; },
        // Pointer events for hover menus driven by script. CSS :hover follows only a real pointer.
        hover: ({ target, x, y }) => {
            let el = target ? need(target) : document.elementFromPoint(x, y);
            if (!el) return false;
            const r = el.getBoundingClientRect();
            const at = target ? { clientX: r.left + r.width / 2, clientY: r.top + r.height / 2 } : { clientX: x, clientY: y };
            const previous = hovered?.deref();
            if (previous && previous !== el && previous.isConnected) {
                for (const type of ["pointerout", "pointerleave", "mouseout", "mouseleave"]) {
                    const Ctor = type.startsWith("pointer") ? PointerEvent : MouseEvent;
                    previous.dispatchEvent(new Ctor(type, { bubbles: !type.endsWith("leave"), composed: true, ...at }));
                }
            }
            for (const type of ["pointerover", "pointerenter", "mouseover", "mouseenter", "pointermove", "mousemove"]) {
                const Ctor = type.startsWith("pointer") ? PointerEvent : MouseEvent;
                el.dispatchEvent(new Ctor(type, { bubbles: !type.endsWith("enter"), composed: true, ...at }));
            }
            hovered = new WeakRef(el);
            return true;
        },
        scrollIntoView: ({ target }) => { need(target).scrollIntoView({ block: "center", behavior: "instant" }); return true; },
        scroll: ({ target, deltaY }) => {
            if (target === "top") scrollTo({ top: 0, behavior: "instant" });
            else if (target === "bottom") scrollTo({ top: document.documentElement.scrollHeight, behavior: "instant" });
            else if (target) need(target).scrollBy({ top: deltaY ?? innerHeight * 0.8, behavior: "instant" });
            else scrollBy({ top: deltaY ?? innerHeight * 0.8, behavior: "instant" });
            return { scrollY: Math.round(scrollY), max: document.documentElement.scrollHeight - innerHeight };
        },
        submit: ({ target }) => {
            const el = need(target);
            const form = el.tagName === "FORM" ? el : el.form || el.closest("form");
            if (!form) throw new Error("Target is not in a form");
            form.requestSubmit ? form.requestSubmit() : form.submit();
            return true;
        },
        getText: ({ target }) => target ? need(target).innerText : document.body.innerText,
        getValue: ({ target }) => {
            const el = need(target);
            if (secretFields.has(el) || el.type === "password") return "••••";
            return "value" in el ? el.value : el.textContent;
        },
        isEditable: ({ target }) => {
            const el = need(target);
            return el.isContentEditable || ["INPUT", "TEXTAREA"].includes(el.tagName);
        },
        fileInput: ({ target }) => {
            const el = need(target);
            const input = el.matches("input[type=file]") ? el
                : el.querySelector("input[type=file]") || (el.control?.type === "file" ? el.control : null);
            if (!input) throw new Error("No file input at or inside the target; target the input itself (observe lists hidden ones only when visible, so use a selector such as input[type=file])");
            return describe(input);
        },
        markdown: args => markdown(args),
        marks: ({ limit = 80 } = {}) => observe({ limit, viewportOnly: true }).elements.filter(e => !e.disabled),
        selectors: ({ target }) => selectorsFor(need(target)),
        recordStart: () => recorder.start(),
        recordStop: () => recorder.stop(),
        pageState: () => ({ url: location.href, title: document.title, ready: document.readyState, scrollY: Math.round(scrollY) }),
        textHash: ({ target }) => {
            const el = target ? resolve(target) : document.body;
            const text = el ? el.innerText.replace(/\s+/g, " ").trim() : "";
            let h = 2166136261;
            for (let i = 0; i < text.length; i++) h = Math.imul(h ^ text.charCodeAt(i), 16777619) >>> 0;
            return { hash: h.toString(16), length: text.length, sample: text.slice(0, 400) };
        }
    };

    // MARK: - Markdown

    const SKIP = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS", "IFRAME", "OBJECT", "EMBED", "HEAD", "LINK", "META"]);
    const CHROME = "nav, footer, aside, [role=navigation], [role=contentinfo], [role=complementary], [aria-hidden=true], dialog:not([open])";

    function mainRoot(selector) {
        if (selector) return need(selector);
        const candidates = [...document.querySelectorAll("main, article, [role=main]")].filter(isVisible);
        if (candidates.length) return candidates.sort((a, b) => b.innerText.length - a.innerText.length)[0];
        return document.body;
    }

    function markdown({ selector, links = false, maxLength = 40000 } = {}) {
        const root = mainRoot(selector);
        const dropChrome = !selector && root === document.body;
        const linkList = [];
        const seenLinks = new Set();
        const esc = s => s.replace(/([\\`*_[\]])/g, "\\$1");

        function inline(node) {
            let out = "";
            for (const child of node.childNodes) out += render(child, 0, true);
            return out.replace(/\s+/g, " ");
        }

        function listItems(list, depth) {
            let out = "";
            let n = Number(list.getAttribute("start") || 1);
            for (const li of list.children) {
                if (li.tagName !== "LI") continue;
                const marker = list.tagName === "OL" ? `${n++}.` : "-";
                let body = "";
                let nested = "";
                for (const child of li.childNodes) {
                    if (child.nodeType === 1 && (child.tagName === "UL" || child.tagName === "OL")) nested += listItems(child, depth + 1);
                    else body += render(child, depth, true);
                }
                out += `${"  ".repeat(depth)}${marker} ${body.replace(/\s+/g, " ").trim()}\n${nested}`;
            }
            return out;
        }

        function table(el) {
            const rows = [...el.querySelectorAll("tr")].filter(tr => tr.closest("table") === el);
            if (!rows.length) return "";
            const cells = rows.map(tr => [...tr.children].map(td => inline(td).trim().replace(/\|/g, "\\|")));
            const width = Math.max(...cells.map(r => r.length));
            const line = r => "| " + Array.from({ length: width }, (_, i) => r[i] || "").join(" | ") + " |";
            return "\n\n" + [line(cells[0]), "|" + " --- |".repeat(width), ...cells.slice(1).map(line)].join("\n") + "\n\n";
        }

        function render(node, depth = 0, inLine = false) {
            if (node.nodeType === 3) return node.textContent;
            if (node.nodeType !== 1) return "";
            const el = node;
            if (SKIP.has(el.tagName) || el.hidden) return "";
            if (dropChrome && el.matches(CHROME)) return "";
            const style = el.checkVisibility ? null : getComputedStyle(el);
            if (el.checkVisibility ? !el.checkVisibility({ visibilityProperty: true }) : style.display === "none") return "";
            const tag = el.tagName;
            switch (tag) {
                case "H1": case "H2": case "H3": case "H4": case "H5": case "H6": {
                    const text = inline(el).trim();
                    return text ? `\n\n${"#".repeat(Number(tag[1]))} ${text}\n\n` : "";
                }
                case "P": case "SECTION": case "DIV": case "ARTICLE": case "MAIN": case "HEADER": case "FIGURE": {
                    let inner = "";
                    for (const child of el.childNodes) inner += render(child, depth, inLine);
                    return inLine ? inner : `\n\n${inner.trim()}\n\n`;
                }
                case "BR": return inLine ? " " : "\n";
                case "HR": return "\n\n---\n\n";
                case "STRONG": case "B": { const t = inline(el).trim(); return t ? `**${t}**` : ""; }
                case "EM": case "I": { const t = inline(el).trim(); return t ? `*${t}*` : ""; }
                case "CODE": return el.closest("pre") ? el.textContent : "`" + el.textContent.replace(/`/g, "\\`") + "`";
                case "PRE": {
                    const lang = (el.querySelector("code")?.className.match(/language-([\w+-]+)/) || [])[1] || "";
                    return `\n\n\`\`\`${lang}\n${el.innerText.replace(/\n$/, "")}\n\`\`\`\n\n`;
                }
                case "A": {
                    const text = inline(el).trim();
                    const href = el.href;
                    if (!href || href.startsWith("javascript:")) return text;
                    if (links && !seenLinks.has(href)) { seenLinks.add(href); linkList.push({ text: clean(text, 100), href }); }
                    return text ? `[${esc(text)}](${href})` : "";
                }
                case "IMG": {
                    const alt = clean(el.alt || "", 100);
                    return el.currentSrc || el.src ? `![${esc(alt)}](${el.currentSrc || el.src})` : "";
                }
                case "UL": case "OL": return `\n\n${listItems(el, depth)}\n`;
                case "BLOCKQUOTE": {
                    const inner = [...el.childNodes].map(c => render(c, depth)).join("").trim();
                    return "\n\n" + inner.split("\n").map(l => "> " + l).join("\n") + "\n\n";
                }
                case "TABLE": return table(el);
                case "DT": return `\n\n**${inline(el).trim()}**\n`;
                case "DD": return `${inline(el).trim()}\n`;
                case "INPUT": case "SELECT": case "TEXTAREA": case "BUTTON": return "";
                default: {
                    let inner = "";
                    for (const child of el.childNodes) inner += render(child, depth, inLine);
                    const display = (style || getComputedStyle(el)).display;
                    return !inLine && display && !display.startsWith("inline") ? `\n${inner}\n` : inner;
                }
            }
        }

        let md = tidy(render(root));
        const truncated = md.length > maxLength;
        if (truncated) md = md.slice(0, maxLength) + "\n\n[…truncated]";
        const result = { url: location.href, title: document.title, markdown: md, truncated };
        if (links) result.links = linkList;
        return result;
    }

    // Trims the whitespace the DOM leaves around blocks, outside code blocks only, and keeps the
    // indent of nested list items.
    function tidy(md) {
        return md.split(/(\n```[^\n]*\n[\s\S]*?\n```\n)/).map((part, i) => i % 2 ? part : part
            .replace(/[ \t]+\n/g, "\n")
            .replace(/\n[ \t]+(?=\S)/g, (m, offset, all) => /^(?:[-*+]|\d+\.)\s/.test(all.slice(offset + m.length)) ? m : "\n")
            .replace(/\n{3,}/g, "\n\n")
        ).join("").replace(/\n{3,}/g, "\n\n").trim();
    }

    // MARK: - Selectors for recipes

    // Candidates from most to least durable: test ids, ids that look hand-written, accessible
    // role and name, form names, visible text, then a CSS path.
    function selectorsFor(el) {
        const out = [];
        const tag = el.tagName.toLowerCase();
        const unique = sel => { try { return document.querySelectorAll(sel).length === 1; } catch { return false; } };
        for (const attr of ["data-testid", "data-test", "data-qa", "data-cy"]) {
            const v = el.getAttribute(attr);
            if (v && unique(`[${attr}="${CSS.escape(v)}"]`)) out.push(`[${attr}="${CSS.escape(v)}"]`);
        }
        if (el.id && !/\d{3,}|[a-f0-9]{8,}|^:r|^ember|^react/i.test(el.id) && unique("#" + CSS.escape(el.id))) out.push("#" + CSS.escape(el.id));
        const name = nameOf(el);
        const role = roleOf(el);
        if (name && name.length <= 60 && !/["']/.test(name)) out.push(`role=${role}[name="${name}"]`);
        if (el.name && unique(`${tag}[name="${CSS.escape(el.name)}"]`)) out.push(`${tag}[name="${CSS.escape(el.name)}"]`);
        const aria = el.getAttribute("aria-label");
        if (aria && unique(`[aria-label="${CSS.escape(aria)}"]`)) out.push(`[aria-label="${CSS.escape(aria)}"]`);
        if (name && name.length <= 40 && ["button", "link", "tab", "menuitem", "option"].includes(role)) out.push(`text=${name}`);
        out.push(cssPath(el));
        return { candidates: [...new Set(out)], label: `${role} "${name}"`, element: describe(el) };
    }

    function cssPath(el) {
        const parts = [];
        while (el && el.nodeType === 1 && el !== document.documentElement) {
            let part = el.tagName.toLowerCase();
            if (el.id && !/\d{3,}/.test(el.id)) { parts.unshift(`#${CSS.escape(el.id)}`); break; }
            const parent = el.parentElement;
            if (parent) {
                const same = [...parent.children].filter(c => c.tagName === el.tagName);
                if (same.length > 1) part += `:nth-of-type(${same.indexOf(el) + 1})`;
            }
            parts.unshift(part);
            el = parent;
        }
        return parts.join(" > ");
    }

    // MARK: - Recorder

    // Watches the person's own input and sends each step to Harbor as it happens, so a
    // navigation that ends this world loses nothing. Typing is sent once the field settles.
    const recorder = (() => {
        let on = false;
        const pendingInput = new Map();
        const post = step => {
            try { webkit.messageHandlers.harborAgentRecord.postMessage(step); } catch { /* handler gone: recording stopped */ }
        };
        const flush = el => {
            const pending = pendingInput.get(el);
            if (!pending) return;
            clearTimeout(pending.timer);
            pendingInput.delete(el);
            const sensitive = el.type === "password" || /card|cc-|cvv|cvc|iban|ssn/i.test(`${el.name} ${el.id} ${el.autocomplete}`);
            post({ action: "fill", ...selectorsFor(el), text: sensitive ? "" : el.value, sensitive });
        };
        const onClick = e => {
            if (!e.isTrusted) return;
            const el = e.target.closest(INTERACTIVE) || e.target;
            if (el.matches("input:not([type=checkbox]):not([type=radio]):not([type=submit]):not([type=button]), textarea, select, [contenteditable]")) return;
            for (const field of pendingInput.keys()) flush(field);
            const action = el.matches("input[type=checkbox], input[type=radio], [role=checkbox], [role=switch]")
                ? (checkedState(el) ? "check" : "uncheck") : "click";
            post({ action, ...selectorsFor(el) });
        };
        const onInput = e => {
            if (!e.isTrusted) return;
            const el = e.target;
            if (el.tagName === "SELECT") return;
            const pending = pendingInput.get(el) || {};
            clearTimeout(pending.timer);
            pending.timer = setTimeout(() => flush(el), 800);
            pendingInput.set(el, pending);
        };
        const onChange = e => {
            if (!e.isTrusted) return;
            const el = e.target;
            if (el.tagName === "SELECT") post({ action: "select", ...selectorsFor(el), value: el.value });
            else if (pendingInput.has(el)) flush(el);
        };
        const onKey = e => {
            if (!e.isTrusted || !["Enter", "Escape", "Tab"].includes(e.key)) return;
            if (pendingInput.has(e.target)) flush(e.target);
            if (e.key === "Tab") return;
            post({ action: "press", key: e.key, ...(e.target !== document.body ? selectorsFor(e.target) : {}) });
        };
        const types = [["click", onClick], ["input", onInput], ["change", onChange], ["keydown", onKey]];
        return {
            start() {
                if (on) return true;
                on = true;
                for (const [type, fn] of types) document.addEventListener(type, fn, true);
                return true;
            },
            stop() {
                for (const el of [...pendingInput.keys()]) flush(el);
                for (const [type, fn] of types) document.removeEventListener(type, fn, true);
                on = false;
                return true;
            }
        };
    })();

    // MARK: - Entry point

    globalThis.__harborAgent = {
        version: 1,
        async call(op, args) {
            const fn = ops[op];
            if (!fn) throw new Error(`Unknown agent op ${op}`);
            return await fn(args || {});
        }
    };
})();
