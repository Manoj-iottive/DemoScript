import Foundation
import AppKit

// MARK: - APP INIT (required for popup via launchd)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// MARK: - SAFE RUN
func run(_ cmd: String, timeout: TimeInterval = 120) -> String {
    let p = Process()
    let pipe = Pipe()
    p.launchPath = "/bin/zsh"
    p.arguments = ["-c", cmd]
    p.standardOutput = pipe
    p.standardError = pipe
    try? p.run()

    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        p.waitUntilExit()
        group.leave()
    }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        return "❌ Timeout"
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - GIT
func hasChanges() -> Bool {
    !run("git status --porcelain").trimmingCharacters(in: .whitespaces).isEmpty
}

func commitPush(_ message: String) -> String {
    guard hasChanges() else { return "No changes" }
    _ = run("git add .")
    _ = run("git commit -m '\(message)'")
    var res = run("git push")
    if res.contains("no upstream") {
        res = run("git push -u origin main")
    }
    return res
}

// MARK: - POPUP (ALWAYS)
func askCommitMessage() -> String? {
    NSApp.activate(ignoringOtherApps: true)

    let alert = NSAlert()
    alert.messageText = "Scheduled CI Trigger"
    alert.informativeText = "Enter commit message"

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    alert.accessoryView = input

    alert.addButton(withTitle: "Commit & Run")
    alert.addButton(withTitle: "Skip")

    let res = alert.runModal()
    if res == .alertFirstButtonReturn {
        return input.stringValue.isEmpty ? "auto: update" : input.stringValue
    }
    return nil
}

// MARK: - AI
func getKey() -> String? {
    ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
}

func aiReview(_ diff: String) -> String {
    guard let key = getKey() else { return "No API key" }

    let url = URL(string: "https://api.openai.com/v1/responses")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "model": "gpt-4.1-mini",
        "input": "Review this code diff:\n\(diff)"
    ]

    req.httpBody = try! JSONSerialization.data(withJSONObject: body)

    let sem = DispatchSemaphore(value: 0)
    var result = "AI failed"

    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data {
            result = String(data: d, encoding: .utf8) ?? "parse error"
        }
        sem.signal()
    }.resume()

    sem.wait()
    return result
}

// MARK: - START FLOW

var report: [String] = []

let isGitRepo = !run("git rev-parse --is-inside-work-tree 2>/dev/null").isEmpty

// COMMIT (ALWAYS POPUP)
if isGitRepo {
    if let msg = askCommitMessage() {
        report.append(commitPush(msg))
    } else {
        report.append("Skipped commit")
    }
}

// BUILD
let build = run("xcodebuild build -scheme DemoAI", timeout: 120)
report.append(build.contains("SUCCEEDED") ? "Build OK" : "Build Failed")

// TEST
let test = run("xcodebuild test -scheme DemoAI -destination 'platform=iOS Simulator,name=iPhone 15'", timeout: 180)
report.append(test.contains("SUCCEEDED") ? "Tests OK" : "Tests Failed")

// AI
let diff = run("git diff HEAD~1")
if !diff.isEmpty {
    report.append(aiReview(diff))
}

// ALERT
let alert = NSAlert()
alert.messageText = "AI CI Report"
alert.informativeText = report.joined(separator: "\n\n")
alert.runModal()

// EMAIL
if let user = ProcessInfo.processInfo.environment["SMTP_USER"],
   let to = ProcessInfo.processInfo.environment["EMAIL_TO"] {

    let mail = """
From: \(user)
To: \(to)
Subject: AI CI Report

\(report.joined(separator: "\n\n"))
"""

    let p = Process()
    let pipe = Pipe()
    p.launchPath = "/usr/sbin/sendmail"
    p.arguments = ["-t"]
    p.standardInput = pipe
    try? p.run()

    pipe.fileHandleForWriting.write(mail.data(using: .utf8)!)
    pipe.fileHandleForWriting.closeFile()
}
