import Foundation
import Security
import CommonCrypto
import CryptoKit

// Reads ISP session cookies directly from Chrome's on-disk SQLite database,
// decrypts them using the "Chrome Safe Storage" key from the macOS Keychain,
// and returns a cookie string ready for use in the Cookie HTTP header.
//
// Chrome v10 cookie encryption (macOS):
//   key = PBKDF2-HMAC-SHA1(keychain_password_utf8, salt="saltysalt", iterations=1003, keyLen=16)
//   plaintext_block = 32_byte_nonce + cookie_value + PKCS7_padding
//   encrypted_value = "v10" + AES_128_CBC(plaintext_block, key, IV=16_spaces)
struct ChromeCookieReader {

    enum ReaderError: LocalizedError {
        case keychainDenied
        case keychainError(OSStatus)
        case databaseNotFound
        case databaseCopyFailed(String)
        case sqliteError(String)
        case noISPCookiesFound

        var errorDescription: String? {
            switch self {
            case .keychainDenied:
                return "Access to Chrome Safe Storage was denied. Grant Keychain access and try again."
            case .keychainError(let s):
                return "Keychain error \(s)"
            case .databaseNotFound:
                return "Chrome cookie database not found — is Chrome installed?"
            case .databaseCopyFailed(let s):
                return "Could not copy Chrome DB: \(s)"
            case .sqliteError(let s):
                return "SQLite error: \(s)"
            case .noISPCookiesFound:
                return "No ISP cookies found in Chrome — log in to ISP in Chrome first."
            }
        }
    }

    // Host we care about. Matches both the bare host and the .host form Chrome stores.
    private static let ispHost = "isp.hec.net.sap"

    // The cookies we need, in order. We'll build "name=value; name=value" from whatever is present.
    private static let targetCookies = ["sap-usercontext", "saplbISP", "SAP_SESSIONID_ISP_001"]

    static func readISPCookies() throws -> String {
        let key = try getDecryptionKey()
        let cookies = try queryCookies(decryptionKey: key)
        guard !cookies.isEmpty else { throw ReaderError.noISPCookiesFound }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - Keychain

    private static func getDecryptionKey() throws -> Data {
        var item: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      "Chrome Safe Storage",
            kSecAttrAccount:      "Chrome",
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecUserCanceled || status == errSecInteractionNotAllowed {
            throw ReaderError.keychainDenied
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ReaderError.keychainError(status)
        }
        let password = data
        return pbkdf2Key(password: password)
    }

    private static func pbkdf2Key(password: Data) -> Data {
        let salt     = [UInt8]("saltysalt".utf8)
        let pwBytes  = [UInt8](password)
        var key      = [UInt8](repeating: 0, count: 16)
        CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            pwBytes, pwBytes.count,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1003,
            &key, 16
        )
        return Data(key)
    }

    // MARK: - SQLite

    private struct RawCookie { let name: String; let encryptedValue: Data }
    private struct DecryptedCookie { let name: String; let value: String }

    private static func queryCookies(decryptionKey: Data) throws -> [DecryptedCookie] {
        let dbPath = (("~/Library/Application Support/Google/Chrome/Default/Cookies") as NSString)
            .expandingTildeInPath
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("isp_chrome_cookies_\(Int.random(in: 100000...999999)).db")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Chrome holds a shared lock on the DB. Read it as raw Data (bypasses the lock)
        // then write to a temp path for SQLite to open.
        let dbData: Data
        do {
            dbData = try Data(contentsOf: URL(fileURLWithPath: dbPath), options: .uncached)
        } catch {
            throw ReaderError.databaseCopyFailed("Cannot read Chrome DB — grant Full Disk Access to ISP Equipment Lookup in System Settings > Privacy & Security > Full Disk Access. (\(error.localizedDescription))")
        }
        guard dbData.count > 0 else {
            throw ReaderError.databaseCopyFailed("Cannot read Chrome DB — grant Full Disk Access to ISP Equipment Lookup in System Settings > Privacy & Security > Full Disk Access.")
        }
        try dbData.write(to: tmp)

        let raws = try readRawCookies(from: tmp.path)
        return raws.compactMap { raw -> DecryptedCookie? in
            guard let plain = decrypt(data: raw.encryptedValue, key: decryptionKey) else { return nil }
            return DecryptedCookie(name: raw.name, value: plain)
        }
    }

