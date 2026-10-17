import AppKit
import MirrorCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
  let model: SettingsViewModel

  var body: some View {
    TabView {
      AccountSettings(model: model)
        .tabItem { Label("Account", systemImage: "person.crop.circle") }
      FolderSettings(model: model)
        .tabItem { Label("Folders", systemImage: "folder") }
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
    }
    .frame(width: 560, height: 420)
    .safeAreaInset(edge: .bottom) {
      if let error = model.errorMessage ?? model.snapshot.message {
        Text(error)
          .foregroundStyle(.red)
          .font(.callout)
          .padding(8)
      }
    }
  }
}

private struct AccountSettings: View {
  let model: SettingsViewModel

  var body: some View {
    Form {
      LabeledContent("Google account", value: model.accountDescription)
      HStack {
        if model.isSignedIn {
          Button("Sign Out") { Task { await model.signOut() } }
        } else {
          Button(model.isSigningIn ? "Waiting for Browser…" : "Sign In…") {
            Task { await model.signIn() }
          }
          .disabled(!model.canSignIn)
        }
        Button("Import Client File…") {
          guard let url = chooseFile() else { return }
          Task { await model.importClientFile(url) }
        }
      }
      Text(
        "The client file is the JSON Google gives you for a Desktop app OAuth client. "
          + "It's copied to Application Support, never into the repository."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }

  private func chooseFile() -> URL? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }
}

private struct FolderSettings: View {
  let model: SettingsViewModel
  @State private var selection: UUID?
  @State private var pendingFolder: URL?
  @State private var newName = ""
  @State private var removing: RootConfig?

  var body: some View {
    HSplitView {
      VStack(alignment: .leading, spacing: 0) {
        List(model.roots, selection: $selection) { root in
          VStack(alignment: .leading) {
            Text(root.displayName)
            Text(root.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.middle)
          }
          .tag(root.id)
        }
        HStack(spacing: 4) {
          Button("Add", systemImage: "plus") { chooseFolder() }
          Button("Remove", systemImage: "minus") {
            removing = model.roots.first { $0.id == selection }
          }
          .disabled(selection == nil)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(6)
      }
      .frame(minWidth: 180)

      Group {
        if let root = model.roots.first(where: { $0.id == selection }) {
          RootEditor(model: model, root: root).id(root.id)
        } else {
          Text("Select a folder, or add one with +.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .frame(minWidth: 300)
    }
    .sheet(item: $pendingFolder) { url in
      NameSheet(url: url, name: $newName) { confirmed in
        pendingFolder = nil
        guard confirmed else { return }
        Task { await model.addRoot(url, displayName: newName) }
      }
    }
    .confirmationDialog(
      "Stop mirroring “\(removing?.displayName ?? "")”?",
      isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    ) {
      Button("Remove and Trash Drive Folder", role: .destructive) { remove(trash: true) }
      Button("Remove, Keep Drive Folder") { remove(trash: false) }
      Button("Cancel", role: .cancel) { removing = nil }
    } message: {
      Text(
        "Your local notes aren't touched either way. Trashed Drive folders can be restored from Drive's trash."
      )
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Mirror"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    newName = SettingsViewModel.defaultDisplayName(for: url)
    pendingFolder = url
  }

  private func remove(trash: Bool) {
    guard let root = removing else { return }
    removing = nil
    selection = nil
    Task { await model.removeRoot(root.id, trashDriveFolder: trash) }
  }
}

extension URL: @retroactive Identifiable {
  public var id: String { absoluteString }
}

private struct NameSheet: View {
  let url: URL
  @Binding var name: String
  let finish: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Mirror \(url.path)").font(.headline)
      TextField("Name in Google Drive", text: $name)
      HStack {
        Spacer()
        Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
        Button("Add") { finish(true) }.keyboardShortcut(.defaultAction)
      }
    }
    .padding()
    .frame(width: 380)
  }
}

private struct RootEditor: View {
  let model: SettingsViewModel
  let root: RootConfig
  @State private var name: String
  @State private var include: String
  @State private var exclude: String

  init(model: SettingsViewModel, root: RootConfig) {
    self.model = model
    self.root = root
    _name = State(initialValue: root.displayName)
    _include = State(initialValue: SettingsViewModel.patternsText(root.filter.include))
    _exclude = State(initialValue: SettingsViewModel.patternsText(root.filter.exclude))
  }

  var body: some View {
    Form {
      TextField("Name", text: $name)
        .onSubmit { Task { await model.rename(root.id, to: name) } }
      LabeledContent("Folder") {
        Text(root.path).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
      }
      Section("Include patterns, one per line") {
        TextEditor(text: $include).font(.body.monospaced()).frame(minHeight: 50)
      }
      Section("Exclude patterns, one per line") {
        TextEditor(text: $exclude).font(.body.monospaced()).frame(minHeight: 50)
      }
      Text("Hidden files and folders are always skipped. Use *, **, and ?.")
        .font(.callout).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Save") {
          Task {
            if name != root.displayName { await model.rename(root.id, to: name) }
            await model.updatePatterns(for: root.id, include: include, exclude: exclude)
          }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettings: View {
  let model: SettingsViewModel

  var body: some View {
    Form {
      Toggle(
        "Launch at login",
        isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
      Picker(
        "Update strategy",
        selection: Binding(
          get: { model.snapshot.updateStrategy },
          set: { strategy in Task { await model.setUpdateStrategy(strategy) } })
      ) {
        Text("In place (keeps Doc links)").tag(UpdateStrategy.inPlace)
        Text("Replace (new Doc each edit)").tag(UpdateStrategy.replace)
      }
      Text("`mirrorctl probe` tells you which strategy your Drive account supports.")
        .font(.callout).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}
