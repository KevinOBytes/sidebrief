import SwiftUI
import AppKit

public struct MemoryManagerView: View {
    @Binding public var activeSpaceId: String
    @Binding public var memoryFacts: [MemoryFact]

    public var onSaveFact: (MemoryFact) -> Void
    public var onDeleteFact: (String) -> Void
    public var onBootstrapImport: (String) -> Void // JSON or text

    @State private var searchQuery: String = ""
    @State private var selectedCategory: String = "All"
    @State private var editingFact: MemoryFact? = nil
    @State private var isCreatingNewFact: Bool = false
    @State private var showImportSheet: Bool = false
    @State private var importText: String = ""

    public init(
        activeSpaceId: Binding<String>,
        memoryFacts: Binding<[MemoryFact]>,
        onSaveFact: @escaping (MemoryFact) -> Void,
        onDeleteFact: @escaping (String) -> Void,
        onBootstrapImport: @escaping (String) -> Void
    ) {
        self._activeSpaceId = activeSpaceId
        self._memoryFacts = memoryFacts
        self.onSaveFact = onSaveFact
        self.onDeleteFact = onDeleteFact
        self.onBootstrapImport = onBootstrapImport
    }

    private var categories: [String] {
        var set = Set(["All"])
        for f in memoryFacts { set.insert(f.category) }
        return Array(set).sorted()
    }

    private var filteredFacts: [MemoryFact] {
        memoryFacts.filter { fact in
            let matchesCategory = (selectedCategory == "All" || fact.category == selectedCategory)
            let matchesSearch = searchQuery.isEmpty ||
                fact.key.localizedCaseInsensitiveContains(searchQuery) ||
                fact.value.localizedCaseInsensitiveContains(searchQuery) ||
                fact.category.localizedCaseInsensitiveContains(searchQuery)
            return matchesCategory && matchesSearch
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            headerBar

            Divider()

            // Filters & Search Bar
            filterBar

            Divider()

            // Facts List
            if filteredFacts.isEmpty {
                emptyStateView
            } else {
                factsListView
            }
        }
        .sheet(item: $editingFact) { fact in
            factEditSheet(fact: fact)
        }
        .sheet(isPresented: $isCreatingNewFact) {
            newFactSheet
        }
        .sheet(isPresented: $showImportSheet) {
            importSheet
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Memory & Context")
                    .font(.system(size: 18, weight: .bold))
                Text("Bootstrapped and extracted memory facts. Injected into live copilot reasoning.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: { showImportSheet = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Bootstrap Memory")
                }
            }

            Button(action: { isCreatingNewFact = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("Add Memory Fact")
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search facts, architecture, people...", text: $searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(7)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Category picker
            Picker("Category", selection: $selectedCategory) {
                ForEach(categories, id: \.self) { cat in
                    Text(cat).tag(cat)
                }
            }
            .frame(width: 160)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.02))
    }

    private var factsListView: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredFacts) { fact in
                    factCard(fact)
                }
            }
            .padding(16)
        }
    }

    private func factCard(_ fact: MemoryFact) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                // Category pill
                Text(fact.category)
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .foregroundColor(.accentColor)
                    .clipShape(Capsule())

                Text(fact.key)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)

                Spacer()

                // Pin toggle
                Button(action: {
                    var updated = fact
                    updated.isPinned.toggle()
                    onSaveFact(updated)
                }) {
                    Image(systemName: fact.isPinned ? "pin.fill" : "pin")
                        .foregroundColor(fact.isPinned ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(fact.isPinned ? "Pinned (always in prompt)" : "Pin to prompt")

                // Edit button
                Button(action: { editingFact = fact }) {
                    Image(systemName: "pencil")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Edit fact")

                // Delete button
                Button(action: { onDeleteFact(fact.id) }) {
                    Image(systemName: "trash")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete fact")
            }

            Text(fact.value)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .lineSpacing(3)
                .textSelection(.enabled)

            HStack {
                Text("Source: \(fact.source)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text("Updated \(fact.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(fact.isPinned ? Color.orange.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No Memory Facts")
                .font(.headline)
            Text("Add facts, key decisions, or bootstrap context for this space.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("Add First Fact") {
                isCreatingNewFact = true
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sheets

    private func factEditSheet(fact: MemoryFact) -> some View {
        FactEditorModal(fact: fact) { updated in
            onSaveFact(updated)
            editingFact = nil
        } onCancel: {
            editingFact = nil
        }
    }

    private var newFactSheet: some View {
        let emptyFact = MemoryFact(
            spaceId: activeSpaceId,
            category: "Architecture",
            key: "",
            value: "",
            source: "manual",
            isPinned: false
        )
        return FactEditorModal(fact: emptyFact) { newFact in
            onSaveFact(newFact)
            isCreatingNewFact = false
        } onCancel: {
            isCreatingNewFact = false
        }
    }

    private var importSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bootstrap Memory")
                .font(.headline)

            Text("Paste JSON or Markdown key-value facts to seed into this context space.")
                .font(.caption)
                .foregroundColor(.secondary)

            TextEditor(text: $importText)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 200)
                .border(Color.secondary.opacity(0.2))

            HStack {
                Button("Cancel") {
                    showImportSheet = false
                    importText = ""
                }
                Spacer()
                Button("Import Facts") {
                    onBootstrapImport(importText)
                    showImportSheet = false
                    importText = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(importText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }
}

// MARK: - Fact Editor Modal

private struct FactEditorModal: View {
    @State private var category: String
    @State private var key: String
    @State private var value: String
    @State private var isPinned: Bool

    let originalFact: MemoryFact
    let onSave: (MemoryFact) -> Void
    let onCancel: () -> Void

    init(fact: MemoryFact, onSave: @escaping (MemoryFact) -> Void, onCancel: @escaping () -> Void) {
        self.originalFact = fact
        self._category = State(initialValue: fact.category)
        self._key = State(initialValue: fact.key)
        self._value = State(initialValue: fact.value)
        self._isPinned = State(initialValue: fact.isPinned)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(originalFact.key.isEmpty ? "New Memory Fact" : "Edit Memory Fact")
                .font(.headline)

            TextField("Category (e.g. Architecture, People, Decisions)", text: $category)
                .textFieldStyle(.roundedBorder)

            TextField("Key / Subject (e.g. Primary Database)", text: $key)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 4) {
                Text("Fact Description / Value:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $value)
                    .frame(height: 90)
                    .border(Color.secondary.opacity(0.2))
            }

            Toggle("Pin to every copilot prompt", isOn: $isPinned)

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save Fact") {
                    var f = originalFact
                    f.category = category.trimmingCharacters(in: .whitespaces)
                    f.key = key.trimmingCharacters(in: .whitespaces)
                    f.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    f.isPinned = isPinned
                    f.updatedAt = Date()
                    onSave(f)
                }
                .buttonStyle(.borderedProminent)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 350)
    }
}
