//! Minimal C ABI over brave/adblock-rust for Harbor.
//! Only answers "would this request be blocked?"; no cosmetic filtering.

use adblock::lists::{ParseOptions, RuleTypes};
use adblock::resources::{PermissionMask, Resource};
use adblock::request::Request;
use adblock::{Engine, FilterSet};
use std::ffi::CStr;
use std::os::raw::c_char;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::ptr;

pub(crate) mod content_blocking_ffi;
pub(crate) mod cosmetic_ffi;
pub(crate) mod urlskip_ffi;

// panic = "abort" in release; catch_unwind still guards debug/test builds.
pub(crate) fn guard<T>(f: impl FnOnce() -> T, fallback: T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(fallback)
}

pub(crate) unsafe fn cstr<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    CStr::from_ptr(p).to_str().ok()
}

/// The one permission bit Harbor grants. A list parsed with it may invoke
/// `trusted-*` scriptlets; a resource declaring it is refused to every other list.
pub(crate) const TRUSTED: u8 = 1;

#[derive(serde::Deserialize)]
struct ListInput {
    rules: String,
    #[serde(default)]
    trusted: bool,
    /// Keep only what `url_cosmetic_resources` reads: cosmetic filters and the
    /// `$generichide` network filters. WebKit's rule lists do the network blocking,
    /// and the other network filters were three quarters of the engine's memory.
    #[serde(default)]
    cosmetic_only: bool,
}

/// Build an engine from a JSON array of
/// `{ "rules": "...", "trusted": bool, "cosmetic_only": bool }`.
///
/// Per-list rather than one blob because `ParseOptions::permissions` is applied
/// at parse time, and it is what gates `trusted-*` scriptlets.
#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_from_lists(
    json_utf8: *const c_char,
    json_len: usize,
) -> *mut Engine {
    if json_utf8.is_null() {
        return ptr::null_mut();
    }
    let bytes = std::slice::from_raw_parts(json_utf8 as *const u8, json_len);
    let Ok(text) = std::str::from_utf8(bytes) else {
        return ptr::null_mut();
    };
    guard(
        || {
            let Ok(lists) = serde_json::from_str::<Vec<ListInput>>(text) else {
                return ptr::null_mut();
            };
            let mut set = FilterSet::new(false);
            for list in lists {
                let permissions = if list.trusted {
                    PermissionMask::from_bits(TRUSTED)
                } else {
                    PermissionMask::default()
                };
                if list.cosmetic_only {
                    let generic_hide = list
                        .rules
                        .lines()
                        .filter(|l| l.contains("generichide") || l.contains("ghide"))
                        .collect::<Vec<_>>()
                        .join("\n");
                    set.add_filter_list(
                        list.rules,
                        ParseOptions {
                            permissions,
                            rule_types: RuleTypes::CosmeticOnly,
                            ..ParseOptions::default()
                        },
                    );
                    set.add_filter_list(
                        generic_hide,
                        ParseOptions {
                            permissions,
                            rule_types: RuleTypes::NetworkOnly,
                            ..ParseOptions::default()
                        },
                    );
                } else {
                    set.add_filter_list(
                        list.rules,
                        ParseOptions {
                            permissions,
                            ..ParseOptions::default()
                        },
                    );
                }
            }
            Box::into_raw(Box::new(Engine::new_with_filter_set(set)))
        },
        ptr::null_mut(),
    )
}

/// Install Harbor's scriptlet resource set. JSON array of `adblock::resources::Resource`.
///
/// Top-level scriptlets must be `application/javascript`; `fn/javascript` is
/// dependency-only. Names must end in `.js`, since lookup appends the extension.
/// Returns false if the JSON does not parse.
#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_use_resources(
    engine: *mut Engine,
    json_utf8: *const c_char,
    json_len: usize,
) -> bool {
    if engine.is_null() || json_utf8.is_null() {
        return false;
    }
    let bytes = std::slice::from_raw_parts(json_utf8 as *const u8, json_len);
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    let engine = &mut *engine;
    guard(
        || match serde_json::from_str::<Vec<Resource>>(text) {
            Ok(resources) => {
                engine.use_resources(resources);
                true
            }
            Err(_) => false,
        },
        false,
    )
}

