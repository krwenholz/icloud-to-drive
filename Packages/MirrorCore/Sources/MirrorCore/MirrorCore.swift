/// Identity shared by the app and `mirrorctl`, so both read the same
/// Application Support directory and Keychain entries.
public enum AppIdentity {
  public static let displayName = "Drive Mirror"
  public static let bundleIdentifier = "dev.krw.DriveMirror"
  public static let driveRootFolderName = "iCloud Mirror"
}
