// Harbor Agent LinkedIn
// LinkedIn people search and profile reading, from Browser Bridge's content script
// (extension/src/lib/scrape-search.ts, scrape-profile.ts, pacing.ts). Evaluated in the agent's own
// content world with one of the functions below called by name. LinkedIn's class names are
// hashed and rotate, so everything anchors on structure, roles and text. Tolerant: a field that
// does not parse is null, never an error.
const clean = s => { const v = (s ?? "").replace(/\s+/g, " ").trim(); return v || null; };
const sleep = ms => new Promise(r => setTimeout(r, ms + Math.random() * 1000));
const between = (min, max) => max < min ? min : min + Math.floor(Math.random() * (max - min + 1));
const scroller = () => document.scrollingElement || document.documentElement || document.body;

// Scroll and dwell as a person reading would, which also brings lazy cards into the page.
async function simulateReading(minMs, maxMs) {
    const until = performance.now() + between(minMs, maxMs);
    while (performance.now() < until) {
        scroller().scrollBy({ top: 150 + Math.random() * 120, behavior: "smooth" });
        await sleep(450 + Math.random() * 500);
        if (Math.random() > 0.75) { scroller().scrollBy({ top: -90, behavior: "smooth" }); await sleep(350 + Math.random() * 300); }
    }
}

async function scrollThroughPage(maxChunks = 12) {
    let last = 0;
    for (let i = 0; i < maxChunks; i++) {
        scroller().scrollBy({ top: 600 + Math.random() * 300, behavior: "smooth" });
        await sleep(500 + Math.random() * 400);
        const height = scroller().scrollHeight;
        if (height === last && i > 2) break;
        last = height;
    }
    scroller().scrollTo({ top: 0, behavior: "smooth" });
    await sleep(400);
}

async function waitAnchor(selector, timeout = 12000) {
    const until = Date.now() + timeout;
    while (Date.now() < until) {
        if (document.querySelector(selector)) return true;
        await new Promise(r => setTimeout(r, 250));
    }
    return false;
}

// MARK: - Search