#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_deserialize(bytes: *const u8, len: usize) -> *mut Engine {
    if bytes.is_null() {
        return ptr::null_mut();
    }
    let data = std::slice::from_raw_parts(bytes, len);
    guard(
        || {
            let mut engine = Engine::default();
            match engine.deserialize(data) {
                Ok(()) => Box::into_raw(Box::new(engine)),
                Err(_) => ptr::null_mut(),
            }
        },
        ptr::null_mut(),
    )
}

#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_serialize(engine: *mut Engine, out_len: *mut usize) -> *mut u8 {
    if engine.is_null() || out_len.is_null() {
        return ptr::null_mut();
    }
    let engine = &*engine;
    guard(
        || {
            let mut v = engine.serialize().into_boxed_slice();
            *out_len = v.len();
            let p = v.as_mut_ptr();
            std::mem::forget(v);
            p
        },
        ptr::null_mut(),
    )
}

#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_buffer_free(bytes: *mut u8, len: usize) {
    if !bytes.is_null() {
        drop(Box::from_raw(std::slice::from_raw_parts_mut(bytes, len)));
    }
}

#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_matches(
    engine: *mut Engine,
    url: *const c_char,
    source_url: *const c_char,
    request_type: *const c_char,
) -> bool {
    if engine.is_null() {
        return false;
    }
    let (Some(url), Some(source), Some(kind)) = (cstr(url), cstr(source_url), cstr(request_type)) else {
        return false;
    };
    let engine = &*engine;
    guard(
        || match Request::new(url, source, kind, "GET") {
            Ok(req) => engine.check_network_request(&req).should_block(),
            Err(_) => false,
        },
        false,
    )
}

