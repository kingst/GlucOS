//
//  MealAnnouncementLink.swift
//  BioKernel
//
//  The universal link an AI app opens to hand a meal over to GlucOS for
//  dosing. See dev/meal-announcements-from-ai-apps.md, "UI/UX".
//
//      https://typezero.ai/meal?bundleId=<bundle.id>&mealId=<mealId>
//
//  The two parameters are exactly the identity the announcement files use —
//  `mealId` is only unique within the app that wrote it, so the bundle id is
//  not decoration. Nothing about the meal itself travels in the link: the meal
//  is already in `meal_announcements.<UTC_DAY>.jsonl`, and a link that carried
//  its own copy would be a second, unversioned way to announce a meal, one
//  where an AI could describe one meal in the file and a different one in the
//  URL.
//
//  Query parameters rather than path components on purpose. Both halves of the
//  identity are opaque strings an AI app chose — a bundle id has dots and a
//  `mealId` is whatever that app mints — and `URLComponents` percent-encodes
//  and decodes them for us, where path splitting would need its own escaping
//  rules for a value that may contain a slash.
//
//  The domain is ClueClue's, not ours, and so is the association file that
//  vouches for GlucOS — it is served by ClueClue's own App Engine instance
//  (server/clueclue/applinks.py). That is the right way round even though
//  GlucOS is the app being opened: the sender owns the link, and ClueClue is
//  the only side with a web host. `applinks:typezero.ai` is in our entitlement
//  for it, and is now the only associated domain GlucOS declares.
//
//  Note the failure mode when the association hasn't propagated, or GlucOS
//  isn't installed: iOS opens the URL in Safari instead, and the handoff
//  becomes a web page. ClueClue's server answers `/meal` with a short page
//  saying so rather than a raw 404.
//
//  Parsing does not check the host. The association file is what decides which
//  hosts can reach us at all, and it claims exactly one path on one domain, so
//  a host check here would be a second gate that can only ever disagree with
//  the first. What it does check is the path, which is the part that actually
//  distinguishes one of our links from another.
//

import Foundation

enum MealAnnouncementLink {
    static let host = "typezero.ai"
    static let path = "/meal"
    static let bundleIdParameter = "bundleId"
    static let mealIdParameter = "mealId"

    /// The meal a link names, or nil when the URL isn't one of ours.
    ///
    /// Strict about the path, because `MainView` falls through to the settings
    /// link when this returns nil and the two must not be able to claim each
    /// other's URLs.
    static func parse(_ url: URL) -> (bundleIdentifier: String, mealId: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard components.path == path else { return nil }
        guard let items = components.queryItems else { return nil }

        guard let bundleIdentifier = items.first(where: { $0.name == bundleIdParameter })?.value,
              let mealId = items.first(where: { $0.name == mealIdParameter })?.value,
              !bundleIdentifier.isEmpty, !mealId.isEmpty else { return nil }

        return (bundleIdentifier, mealId)
    }

    /// The link for a meal. Written down here rather than only in the AI app so
    /// the format has one owner — GlucOS is the side that has to parse it.
    static func url(bundleIdentifier: String, mealId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = [
            URLQueryItem(name: bundleIdParameter, value: bundleIdentifier),
            URLQueryItem(name: mealIdParameter, value: mealId)
        ]
        return components.url
    }
}
