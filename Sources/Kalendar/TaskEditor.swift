// Tasks in the UI (§5.1, §7.3, §10): the task form and detail popover, the task row, its context
// menu, and the Tasks view.
import AppKit
import KalendarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class TaskEditorModel {
    let agenda: AgendaModel
    let writer: EventWriter
    /// The new-item form: `draft` follows the parsed input until it is added (§5).
    let isNew: Bool
    private(set) var original: TaskItem
    var draft: TaskItem
    /// The input named a time, which Google Tasks can't store (§5.1).
    private(set) var timeIgnored = false
    /// The list menu's choices: every list for a new task; for an existing one, its own list and
    /// the lists it can move to.
    let lists: [TaskList]

    init(task: TaskItem, isNew: Bool = false, timeIgnored: Bool = false, agenda: AgendaModel, writer: EventWriter) {
        self.isNew = isNew
        original = task
        draft = task
        self.timeIgnored = timeIgnored && task.due != nil
        self.agenda = agenda
        self.writer = writer
        let destinations = isNew ? [] : Set(writer.destinations(for: task, among: agenda.taskLists).map(\.key))
        lists = agenda.taskLists.filter { isNew || $0.key == task.listKey || destinations.contains($0.key) }
        writer.clearError()
    }

    /// The input changed: fields the user hasn't edited by hand take the new parse (§5.2).
    func follow(_ parsed: TaskItem, timeIgnored: Bool) {
        if draft.title == original.title { draft.title = parsed.title }
        if draft.due == original.due { draft.due = parsed.due }
        if draft.listKey == original.listKey {
            draft.account = parsed.account
            draft.listId = parsed.listId
        }
        original = parsed
        self.timeIgnored = timeIgnored && draft.due != nil
    }

    var hasChanges: Bool { draft != original }
    var canAdd: Bool { !draft.title.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The detail popover saves on close (§6): field edits on the task's list, then the move.
    func shouldClose() -> Bool {
        guard !isNew, hasChanges else { return true }
        var edited = draft
        edited.account = original.account
        edited.listId = original.listId
        edited.title = edited.title.trimmingCharacters(in: .whitespaces)
        if edited != original { writer.update(edited) }
        if draft.listKey != original.listKey, let list = agenda.taskList(forKey: draft.listKey) {
            writer.move(edited, to: list)
        }
        return true
    }

    func setList(_ list: TaskList) {
        draft.account = list.account
        draft.listId = list.id
    }
}

/// The task form (§5.1) and a task's detail popover.
struct TaskEditor: View {
    @Bindable var model: TaskEditorModel
    /// The new-item form's Add Task button; nil for an existing task.
    var onAdd: (() -> Void)?
    /// The ▣ | ✓ toggle, on the new-item form only.
    var onKind: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                TextField("Title", text: $model.draft.title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .uiFont(16, weight: .semibold)
                    .foregroundStyle(Theme.text)
                if let onKind { KindToggle(isTask: true, set: onKind) }
            }
            Row("due") {
                Toggle("On a day", isOn: Binding(
                    get: { model.draft.due != nil },
                    set: { model.draft.due = $0 ? Calendar.current.startOfDay(for: Date()) : nil }))
                    .toggleStyle(.checkbox)
                if let due = model.draft.due {
                    DatePicker("", selection: Binding(get: { due }, set: { model.draft.due = Calendar.current.startOfDay(for: $0) }),
                               displayedComponents: [.date])
                        .labelsHidden()
                }
            }
            if model.timeIgnored {
                Text("Google Tasks stores dates only")
                    .uiFont(11)
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, labelWidth + 8)
            }
            Row("list") { TaskListMenu(model: model) }
            TextField("Notes", text: Binding(get: { model.draft.notes ?? "" },
                                             set: { model.draft.notes = $0.isEmpty ? nil : $0 }), axis: .vertical)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.text)
                .lineLimit(1...8)
                .padding(.top, 4)
            WriteError(writer: model.writer)
            if let onAdd {
                HStack {
                    Spacer()
                    Button("Add Task", action: onAdd)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canAdd)
                    Spacer()
                }
            }
        }
        .padding(16)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .tint(Theme.accent)
        .uiFont(13)
    }
}

/// The task lists of both accounts, grouped by account (§5.1).
private struct TaskListMenu: View {
    let model: TaskEditorModel

    var body: some View {
        Menu {
            TaskListSections(lists: model.lists, pick: model.setList)
        } label: {
            Text(model.agenda.taskList(forKey: model.draft.listKey)?.title ?? "Tasks")
        }
        .fixedSize()
        .disabled(model.lists.isEmpty)
    }
}

/// Task lists grouped by account (§5.1).
private struct TaskListSections: View {
    let lists: [TaskList]
    let pick: (TaskList) -> Void