#[no_mangle]
pub unsafe extern "C" fn harbor_adblock_engine_free(engine: *mut Engine) {
    if !engine.is_null() {
        drop(Box::from_raw(engine));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    fn c(s: &str) -> CString {
        CString::new(s).unwrap()
    }

    #[test]
    fn ffi_smoke() {
        let rules = "||example.com^\n@@||example.com/allowed.js\n";
        let site = c("https://site.test/");
        let script = c("script");
        unsafe {
            let e = engine_from_test_rules(rules);
            assert!(!e.is_null());
            assert!(harbor_adblock_engine_matches(e, c("https://example.com/ad.js").as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!(!harbor_adblock_engine_matches(e, c("https://other.test/x.js").as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!(!harbor_adblock_engine_matches(e, c("https://example.com/allowed.js").as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!(!harbor_adblock_engine_matches(e, c("not a url").as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!(!harbor_adblock_engine_matches(e, ptr::null(), site.as_ptr(), script.as_ptr()));

            let mut len = 0usize;
            let buf = harbor_adblock_engine_serialize(e, &mut len);
            assert!(!buf.is_null() && len > 0);
            let e2 = harbor_adblock_engine_deserialize(buf, len);
            assert!(!e2.is_null());
            assert!(harbor_adblock_engine_matches(e2, c("https://example.com/ad.js").as_ptr(), site.as_ptr(), script.as_ptr()));
            harbor_adblock_buffer_free(buf, len);

            assert!(harbor_adblock_engine_deserialize(b"garbage".as_ptr(), 7).is_null());
            assert!(!harbor_adblock_engine_matches(ptr::null_mut(), site.as_ptr(), site.as_ptr(), script.as_ptr()));

            harbor_adblock_engine_free(e2);
            harbor_adblock_engine_free(e);
            harbor_adblock_engine_free(ptr::null_mut());
        }
    }

    fn engine_from(lists: serde_json::Value) -> *mut Engine {
        let json = lists.to_string();
        unsafe { harbor_adblock_engine_from_lists(json.as_ptr() as *const c_char, json.len()) }
    }

    /// Order-free view of one cosmetic answer, for comparing two engines.
    /// adblock-rust emits scriptlets in hash order, new on every call, so the
    /// script is compared as a set of lines.
    fn cosmetic_answer(e: *mut Engine, url: &str) -> String {
        let mut v = serde_json::to_value(unsafe { &*e }.url_cosmetic_resources(url)).unwrap();
        for key in ["hide_selectors", "procedural_actions", "exceptions"] {
            if let Some(arr) = v[key].as_array_mut() {
                arr.sort_by_key(|x| x.to_string());
            }
        }
        let mut lines: Vec<&str> = v["injected_script"].as_str().unwrap_or("").lines().collect();
        lines.sort();
        let script = lines.join("\n");
        v["injected_script"] = serde_json::Value::String(script);
        v.to_string()
    }

    #[test]
    fn cosmetic_only_drops_network_rules_and_keeps_generichide() {
        let rules = "||ads.example^\nexample.com##.banner\n@@||quiet.test^$generichide\n";
        let full = engine_from(serde_json::json!([{ "rules": rules }]));
        let slim = engine_from(serde_json::json!([{ "rules": rules, "cosmetic_only": true }]));
        let (ad, site, script) = (c("https://ads.example/x.js"), c("https://site.test/"), c("script"));
        unsafe {
            assert!(harbor_adblock_engine_matches(full, ad.as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!(!harbor_adblock_engine_matches(slim, ad.as_ptr(), site.as_ptr(), script.as_ptr()));
            assert!((&*slim).url_cosmetic_resources("https://quiet.test/").generichide);
            for url in ["https://example.com/", "https://quiet.test/", "https://other.test/"] {
                assert_eq!(cosmetic_answer(full, url), cosmetic_answer(slim, url), "{url}");
            }
            harbor_adblock_engine_free(full);
            harbor_adblock_engine_free(slim);
        }
    }

    /// The bundled lists and resources give the same cosmetic answers, scriptlets
    /// included, from the cosmetic-only engine the app builds as from a full one.
    #[test]
    fn cosmetic_only_answers_like_the_full_engine_on_real_lists() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../Packages/HarborBlocker/Sources/HarborBlocker/Resources");
        let trusted = ["ublock-filters.min", "ublock-privacy.min", "ublock-badware",
            "ublock-quick-fixes", "ublock-unbreak", "harbor-filters-default"];
        let mut lists = Vec::new();
        for entry in std::fs::read_dir(&dir).unwrap() {
            let p = entry.unwrap().path();
            if p.extension().and_then(|e| e.to_str()) != Some("txt") { continue; }
            let stem = p.file_stem().unwrap().to_str().unwrap().to_string();
            lists.push((std::fs::read_to_string(&p).unwrap(), trusted.contains(&stem.as_str())));
        }
        let as_json = |cosmetic_only: bool| serde_json::Value::Array(lists.iter().map(|(rules, trusted)| {
            serde_json::json!({ "rules": rules, "trusted": trusted, "cosmetic_only": cosmetic_only })
        }).collect());
        let resources = std::fs::read_to_string(dir.join("scriptlets.json")).unwrap();
        let (full, slim) = (engine_from(as_json(false)), engine_from(as_json(true)));
        unsafe {
            for e in [full, slim] {
                assert!(!e.is_null());
                assert!(harbor_adblock_engine_use_resources(e, resources.as_ptr() as *const c_char, resources.len()));
            }
            for url in [
                "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/",
                "https://www.reddit.com/", "https://www.nytimes.com/", "https://www.cnn.com/",
                "https://www.facebook.com/", "https://x.com/home", "https://en.wikipedia.org/wiki/Web_browser",
                "https://github.com/WebKit/WebKit", "https://www.twitch.tv/", "https://www.amazon.com/",
            ] {
                assert_eq!(cosmetic_answer(full, url), cosmetic_answer(slim, url), "{url}");
            }
            harbor_adblock_engine_free(full);
            harbor_adblock_engine_free(slim);
        }
    }

    /// Reachability check for the `content-blocking` feature, which is off by
    /// default. Without it the module is invisible and every conversion call
    /// fails to compile with an unresolved-module error rather than a missing
    /// feature one.
    #[test]
    fn content_blocking_module_is_available() {
        use adblock::content_blocking::{CbRuleEquivalent, CbType};
        use adblock::lists::{parse_filter, ParseOptions};
        use std::convert::TryFrom;

        let parsed = parse_filter("||example.com^", true, ParseOptions::default())
            .expect("filter should parse");
        let equivalent = CbRuleEquivalent::try_from(parsed).expect("should convert");
        let rules: Vec<_> = equivalent.into_iter().collect();
        assert_eq!(rules.len(), 1);
        assert!(matches!(rules[0].action.typ, CbType::Block));
        assert!(rules[0].trigger.url_filter.contains("example"));
    }
}

/// Wraps a bare rules blob as the single untrusted list the new builder expects.
#[cfg(test)]
pub(crate) fn engine_from_test_rules(rules: &str) -> *mut Engine {
    let json = serde_json::json!([{ "rules": rules, "trusted": false }]).to_string();
    unsafe { harbor_adblock_engine_from_lists(json.as_ptr() as *const c_char, json.len()) }
}

#[cfg(test)]
mod scriptlet_tests {
    use super::*;
    use base64::engine::general_purpose::STANDARD;
    use base64::Engine as _;
    use std::ffi::{CStr, CString};

    fn resource(name: &str, body: &str, trusted: bool) -> String {
        format!(
            r#"{{"name":"{name}","aliases":[],"kind":{{"mime":"application/javascript"}},"content":"{}","dependencies":[],"permission":{}}}"#,
            STANDARD.encode(body),
            if trusted { TRUSTED } else { 0 }
        )
    }

    /// injected_script for `url`, or "" when nothing applies.
    fn injected(lists: &str, resources: &str, url: &str) -> String {
        unsafe {
            let l = CString::new(lists).unwrap();
            let engine = harbor_adblock_engine_from_lists(l.as_ptr(), lists.len());
            assert!(!engine.is_null(), "engine build failed");
            let r = CString::new(resources).unwrap();
            assert!(harbor_adblock_engine_use_resources(engine, r.as_ptr(), resources.len()));
            let u = CString::new(url).unwrap();
            let out = cosmetic_ffi::harbor_adblock_cosmetic_for_url(engine, u.as_ptr());
            let text = if out.is_null() {
                String::new()
            } else {
                let s = CStr::from_ptr(out).to_string_lossy().into_owned();
                content_blocking_ffi::harbor_adblock_string_free(out);
                s
            };
            harbor_adblock_engine_free(engine);
            serde_json::from_str::<serde_json::Value>(&text)
                .map(|v| v["injected_script"].as_str().unwrap_or("").to_string())
                .unwrap_or_default()
        }
    }

    const BODY: &str = "function harborMark(a) { window.__m = a; }";

    #[test]
    fn plain_scriptlet_runs_from_any_list() {
        let lists = r#"[{"rules":"example.com##+js(mark, hello)","trusted":false}]"#;
        let res = format!("[{}]", resource("mark.js", BODY, false));
        let out = injected(lists, &res, "https://example.com/");
        assert!(out.contains(r#"harborMark("hello")"#), "got: {out}");
    }

    #[test]
    fn trusted_scriptlet_runs_from_a_trusted_list() {
        let lists = r#"[{"rules":"example.com##+js(trusted-mark, hello)","trusted":true}]"#;
        let res = format!("[{}]", resource("trusted-mark.js", BODY, true));
        let out = injected(lists, &res, "https://example.com/");
        assert!(out.contains(r#"harborMark("hello")"#), "got: {out}");
    }

    /// The point of the trust model: an untrusted list cannot reach a trusted body.
    #[test]
    fn trusted_scriptlet_is_refused_to_an_untrusted_list() {
        let lists = r#"[{"rules":"example.com##+js(trusted-mark, hello)","trusted":false}]"#;
        let res = format!("[{}]", resource("trusted-mark.js", BODY, true));
        let out = injected(lists, &res, "https://example.com/");
        assert!(!out.contains("harborMark"), "trusted body leaked: {out}");
    }

    #[test]
    fn unknown_scriptlet_name_injects_nothing() {
        let lists = r#"[{"rules":"example.com##+js(no-such-thing, x)","trusted":true}]"#;
        let res = format!("[{}]", resource("mark.js", BODY, false));
        assert_eq!(injected(lists, &res, "https://example.com/"), "");
    }

    /// Only `function name(...)` bodies receive their arguments. Arrow and
    /// `async function` forms fall back to inlining with no call and no args.
    #[test]
    fn only_function_declarations_receive_arguments() {
        let lists = r#"[{"rules":"example.com##+js(arrow, hello)","trusted":false}]"#;
        let arrow = "const harborArrow = (a) => { window.__m = a; };";
        let res = format!("[{}]", resource("arrow.js", arrow, false));
        let out = injected(lists, &res, "https://example.com/");
        assert!(
            !out.contains(r#"harborArrow("hello")"#),
            "crate gained arrow support: {out}"
        );
    }
}

