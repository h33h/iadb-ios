import Foundation

enum DecimalDigits {
    static func asciiDigits(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var normalized = ""
        normalized.reserveCapacity(trimmed.count)
        for character in trimmed {
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first,
                  CharacterSet.decimalDigits.contains(scalar),
                  let value = character.wholeNumberValue,
                  (0...9).contains(value) else {
                return nil
            }
            normalized.append(String(value))
        }
        return normalized
    }

}
