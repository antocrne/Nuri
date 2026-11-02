import Foundation

/// Nuri's built-in block list: well-known ad, tracking and malvertising domains, blocked when
/// loaded as third-party resources, plus a few conservative cosmetic rules.
/// It's deliberately compact (fast to compile, low false positives); it is not EasyList.
enum AdBlockList {
    static let version = 4

    static let domains: [String] = [
        // Ad exchanges & servers
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com",
        "googletagservices.com", "2mdn.net", "adnxs.com", "adsrvr.org", "amazon-adsystem.com",
        "criteo.com", "criteo.net", "taboola.com", "outbrain.com", "pubmatic.com", "rubiconproject.com",
        "openx.net", "casalemedia.com", "smartadserver.com", "sascdn.com", "moatads.com", "adform.net",
        "advertising.com", "yieldmo.com", "teads.tv", "sharethrough.com", "33across.com", "indexww.com",
        "media.net", "contextweb.com", "bidswitch.net", "adroll.com", "mathtag.com", "adsafeprotected.com",
        "doubleverify.com", "serving-sys.com", "zedo.com", "revcontent.com", "mgid.com", "propellerads.com",
        "popads.net", "popcash.net", "adcash.com", "exoclick.com", "juicyads.com", "trafficjunky.net",
        "adsterra.com", "hilltopads.net", "clickadu.com", "onclickads.net", "adfox.ru", "an.yandex.ru",
        "smartclip.net", "stickyadstv.com", "spotxchange.com", "springserve.com", "lijit.com", "sovrn.com",
        "gumgum.com", "kargo.com", "triplelift.com", "3lift.com", "adition.com", "yieldlab.net",
        "improvedigital.com", "richaudience.com", "seedtag.com", "ogury.com", "adhese.com", "adskeeper.com",
        "zergnet.com", "content.ad", "nativo.com", "adtelligent.com", "e-planning.net", "adkernel.com",
        "adsymptotic.com", "undertone.com", "vidoomy.com", "connatix.com", "primis.tech", "unrulymedia.com",
        "adzerk.net", "carbonads.net", "buysellads.com", "infolinks.com", "admixer.net", "adpone.com",
        // Trackers, data brokers, session recorders
        "google-analytics.com", "googletagmanager.com", "scorecardresearch.com", "quantserve.com",
        "quantcount.com", "rlcdn.com", "demdex.net", "omtrdc.net", "everesttech.net", "hotjar.com",
        "hotjar.io", "mouseflow.com", "fullstory.com", "crazyegg.com", "clarity.ms", "bluekai.com",
        "krxd.net", "exelator.com", "agkn.com", "tapad.com", "id5-sync.com", "liveintent.com",
        "bounceexchange.com", "chartbeat.com", "chartbeat.net", "nr-data.net", "mc.yandex.ru",
        "analytics.tiktok.com", "ads-twitter.com", "ads.linkedin.com", "bat.bing.com", "adsymptotic.com",
        "weborama.fr", "weborama.com", "mediarithmics.com", "xiti.com", "ati-host.net", "tradedoubler.com",
        "effiliation.com", "branch.io", "appsflyer.com", "adjust.com", "kochava.com", "iljmp.com",
        "openxcdn.net", "cxense.com", "permutive.com", "permutive.app", "zemanta.com", "lotame.com",
        "crwdcntrl.net", "adsco.re", "doubleverify.com", "imrworldwide.com", "statcounter.com",
    ]

    /// Path-based rules (regex, WebKit content-blocker syntax: no `|` disjunctions).
    static let urlFilters: [String] = [
        #"^https?://([^/]+\.)?facebook\.com/tr[/?]"#,
        #"^https?://([^/]+\.)?facebook\.net/tr[/?]"#,
        #"^https?://connect\.facebook\.net/.*/fbevents\.js"#,
        #"^https?://www\.youtube\.com/pagead/"#,
        #"^https?://www\.youtube\.com/api/stats/ads"#,
        #"^https?://www\.youtube\.com/ptracking"#,
        #"^https?://([^/]+\.)?google\.[a-z.]+/pagead/"#,
    ]

    /// Cosmetic rules applied everywhere (only unambiguous ad containers).
    static let hiddenSelectors = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^='div-gpt-ad']", "[id^='google_ads_iframe']",
        "iframe[src*='doubleclick.net']", "iframe[src*='googlesyndication.com']",
        "[id^='taboola-']", ".trc_related_container", ".OUTBRAIN", ".ob-widget",
    ]

    static func encodedRules(allowlist: [String]) -> String {
        var rules: [[String: Any]] = []
        for domain in Set(domains).sorted() {
            let escaped = domain.replacingOccurrences(of: ".", with: "\\.")
            rules.append([
                "trigger": ["url-filter": "^[^:]+://+([^:/]+\\.)?\(escaped)[:/]", "load-type": ["third-party"]],
                "action": ["type": "block"],
            ])
        }
        for filter in urlFilters {
            rules.append(["trigger": ["url-filter": filter], "action": ["type": "block"]])
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": hiddenSelectors.joined(separator: ", ")],
        ])
        if !allowlist.isEmpty {
            // Sites where the user turned the blocker off.
            rules.append([
                "trigger": ["url-filter": ".*", "if-domain": allowlist.map { "*" + $0 }],
                "action": ["type": "ignore-previous-rules"],
            ])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
