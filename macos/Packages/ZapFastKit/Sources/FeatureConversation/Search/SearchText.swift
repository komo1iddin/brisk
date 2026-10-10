import Foundation

/// The search bar's words, from `Resources/<language>.lproj/Search.strings`.
/// Views name a key; what it says, in each language, lives in those files.
func searchText(_ key: String.LocalizationValue) -> String {
    String(localized: key, table: "Search", bundle: .module)
}
