import SwiftUI

struct AgendaView: View {
    @Bindable var store: AgendaStore
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if case let .loaded(sections, truncated) = store.state {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.items) { occurrence in
                                AgendaRow(occurrence: occurrence)
                            }
                        } header: {
                            AgendaDayHeader(day: section.day)
                        }
                    }
                    if truncated {
                        Text("Some events are not shown because the result was truncated.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .overlay { statusView }
            .navigationTitle("Agenda")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let defaultGroup = store.groups.first, store.groups.count > 1 {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Picker("Group", selection: $store.selectedGroup) {
                                Text(verbatim: defaultGroup).tag(String?.none)
                                ForEach(store.groups.dropFirst(), id: \.self) { group in
                                    Text(verbatim: group).tag(String?.some(group))
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Group")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onClose)
                }
            }
            .task {
                guard case .idle = store.state else { return }
                await store.load()
            }
            .refreshable { await store.refresh() }
            .onChange(of: store.selectedGroup) { _, _ in
                Task { await store.load() }
            }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch store.state {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView()
        case let .loaded(sections, _) where sections.isEmpty:
            ContentUnavailableView("No upcoming events", systemImage: "calendar")
        case .loaded:
            EmptyView()
        case .disabled:
            ContentUnavailableView("Calendars are off in hestia", systemImage: "calendar.badge.exclamationmark")
        case .unavailable:
            ContentUnavailableView("Calendars are unavailable right now", systemImage: "exclamationmark.triangle")
        case .failed(let message):
            ContentUnavailableView(
                "Couldn’t load agenda",
                systemImage: "exclamationmark.triangle",
                description: Text(verbatim: message)
            )
        }
    }
}

private struct AgendaDayHeader: View {
    @Environment(\.calendar) private var calendar
    let day: Date

    var body: some View {
        if calendar.isDateInToday(day) {
            Text("Today")
        } else if calendar.isDateInTomorrow(day) {
            Text("Tomorrow")
        } else {
            Text(day, format: .dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }
}

private struct AgendaRow: View {
    let occurrence: AgendaOccurrence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                title
                if let location = occurrence.location,
                   !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(verbatim: location)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 3) {
                Group {
                    if occurrence.allDay {
                        Text("All day")
                    } else if let timeRange {
                        timeRange
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                if occurrence.status == .tentative {
                    Text("Tentative")
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: Text {
        if occurrence.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Text("(No title)")
        }
        return Text(verbatim: occurrence.summary)
    }

    private var timeRange: Text? {
        guard case let .instant(start) = occurrence.start,
              case let .instant(end) = occurrence.end else { return nil }
        let from = start.formatted(date: .omitted, time: .shortened)
        // A zero-length event (a reminder, or no known end) shows just its start.
        guard end > start else { return Text(verbatim: from) }
        return Text(verbatim: "\(from) – \(end.formatted(date: .omitted, time: .shortened))")
    }
}
