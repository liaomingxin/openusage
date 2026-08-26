import Foundation

/// Everything OpenUsage reads out of Cursor's `auth/stripe` response, split out from the meter mapping
/// in `CursorUsageMapper`: the prepaid balance behind the Credits row, whether the plan renews or ends,
/// and whether the account is in payment trouble. Every field not read here — `paymentId`, the card
/// metadata, the plan-shape flags — is never read, logged, or persisted.
extension CursorUsageMapper {
    /// Whether `auth/stripe` says the plan will stop at the end of the current period rather than
    /// renew: a non-null `pendingCancellationDate`, or a `subscriptionStatus` that has left "active".
    static func subscriptionIsEnding(from body: [String: Any]?) -> Bool {
        guard let body else { return false }
        if let pending = body["pendingCancellationDate"], !(pending is NSNull) {
            return true
        }
        guard let status = (body["subscriptionStatus"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            // No status reported is not evidence of a cancellation — keep the row reading "Renews".
            return false
        }
        return status.lowercased() != "active"
    }

    /// The provider-header warning text for a Cursor account whose payment is failing. One fixed
    /// sentence pair: `paymentRecoveryAction`'s value set is undocumented, so it steers the warning
    /// without ever being shown, logged, or persisted.
    static let paymentFailedWarning =
        "Cursor couldn't take your last payment. Update your payment method in the Cursor dashboard to keep your plan."

    /// The dunning state `auth/stripe` reports: `lastPaymentFailed`, or a queued
    /// `paymentRecoveryAction`. A healthy account sends `false`/`null` (and older responses may omit
    /// both), so "absent" is the normal case and returns `nil` — no warning, no row, no error.
    ///
    /// `subscriptionStatus` is deliberately *not* read here even though a failing subscription
    /// eventually leaves "active": its full value set is unknown, and it already flips the renewal row
    /// to "Ends". Warning off the two payment fields alone keeps the triangle for real billing trouble
    /// instead of nagging on a status we have never seen.
    static func paymentFailureWarning(from body: [String: Any]?) -> String? {
        guard let body else { return nil }
        let lastPaymentFailed = body["lastPaymentFailed"] as? Bool == true
        guard lastPaymentFailed || hasPaymentRecoveryAction(body["paymentRecoveryAction"]) else {
            return nil
        }
        return paymentFailedWarning
    }

    /// `paymentRecoveryAction` is `null` on a healthy account and an undocumented shape otherwise, so
    /// any non-null value counts as "Cursor wants the user to fix something" — except an empty string,
    /// which some payloads use where they mean null. Mirrors the `pendingCancellationDate` check above.
    private static func hasPaymentRecoveryAction(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil
        }
        return true
    }

    /// The prepaid balance behind the Credits row. Stripe carries account credit as a *negative*
    /// `customerBalance`, so anything zero or positive is money owed, not money available.
    static func stripeBalanceCents(from body: [String: Any]?) -> Double {
        guard let body,
              let balance = ProviderParse.number(body["customerBalance"]),
              balance < 0
        else {
            return 0
        }
        return abs(balance)
    }
}
