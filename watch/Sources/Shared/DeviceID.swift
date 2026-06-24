//
//  DeviceID.swift
//  Stable per-install device id, shared by every client (watch + phone).
//
//  This id is the owner key the backend binds sessions to (resume, agent listing,
//  render mode, and future push all key off it). It is kept out of the keychain for
//  simplicity — fine for a non-secret routing id. The platform prefix is purely
//  cosmetic (it shows up in backend logs / the agent list), so the two clients are
//  distinguishable at a glance; existing installs keep whatever id they already stored.
//

import Foundation

enum DeviceID {
    private static let key = "pinch.deviceId"

    #if os(watchOS)
    private static let platformPrefix = "watch-"
    #else
    private static let platformPrefix = "phone-"
    #endif

    static var current: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = platformPrefix + UUID().uuidString.prefix(8).lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }
}
