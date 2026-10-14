import Foundation
import CoreServices

/// Deletes local accounts through macOS's identity API, as Users & Groups does. A root shell can't: Directory Services
/// answers it with eDSPermissionError unless the request comes from an app macOS trusts with the change, so the
/// deletion happens in Spare itself, and macOS asks for an administrator's password.
public enum LocalAccounts {
    /// Permission to change Directory Services, granted once an administrator types their password into macOS's
    /// prompt. Good for several deletions.
    public final class Permission: @unchecked Sendable {
        let reference: AuthorizationRef
        init(_ reference: AuthorizationRef) { self.reference = reference }
        deinit { AuthorizationFree(reference, [.destroyRights]) }
    }

    /// The right macOS checks "for making Directory Services changes".
    static let right = "system.services.directory.configure"

    /// Asks macOS for an administrator's password. The permission, or why there's none ("Cancelled." when the person
    /// cancelled).
    public static func ask(prompt: String) -> (permission: Permission?, problem: String?) {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            return (nil, "macOS couldn't start asking for a password.")
        }
        let permission = Permission(reference)
        let status: OSStatus = right.withCString { name in
            prompt.withCString { text in
            kAuthorizationEnvironmentPrompt.withCString { promptName in
                var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                var message = AuthorizationItem(name: promptName, valueLength: strlen(text),
                                                value: UnsafeMutableRawPointer(mutating: text), flags: 0)
                return withUnsafeMutablePointer(to: &item) { items in
                    withUnsafeMutablePointer(to: &message) { messages in
                        var rights = AuthorizationRights(count: 1, items: items)
                        var environment = AuthorizationEnvironment(count: 1, items: messages)
                        return AuthorizationCopyRights(reference, &rights, &environment, [.interactionAllowed, .extendRights, .preAuthorize], nil)
                    }
                }
            }
            }
        }
        switch status {
        case errAuthorizationSuccess: return (permission, nil)
        case errAuthorizationCanceled: return (nil, "Cancelled.")
        case errAuthorizationDenied: return (nil, "That password isn't an administrator's.")
        default: return (nil, "macOS didn't give permission (\(status)).")
        }
    }

    /// Deletes the account and, if there is one, the group of the same name installers create with it. nil when the
    /// account is gone.
    public static func delete(_ name: String, permission: Permission) -> String? {
        guard let account = find(name, class: kCSIdentityClassUser) else { return "macOS has no account named \(name)." }
        CSIdentityDelete(account)
        var error: Unmanaged<CFError>?
        guard CSIdentityCommit(account, permission.reference, &error) else { return describe(error?.takeRetainedValue()) }
        // The group: only one that matches the name exactly, and quietly, since many accounts have none.
        if let group = find(name, class: kCSIdentityClassGroup) {
            CSIdentityDelete(group)
            _ = CSIdentityCommit(group, permission.reference, nil)
        }
        return nil
    }

    static func find(_ name: String, class identityClass: Int) -> CSIdentity? {
        let authority = CSGetLocalIdentityAuthority().takeUnretainedValue()
        let query = CSIdentityQueryCreateForName(kCFAllocatorDefault, name as CFString, CSIdentityQueryStringComparisonMethod(kCSIdentityQueryStringEquals),
                                                 CSIdentityClass(identityClass), authority).takeRetainedValue()
        guard CSIdentityQueryExecute(query, CSIdentityQueryFlags(kCSIdentityQueryIncludeHiddenIdentities), nil) else { return nil }
        let results = CSIdentityQueryCopyResults(query).takeRetainedValue()
        return (0..<CFArrayGetCount(results))
            .map { unsafeBitCast(CFArrayGetValueAtIndex(results, $0), to: CSIdentity.self) }
            .first { CSIdentityGetPosixName($0).takeUnretainedValue() as String == name }
    }

    static func describe(_ error: CFError?) -> String {
        guard let error else { return "macOS didn't say why." }
        let code = CFErrorGetCode(error)
        if code == Int(errAuthorizationCanceled) || code == Int(errAuthorizationDenied) && CFErrorGetDomain(error) as String == NSOSStatusErrorDomain {
            return code == Int(errAuthorizationCanceled) ? "Cancelled." : "That password isn't an administrator's."
        }
        return "\(CFErrorCopyDescription(error) as String) (\(CFErrorGetDomain(error) as String) \(code))"
    }
}
