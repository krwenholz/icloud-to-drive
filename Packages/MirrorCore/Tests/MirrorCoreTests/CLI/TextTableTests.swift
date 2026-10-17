import Testing

@testable import MirrorCore

struct TextTableTests {
  @Test func alignsColumnsAndLeavesTheLastUnpadded() {
    let table = TextTable.render(
      headers: ["Result", "Check", "Detail"],
      rows: [["PASS", "Upload", "ok"], ["FAIL", "A longer check", "two\nlines"]])
    #expect(
      table == """
        Result  Check           Detail
        ------  --------------  ---------
        PASS    Upload          ok
        FAIL    A longer check  two lines
        """)
  }
}
