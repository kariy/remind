import EventKit
import Foundation

// MARK: - Helpers

let store = EKEventStore()

func requestAccess() async throws {
    if #available(macOS 14.0, *) {
        try await store.requestFullAccessToReminders()
    } else {
        let granted = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Bool, Error>) in
            store.requestAccess(to: .reminder) { granted, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: granted) }
            }
        }
        guard granted else {
            throw RemindError.accessDenied
        }
    }
}

enum RemindError: LocalizedError {
    case accessDenied
    case listNotFound(String)
    case reminderNotFound(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Access to Reminders was denied. Grant access in System Settings > Privacy & Security > Reminders."
        case .listNotFound(let name):
            return "Reminder list '\(name)' not found."
        case .reminderNotFound(let id):
            return "Reminder '\(id)' not found."
        }
    }
}

func findList(named name: String?) throws -> EKCalendar {
    if let name {
        guard let cal = store.calendars(for: .reminder).first(where: {
            $0.title.localizedCaseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw RemindError.listNotFound(name)
        }
        return cal
    }
    return store.defaultCalendarForNewReminders()!
}

func parseDate(_ string: String) -> DateComponents? {
    let formatters: [(String, DateFormatter)] = [
        ("yyyy-MM-dd HH:mm", {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "en_US_POSIX"); return f
        }()),
        ("yyyy-MM-dd", {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
        }()),
    ]
    for (_, formatter) in formatters {
        if let date = formatter.date(from: string) {
            let cal = Calendar.current
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            // Only include time components if time was provided
            if !string.contains(":") {
                comps.hour = nil
                comps.minute = nil
            }
            return comps
        }
    }
    // Relative: +Nd or +Nh or +Nm
    let pattern = #"^\+(\d+)([dhm])$"#
    if let match = string.range(of: pattern, options: .regularExpression) {
        let s = String(string[match])
        let num = Int(s.dropFirst().dropLast())!
        let unit = s.last!
        let cal = Calendar.current
        var date = Date()
        switch unit {
        case "d": date = cal.date(byAdding: .day, value: num, to: date)!
        case "h": date = cal.date(byAdding: .hour, value: num, to: date)!
        case "m": date = cal.date(byAdding: .minute, value: num, to: date)!
        default: break
        }
        return cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
    return nil
}

func formatDate(_ comps: DateComponents?) -> String {
    guard let comps else { return "none" }
    let cal = Calendar.current
    guard let date = cal.date(from: comps) else { return "none" }
    let f = DateFormatter()
    if comps.hour != nil {
        f.dateFormat = "yyyy-MM-dd HH:mm"
    } else {
        f.dateFormat = "yyyy-MM-dd"
    }
    return f.string(from: date)
}

func printReminder(_ r: EKReminder) {
    let status = r.isCompleted ? "[x]" : "[ ]"
    let due = formatDate(r.dueDateComponents)
    let priority = r.priority > 0 ? " p\(r.priority)" : ""
    print("\(status) \(r.title ?? "(untitled)")  due:\(due)\(priority)  list:\(r.calendar.title)  id:\(r.calendarItemIdentifier)")
}

// MARK: - Commands

func cmdAdd(_ args: [String]) async throws {
    var title: String?
    var dueStr: String?
    var listName: String?
    var priority: Int = 0
    var notes: String?

    var i = 0
    var titleParts: [String] = []
    while i < args.count {
        switch args[i] {
        case "--due", "-d":
            i += 1; dueStr = args[i]
        case "--list", "-l":
            i += 1; listName = args[i]
        case "--priority", "-p":
            i += 1; priority = Int(args[i]) ?? 0
        case "--notes", "-n":
            i += 1; notes = args[i]
        default:
            titleParts.append(args[i])
        }
        i += 1
    }
    title = titleParts.isEmpty ? nil : titleParts.joined(separator: " ")

    guard let title, !title.isEmpty else {
        print("Usage: remind add <title> [--due <date>] [--list <name>] [--priority <1-9>] [--notes <text>]")
        print("  date formats: yyyy-MM-dd, yyyy-MM-dd HH:mm, +Nd, +Nh, +Nm")
        return
    }

    try await requestAccess()
    let cal = try findList(named: listName)

    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    reminder.calendar = cal
    reminder.priority = priority
    if let notes { reminder.notes = notes }
    if let dueStr {
        guard let comps = parseDate(dueStr) else {
            print("Error: could not parse date '\(dueStr)'")
            print("  formats: yyyy-MM-dd, yyyy-MM-dd HH:mm, +Nd, +Nh, +Nm")
            return
        }
        reminder.dueDateComponents = comps
        // Add an alarm at the due date
        if let date = Calendar.current.date(from: comps) {
            reminder.addAlarm(EKAlarm(absoluteDate: date))
        }
    }

    try store.save(reminder, commit: true)
    print("Created reminder:")
    printReminder(reminder)
}

func cmdList(_ args: [String]) async throws {
    var listName: String?
    var showCompleted = false

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--list", "-l":
            i += 1; listName = args[i]
        case "--all", "-a":
            showCompleted = true
        default: break
        }
        i += 1
    }

    try await requestAccess()
    let cal = try findList(named: listName)
    let predicate = store.predicateForReminders(in: [cal])

    let reminders = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[EKReminder], Error>) in
        store.fetchReminders(matching: predicate) { reminders in
            cont.resume(returning: reminders ?? [])
        }
    }

    let filtered = showCompleted ? reminders : reminders.filter { !$0.isCompleted }
    let sorted = filtered.sorted { a, b in
        let da = a.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
        let db = b.dueDateComponents.flatMap { Calendar.current.date(from: $0) } ?? Date.distantFuture
        return da < db
    }

    if sorted.isEmpty {
        print("No reminders found.")
        return
    }
    for r in sorted {
        printReminder(r)
    }
}

