/// Plain-text tables with padded columns, so probe results line up in a terminal.
public enum TextTable {
  public static func render(headers: [String], rows: [[String]]) -> String {
    let columns = headers.count
    let cleaned = rows.map { row in
      (0..<columns).map { index in
        // A multi-line cell would break the alignment of everything after it.
        index < row.count ? row[index].replacingOccurrences(of: "\n", with: " ") : ""
      }
    }
    let widths = (0..<columns).map { index in
      ([headers[index]] + cleaned.map { $0[index] }).map(\.count).max() ?? 0
    }
    func line(_ cells: [String]) -> String {
      let padded = cells.enumerated().map { index, cell in
        index == columns - 1
          ? cell : cell + String(repeating: " ", count: widths[index] - cell.count)
      }
      return padded.joined(separator: "  ")
    }
    let rule = widths.map { String(repeating: "-", count: $0) }
    return ([line(headers), line(rule)] + cleaned.map(line)).joined(separator: "\n")
  }
}
