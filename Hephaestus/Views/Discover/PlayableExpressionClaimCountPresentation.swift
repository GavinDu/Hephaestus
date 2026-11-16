/// A missing classification list is not proof that it contains zero claims.
/// The producer explicitly represents missing vs a confirmed empty array.
enum PlayableExpressionClaimCountPresentation {
    static func visualLabel(category: String, count: Int?) -> String {
        guard let count else { return "\(category) · Not reported" }
        return "\(category) · \(count)"
    }

    static func accessibilityLabel(category: String, count: Int?) -> String {
        guard let count else { return "\(category) claims: not reported" }
        return "\(category) claims: \(count)"
    }
}