const slugOf = el => el.getAttribute("href")?.match(/\/in\/([^/?#]+)/)?.[1] ?? null;

function resultCards() {
    // The list holding the most profile links (skips sidebars).
    let root = document, best = 0;
    for (const list of document.querySelectorAll('[role="list"]')) {
        const count = list.querySelectorAll('a[href*="/in/"]').length;
        if (count > best) { best = count; root = list; }
    }
    // The card is the <a> wrapping <p> blocks; the inner name link has none.
    const seen = new Set(), cards = [];
    for (const a of root.querySelectorAll('a[href*="/in/"]')) {
        if (!a.querySelector("p")) continue;
        const slug = slugOf(a);
        if (!slug || seen.has(slug)) continue;
        seen.add(slug);
        cards.push(a);
    }
    if (cards.length) return cards;
    const universal = [...document.querySelectorAll('[role="list"] [data-view-name="search-entity-result-universal-template"]')];
    return universal.length ? universal : [...document.querySelectorAll('div[data-view-name="people-search-result"] > a > div')];
}

const profileURL = href => {
    if (!href) return null;
    try {
        const u = new URL(href, "https://www.linkedin.com");
        const m = u.pathname.match(/\/in\/([^/?#]+)/);
        return m ? `https://www.linkedin.com/in/${m[1]}/` : u.origin + u.pathname;
    } catch { return href; }
};

const CARD_NOISE = /^(message|connect|follow|following|pending|view\b)/i;

function parseCard(card) {
    const nested = card.querySelector('a[href*="/in/"]');
    const url = profileURL(card.getAttribute("href") ?? nested?.getAttribute("href") ?? null);
    // innerText breaks lines between blocks; React leaves no space between them in textContent.
    const degree = (card.innerText || card.textContent || "").match(/\b(1st|2nd|3rd)\+?(?=\W|$)/i)?.[0] ?? null;
    let name = clean(nested?.textContent)?.replace(/\s*•.*$/, "").trim() || null;
    const nameP = nested?.closest("p");
    const info = [...card.querySelectorAll("p")].filter(p => p !== nameP).map(p => clean(p.textContent))
        .filter(l => l !== null && !CARD_NOISE.test(l));
    if (!info.length) {
        const lines = (card.textContent ?? "").split("\n").map(clean).filter(l => l !== null && !CARD_NOISE.test(l));
        if (!name) name = lines[0] ?? null;
        return { name, headline: lines.find(l => l !== name) ?? null, location: null, profileUrl: url, connectionDegree: degree };
    }
    return { name, headline: info[0] ?? null, location: info[1] ?? null, profileUrl: url, connectionDegree: degree };
}

async function scrapeSearch() {
    if (!(await waitAnchor('[role="list"], [data-view-name="people-search-result"]'))) {
        return { error: "No search results on the page (signed out, or LinkedIn changed its layout)", url: location.href };
    }
    await sleep(800);
    await simulateReading(2500, 5000);
    return { hits: resultCards().map(parseCard).filter(h => h.profileUrl || h.name) };
}

// MARK: - Profile

const SCHOOL = /(university|college|school|institute|academy|universit|école|hochschule)/i;
const PROFILE_NOISE = /^(message|connect|follow|following|pending|more|save|share|contact info|see contact info|·|•)/i;
const POST_TIME = /\b(\d+)\s*(s|m|h|d|w|mo|yr|sec|min|hour|day|week|month|year)s?\b\s*[•·]/i;
const POST_NOISE = /^(video player is loading|beginning of dialog|escape will cancel|end of dialog|this is a modal|play|pause|mute|unmute|posts|videos|loaded|follow|like|liked|comment|repost|reposted|\d+:\d+|\d+\s*(likes?|comments?|reposts?))/i;

const primaryContent = () => document.querySelector('section[aria-label="Primary content"]') ?? document.body;

function leafLines(root) {
    const out = [], seen = new Set();
    root.querySelectorAll("h1, h2, h3, p, span, a, li").forEach(el => {
        if ([...el.children].some(c => (c.textContent ?? "").trim())) return;
        const t = clean(el.textContent);
        if (t && !seen.has(t)) { seen.add(t); out.push(t); }
    });
    return out;
}

function latestPost() {
    const root = primaryContent();
    const lines = leafLines(root);
    const at = lines.findIndex(l => POST_TIME.test(l));
    if (at === -1) return null;
    const m = lines[at].match(POST_TIME);
    const prose = [...root.querySelectorAll("p, span[dir], div[dir]")].map(e => clean(e.textContent));
    const text = [...lines.slice(at), ...prose]
        .map(l => (l ?? "").replace(/^\s*\d+\s*(?:s|m|h|d|w|mo|yr)\w*\s*[•·]\s*/i, "").trim())
        .filter(l => l.length > 25 && l.length < 3000 && !POST_NOISE.test(l) && !POST_TIME.test(l))
        .sort((a, b) => b.length - a.length)[0] ?? null;
    return { text: text ? text.slice(0, 1500) : null, time: m ? `${m[1]}${m[2].toLowerCase()}` : null };
}

async function scrapeProfile() {
    if (!(await waitAnchor('section[aria-label="Primary content"]'))) {
        return { error: "No profile on the page (signed out, not found, or LinkedIn changed its layout)", url: location.href };
    }
    await sleep(800);
    await scrollThroughPage();
    const name = clean(document.title.replace(/\s*[|·].*$/, ""));
    const root = primaryContent();
    const card = root.querySelector('[componentkey*="Topcard"]') ?? root.querySelector("section") ?? root;
    const lines = leafLines(card).filter(l => l !== name && !PROFILE_NOISE.test(l) && !/^(1st|2nd|3rd)\+?$/i.test(l));
    const headline = lines[0] ?? null;
    // A place has two commas or more ("City, Region, Country"); a headline rarely does.
    const placeAt = lines.findIndex(l => (l.match(/,/g)?.length ?? 0) >= 2 && !/[·•]/.test(l));
    const chips = lines.slice(1, placeAt >= 0 ? placeAt : 4).flatMap(l => l.split(/[·•]/).map(s => s.trim()))
        .filter(l => l && l !== headline && !PROFILE_NOISE.test(l));
    const school = chips.find(l => SCHOOL.test(l)) ?? null;
    const company = chips.find(l => l !== school) ?? null;
    const text = `${root.textContent ?? ""} ${document.body.textContent ?? ""}`;
    const followers = text.match(/([\d.,]+)\s*(followers|abonnés|seguidores|follower)/i);
    const connections = text.match(/([\d.,]+\+?)\s*(connections|connexions|relations|contactos|contatti|kontakte)/i);
    const slug = location.pathname.match(/\/in\/([^/?#]+)/)?.[1];
    const followerCount = followers ? Number.parseInt(followers[1].replace(/[.,]/g, ""), 10) : null;
    return { profile: {
        profileUrl: slug ? `https://www.linkedin.com/in/${slug}/` : location.href,
        name, headline: clean(headline), location: clean(placeAt >= 0 ? lines[placeAt] : null),
        followers: followerCount != null && !Number.isNaN(followerCount) ? followerCount : null,
        connections: connections ? clean(connections[0].replace(/(\d)\s*\+?\s*(connections)/i, "$1+ $2")) : null,
        currentCompany: clean(company), currentSchool: clean(school), latestPost: latestPost()
    } };
}
