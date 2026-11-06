//
//  WorkerDeviceToken.swift
//  leanring-buddy
//
//  The Worker refuses any request without a device token. The token lives in the
//  Keychain rather than the app bundle, because anything in a bundle can be extracted
//  and would be shared by every copy of the app. `scripts/mint-device-token.mjs` puts
//  it there.
//

import Foundation
import Security

enum WorkerDeviceToken {
    // These must match scripts/mint-device-token.mjs.
    private static let keychainService = "me.ivyx.ivy.worker-device-token"
    private static let keychainAccount = "device"

    /// Without a token the request still goes out, and the Worker answers 401. That keeps
    /// one failure path, whether the token is missing, expired, or revoked.
    static func addAuthorizationHeader(to request: inout URLRequest) {
        guard let deviceToken = readDeviceTokenFromKeychain() else {
            print("⚠️ No Worker device token in the Keychain. Run scripts/mint-device-token.mjs.")
            return
        }
        request.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization")
    }

    /// For code that builds its own requests, like the lesson engine.
    static func readDeviceToken() -> String? {
        readDeviceTokenFromKeychain()
    }

    private static func readDeviceTokenFromKeychain() -> String? {
        let keychainQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var keychainResult: AnyObject?
        let keychainStatus = SecItemCopyMatching(keychainQuery as CFDictionary, &keychainResult)
        guard keychainStatus == errSecSuccess, let deviceTokenData = keychainResult as? Data else {
            return nil
        }
        return String(data: deviceTokenData, encoding: .utf8)
    }
}