    var body: some View {
        let byAccount = Dictionary(grouping: lists, by: \.account)
        ForEach(byAccount.keys.sorted(), id: \.self) { account in
            Section(account) {
                ForEach(byAccount[account]!, id: \.key) { list in
                    Button(list.title) { pick(list) }
                }
            }
        }
    }
}

/// ▣ | ✓: switches the new-item form between an event and a task (§5.1).
struct KindToggle: View {
    let isTask: Bool
    let set: (Bool) -> Void

    var body: some View {
        Picker("", selection: Binding(get: { isTask }, set: set)) {
            Image(systemName: "calendar").tag(false).accessibilityLabel("Event")
            Image(systemName: "checkmark").tag(true).accessibilityLabel("Task")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// A task in the agenda (§4.3) or the Tasks view (§10): circle checkbox, due line, title.
struct TaskRow: View {
    let task: TaskItem
    let actions: PopoverModel
    /// The Tasks view always shows the due date; the agenda shows it only for overdue tasks.
    var showsDue = false
    var depth = 0
    @State private var anchor: NSView?

    var body: some View {
        let today = actions.agenda.today
        let overdue = !task.completed && (task.due.map { $0 < today } ?? false)
        HStack(alignment: .top, spacing: 8) {
            Button { actions.writer.setCompleted(task, !task.completed) } label: {
                Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                    .uiFont(13)
                    .foregroundStyle(task.completed ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.completed ? "Uncomplete" : "Complete")
            VStack(alignment: .leading, spacing: 1) {
                if let due = task.due, showsDue || overdue {
                    // "Sep 28"; a date in another year shows it: "Jul 17, 2023"
                    Text(Calendar.current.isDate(due, equalTo: today, toGranularity: .year)
                         ? due.formatted(.dateTime.month(.abbreviated).day())
                         : due.formatted(.dateTime.month(.abbreviated).day().year()))
                        .uiFont(11)
                        .foregroundStyle(overdue ? Theme.wait : Theme.muted)
                }
                Text(task.title.isEmpty ? "(No title)" : task.title)
                    .uiFont(13)
                    .foregroundStyle(task.completed ? Theme.muted : Theme.text)
                    .strikethrough(task.completed)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(depth) * 20)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .rowSelection(actions.agenda.selectedEvent == task.key)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(AnchorView(view: $anchor))
        .onTapGesture { actions.openTask(task, anchor: anchor) }
        .contextMenu { TaskContextMenu(task: task, actions: actions) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText(overdue: overdue))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: task.completed ? "Uncomplete" : "Complete") {
            actions.writer.setCompleted(task, !task.completed)
        }
    }
}

extension TaskRow {
    /// "Task, pay office rent, overdue, due Oct 1" for VoiceOver.
    func accessibilityText(overdue: Bool) -> String {
        var parts = ["Task", task.title.isEmpty ? "No title" : task.title]
        if task.completed { parts.append("completed") }
        if overdue { parts.append("overdue") }
        if let due = task.due { parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))") }
        return parts.joined(separator: ", ")
    }
}

/// Right-click on a task (§7.3).
struct TaskContextMenu: View {
    let task: TaskItem
    let actions: PopoverModel

    var body: some View {
        Button(task.completed ? "Uncomplete" : "Complete") { actions.writer.setCompleted(task, !task.completed) }
        let destinations = actions.writer.destinations(for: task, among: actions.agenda.taskLists)
        Menu("Move to List") {
            TaskListSections(lists: destinations) { actions.writer.move(task, to: $0) }
        }
        .disabled(destinations.isEmpty)
        Divider()
        Button("Duplicate as Event") { actions.duplicateAsEvent(task) }
        Button("Delete") { actions.deleteTask(task) }
    }
}

/// The Tasks view (§10): "All Tasks", every list merged.
struct TasksView: View {
    let model: PopoverModel

    var body: some View {
        @Bindable var agenda = model.agenda
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("All Tasks")
                    .uiFont(22, weight: .semibold)
                    .foregroundStyle(Theme.text)
                Spacer()
                Menu {
                    Picker("Sort By", selection: $agenda.taskSort) {
                        ForEach(TaskSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Show Completed", isOn: $agenda.showCompletedTasks)
                } label: {
                    Image(systemName: "ellipsis.circle").foregroundStyle(Theme.muted)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Task options")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            Theme.line.frame(height: 1)
            if agenda.taskRows.isEmpty {
                Text(agenda.taskLists.isEmpty ? "No task lists" : "No tasks")
                    .uiFont(12)
                    .foregroundStyle(Theme.muted)
                    .padding(16)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(agenda.taskRows, id: \.task.key) { row in
                            TaskRow(task: row.task, actions: model, showsDue: true, depth: row.depth)
                        }
                    }
                    .padding(.vertical, 6)
                }
                // keyboard selection (§11) keeps the selected row on screen
                .onChange(of: agenda.selectedEvent) {
                    if let key = agenda.selectedEvent { proxy.scrollTo(key) }
                }
            }
        }
    }
}
