import Foundation
import AppKit

// MARK: - SAFE RUN (timeout + no freeze)
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
        return "❌ Timeout: \(cmd)"
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}

// MARK: - CHECK CHANGES (avoid heavy commit)
func hasChanges() -> Bool {
    let status = run("git status --porcelain")
    return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - FAST COMMIT
func gitCommitAndPush() -> String {
    guard hasChanges() else { return "No changes (skip commit)" }

    _ = run("git add .")
    _ = run("git commit -m 'auto: xcode agent'")

    var result = run("git push")

    if result.contains("no upstream branch") {
        result = run("git push --set-upstream origin main")
    }

    return result
}

// MARK: - AUTO REPO
func setupRepoIfNeeded() {
    let isGit = !run("git rev-parse --is-inside-work-tree 2>/dev/null").isEmpty

    if !isGit {
        _ = run("git init")
        _ = run("git add .")
        _ = run("git commit -m 'initial commit'")
        _ = run("git branch -M main")
    }
}

// MARK: - ALERT
func askCommit() -> Bool {
    let alert = NSAlert()
    alert.messageText = "Commit Changes?"
    alert.informativeText = "Commit & push before build?"
    alert.addButton(withTitle: "Yes")
    alert.addButton(withTitle: "No")
    return alert.runModal() == .alertFirstButtonReturn
}

// MARK: - AI REVIEW
func aiReview(_ diff: String) -> String {
    guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
        return "No API key"
    }

    let url = URL(string: "https://api.openai.com/v1/responses")!
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    req.addValue("application/json", forHTTPHeaderField: "Content-Type")

    let body: [String: Any] = [
        "model": "gpt-4.1-mini",
        "input": "Review this code diff and list issues:\n\(diff)"
    ]

    req.httpBody = try! JSONSerialization.data(withJSONObject: body)

    let sem = DispatchSemaphore(value: 0)
    var result = "AI failed"

    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data,
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let output = json["output"] as? [[String: Any]],
           let content = output.first?["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String {
            result = text
        }
        sem.signal()
    }.resume()

    sem.wait()
    return result
}

// MARK: - START FLOW

setupRepoIfNeeded()

var report: [String] = []

let isGitRepo = !run("git rev-parse --is-inside-work-tree 2>/dev/null").isEmpty

// COMMIT (optimized)
if isGitRepo && askCommit() {
    let git = gitCommitAndPush()
    report.append(git)
} else {
    report.append("Skipped commit")
}

// BUILD (timeout protected)
let build = run("xcodebuild build -scheme DemoAI", timeout: 120)
report.append(build.contains("** BUILD SUCCEEDED **") ? "Build OK" : "Build Failed")

// TEST
let test = run("xcodebuild test -scheme DemoAI -destination 'platform=iOS Simulator,name=iPhone 15'", timeout: 180)
report.append(test.contains("** TEST SUCCEEDED **") ? "Tests OK" : "Tests Failed")

// AI REVIEW
if isGitRepo {
    let diff = run("git diff HEAD~1")
    if !diff.isEmpty {
        report.append(aiReview(diff))
    }
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

    if let data = mail.data(using: .utf8) {
        pipe.fileHandleForWriting.write(data)
        pipe.fileHandleForWriting.closeFile()
    }
}
