import Foundation

enum IdentifyClassNames {
    // MARK: - Properties

    private static let textPromptResourceName = "yoloe26n_text_names"
    private static let resourceExtension = "json"

    /// Text-prompt YOLOE-26n vocabulary (ml/household_classes.txt), in model class index order.
    /// Static `let` is lazily initialized, so the JSON is decoded on first access.
    static let yoloeTextPrompt: [String] = loadNames(
        resource: textPromptResourceName,
        withExtension: resourceExtension
    )

    // MARK: - Helpers

    private static func loadNames(resource: String, withExtension fileExtension: String) -> [String] {
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else {
            assertionFailure("Missing \(resource).\(fileExtension) in bundle")
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            assertionFailure("Failed to decode \(resource).\(fileExtension): \(error)")
            return []
        }
    }
}