    private static func readRawCookies(from path: String) throws -> [RawCookie] {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openStatus == SQLITE_OK, let db = db else {
            throw ReaderError.sqliteError("Could not open DB (status \(openStatus))")
        }
        defer { sqlite3_close(db) }

        // Use a literal SQL string to avoid sqlite3_bind_text lifetime issues with Swift strings.
        let sql = "SELECT name, encrypted_value FROM cookies WHERE host_key = 'isp.hec.net.sap' OR host_key = '.isp.hec.net.sap'"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt = stmt else {
            throw ReaderError.sqliteError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var results: [RawCookie] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let namePtr = sqlite3_column_text(stmt, 0) else { continue }
            let name = String(cString: namePtr)
            guard targetCookies.contains(name) else { continue }

            let byteCount = sqlite3_column_bytes(stmt, 1)
            let blob = sqlite3_column_blob(stmt, 1)
            guard let blob = blob, byteCount > 0 else { continue }
            results.append(RawCookie(name: name, encryptedValue: Data(bytes: blob, count: Int(byteCount))))
        }

        return targetCookies.compactMap { name in results.first(where: { $0.name == name }) }
    }

    // MARK: - Decryption

    // Chrome's v10 encrypted cookie format (macOS):
    //   "v10" + AES_CBC(32_byte_nonce + value + PKCS7_padding, key, IV=16_spaces)
    // The 32-byte nonce is prepended to the plaintext by Chrome before encrypting.
    // After decrypting, strip the nonce and PKCS7 padding to get the actual value.
    private static let chromeNonceLength = 32

    private static func decrypt(data: Data, key: Data) -> String? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else {
            return String(data: data, encoding: .utf8)
        }
        let ctBytes  = [UInt8](data.dropFirst(3))
        let keyBytes = [UInt8](key)
        let ivBytes  = [UInt8](repeating: 0x20, count: 16)
        let bufSize  = ctBytes.count + kCCBlockSizeAES128
        var out      = [UInt8](repeating: 0, count: bufSize)
        var outLen: size_t = 0

        let status = CCCrypt(
            CCOperation(kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES128),
            CCOptions(kCCOptionPKCS7Padding),
            keyBytes, kCCKeySizeAES128,
            ivBytes,
            ctBytes, ctBytes.count,
            &out, bufSize,
            &outLen
        )
        guard status == kCCSuccess, outLen > chromeNonceLength else { return nil }
        return String(bytes: out[chromeNonceLength..<outLen], encoding: .utf8)
    }
}

// SQLite C API bridge — already available via macOS SDK, no extra imports needed.
private let SQLITE_OPEN_READONLY: Int32 = 0x00000001
private let SQLITE_OK:    Int32 = 0
private let SQLITE_ROW:   Int32 = 100
@_silgen_name("sqlite3_open_v2")
private func sqlite3_open_v2(_ filename: UnsafePointer<CChar>?,
                              _ ppDb: UnsafeMutablePointer<OpaquePointer?>?,
                              _ flags: Int32,
                              _ zVfs: UnsafePointer<CChar>?) -> Int32
@_silgen_name("sqlite3_close")
private func sqlite3_close(_ db: OpaquePointer?) -> Int32
@_silgen_name("sqlite3_prepare_v2")
private func sqlite3_prepare_v2(_ db: OpaquePointer?,
                                 _ zSql: UnsafePointer<CChar>?,
                                 _ nByte: Int32,
                                 _ ppStmt: UnsafeMutablePointer<OpaquePointer?>?,
                                 _ pzTail: UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
@_silgen_name("sqlite3_bind_text")
private func sqlite3_bind_text(_ stmt: OpaquePointer?,
                                _ i: Int32,
                                _ zData: UnsafePointer<CChar>?,
                                _ nData: Int32,
                                _ destructor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)?) -> Int32
@_silgen_name("sqlite3_step")
private func sqlite3_step(_ pStmt: OpaquePointer?) -> Int32
@_silgen_name("sqlite3_column_text")
private func sqlite3_column_text(_ pStmt: OpaquePointer?, _ iCol: Int32) -> UnsafePointer<UInt8>?
@_silgen_name("sqlite3_column_blob")
private func sqlite3_column_blob(_ pStmt: OpaquePointer?, _ iCol: Int32) -> UnsafeRawPointer?
@_silgen_name("sqlite3_column_bytes")
private func sqlite3_column_bytes(_ pStmt: OpaquePointer?, _ iCol: Int32) -> Int32
@_silgen_name("sqlite3_finalize")
private func sqlite3_finalize(_ pStmt: OpaquePointer?) -> Int32
@_silgen_name("sqlite3_errmsg")
private func sqlite3_errmsg(_ db: OpaquePointer?) -> UnsafePointer<CChar>
@_silgen_name("sqlite3_column_int64")
private func sqlite3_column_int64(_ pStmt: OpaquePointer?, _ iCol: Int32) -> Int64
