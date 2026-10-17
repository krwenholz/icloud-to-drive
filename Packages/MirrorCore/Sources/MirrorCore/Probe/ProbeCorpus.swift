/// Markdown the probe uploads. Embedded as literals so the binary works wherever it's copied.
public struct ProbeFixture: Equatable, Sendable {
  public var name: String
  public var markdown: String
}

public enum ProbeCorpus {
  /// The fixture whose original and exported text the probe prints side by side.
  public static let comparisonFixtureName = "Conversion sampler"

  public static let fixtures: [ProbeFixture] = [
    ProbeFixture(
      name: comparisonFixtureName,
      markdown: """
        # Conversion sampler

        ## Lists

        - First item
          - Nested item with **bold** and *italic*
            - Third level with `inline code`
        - Second item

        1. One
        2. Two

        ## Links and code

        A [link to Example](https://example.com) inside a sentence.

        ```swift
        let greeting = "hello"
        print(greeting)
        ```

        ## Table

        | Name  | Count |
        |-------|-------|
        | Apple | 3     |
        | Pear  | 5     |
        """),
    ProbeFixture(
      name: "Front matter",
      markdown: """
        ---
        title: Front matter probe
        tags: [probe, yaml]
        ---

        # After the front matter

        Only this body should reach Drive.
        """),
    ProbeFixture(
      name: "Plain note",
      markdown: """
        # Plain note

        Just a paragraph with *emphasis* and **strong** text.
        """),
  ]
}
