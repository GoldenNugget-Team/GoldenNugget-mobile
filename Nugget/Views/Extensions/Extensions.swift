//
//  Extensions.swift
//  Nugget
//
//  Created by lemin on 9/9/24.
//

import Foundation

extension URL {
    static var documents: URL {
        return FileManager
            .default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

/// The reference's `IOSSearchEdit.matches` (`gui/ios/components.py:227`): every
/// whitespace-separated word of the query must appear in the joined haystack,
/// case- and diacritic-insensitively.  An empty (or whitespace-only) query
/// matches everything, which is what makes the field optional.
///
/// Shared by the Tweaks and Daemons pages; the desktop gives both the same
/// search widget, so the two lists cannot disagree about what a query means.
func searchMatches(query: String, _ texts: String...) -> Bool {
    let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !words.isEmpty else { return true }
    let haystack = texts.joined(separator: " ")
    return words.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
}
