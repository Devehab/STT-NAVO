import Foundation
import Security

/// Navo used Google Gemini for AI writing before it moved to models on this Mac. This erases
/// what that left behind: the API key in the keychain and its settings. Runs once per launch
/// and does nothing when there is nothing to erase.
enum LegacyGemini {
    static func erase() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.ehab-kahwati.navo",
            kSecAttrAccount as String: "gemini-api-key",
        ]
        SecItemDelete(query as CFDictionary)
        for key in ["geminiKeyHint", "geminiModel"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