func cmdComplete(_ args: [String]) async throws {
    guard let identifier = args.first else {
        print("Usage: remind done <id>")
        return
    }

    try await requestAccess()
    guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
        throw RemindError.reminderNotFound(identifier)
    }
    item.isCompleted = true
    item.completionDate = Date()
    try store.save(item, commit: true)
    print("Completed:")
    printReminder(item)
}

func cmdDelete(_ args: [String]) async throws {
    guard let identifier = args.first else {
        print("Usage: remind delete <id>")
        return
    }

    try await requestAccess()
    guard let item = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
        throw RemindError.reminderNotFound(identifier)
    }
    let title = item.title ?? "(untitled)"
    try store.remove(item, commit: true)
    print("Deleted: \(title)")
}

func cmdLists() async throws {
    try await requestAccess()
    let calendars = store.calendars(for: .reminder)
    let def = store.defaultCalendarForNewReminders()
    for cal in calendars.sorted(by: { $0.title < $1.title }) {
        let marker = cal == def ? " (default)" : ""
        print("  \(cal.title)\(marker)")
    }
}

// MARK: - Main

func printUsage() {
    print("""
    remind - a CLI for Apple Reminders

    Usage:
      remind add <title> [--due <date>] [--list <name>] [--priority <1-9>] [--notes <text>]
      remind ls [--list <name>] [--all]
      remind done <id>
      remind delete <id>
      remind lists

    Date formats:
      yyyy-MM-dd          e.g. 2026-04-01
      yyyy-MM-dd HH:mm    e.g. 2026-04-01 09:00
      +Nd / +Nh / +Nm     e.g. +3d (3 days from now), +2h, +30m
    """)
}

let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first else {
    printUsage()
    exit(0)
}

do {
    let subArgs = Array(args.dropFirst())
    switch command {
    case "add":
        try await cmdAdd(subArgs)
    case "ls", "list":
        try await cmdList(subArgs)
    case "done", "complete":
        try await cmdComplete(subArgs)
    case "delete", "rm":
        try await cmdDelete(subArgs)
    case "lists":
        try await cmdLists()
    case "--help", "-h", "help":
        printUsage()
    default:
        print("Unknown command: \(command)")
        printUsage()
        exit(1)
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
