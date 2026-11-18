import AppKit
import Darwin

/// Measurement harness behind command-line flags (see scripts/measure.sh):
///   --measure            launch time to first frame + idle memory, then quit
///   --bench <file>       open time, main-thread stalls, typing and scrolling cost, then quit
enum Bench {
    static let arguments = CommandLine.arguments
    static var isActive: Bool { arguments.contains("--measure") || arguments.contains("--bench") }

    static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        sysctl(&mib, 4, &info, &size, nil, 0)
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    /// Same number Activity Monitor shows as "Memory".
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func emit(_ values: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
            fflush(stdout)
        }
    }

    static func run(_ controller: MainWindowController) {
        if arguments.contains("--measure") {
            measureLaunch(controller)
        } else if let index = arguments.firstIndex(of: "--bench"), index + 1 < arguments.count {
            // PS_BENCH_DELAY lets a profiler attach before the file is opened.
            let delay = Double(ProcessInfo.processInfo.environment["PS_BENCH_DELAY"] ?? "") ?? 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                bench(controller, file: URL(fileURLWithPath: arguments[index + 1]))
            }
        }
    }

    private static func measureLaunch(_ controller: MainWindowController) {
        // The window is ordered front; wait for the first frame to be drawn.
        DispatchQueue.main.async {
            controller.window?.displayIfNeeded()
            let launch = Date().timeIntervalSince(processStart())
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                emit(["launch_to_window_ms": Int(launch * 1000), "idle_footprint_mb": (footprintMB() * 10).rounded() / 10])
                exit(0)
            }
        }
    }

    private static func bench(_ controller: MainWindowController, file: URL) {
        var maxGap: TimeInterval = 0
        var last = Date()
        let probe = Timer(timeInterval: 0.005, repeats: true) { _ in
            let now = Date()
            maxGap = max(maxGap, now.timeIntervalSince(last))
            last = now
        }
        RunLoop.main.add(probe, forMode: .common)
        let start = Date()

        controller.open(file) { tab in
            guard let tab, let view = tab.editor?.textView else {
                emit(["error": "open failed"])
                exit(1)
            }
            view.window?.displayIfNeeded()
            let opened = Date().timeIntervalSince(start)

            // Let any background highlighting land, measuring stalls meanwhile.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                probe.invalidate()
                let stall = maxGap
                let typing = measureTyping(view)
                let scrolling = measureScrolling(view)
                emit([
                    "file": file.lastPathComponent,
                    "bytes": (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0,
                    "lines": tab.document.lineIndex.lineCount,
                    "open_to_visible_ms": Int(opened * 1000),
                    "max_main_thread_stall_ms": Int(stall * 1000),
                    "typing_avg_ms": typing.average,
                    "typing_p95_ms": typing.p95,
                    "scroll_frame_avg_ms": scrolling,
                    "footprint_mb": (footprintMB() * 10).rounded() / 10,
                    "highlighting": !tab.document.highlightingDisabled,
                ])
                exit(0)
            }
        }
    }

    /// Each keystroke: insert, let the incremental highlighter run, redraw.
    private static func measureTyping(_ view: NSTextView) -> (average: Double, p95: Double) {
        let middle = (view.string as NSString).length / 2
        view.setSelectedRange(NSRange(location: middle, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        view.window?.displayIfNeeded()
        var samples: [Double] = []
        for index in 0..<200 {
            let begin = CFAbsoluteTimeGetCurrent()
            view.insertText(index % 20 == 19 ? "\n" : "x", replacementRange: view.selectedRange())
            RunLoop.main.run(mode: .default, before: Date())
            view.window?.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - begin) * 1000)
        }
        samples.sort()
        let average = samples.reduce(0, +) / Double(samples.count)
        return ((average * 100).rounded() / 100, (samples[Int(Double(samples.count) * 0.95)] * 100).rounded() / 100)
    }

    private static func measureScrolling(_ view: NSTextView) -> Double {
        guard let clip = view.enclosingScrollView?.contentView else { return -1 }
        clip.scroll(to: .zero)
        var total = 0.0
        let frames = 120
        for _ in 0..<frames {
            let begin = CFAbsoluteTimeGetCurrent()
            var origin = clip.bounds.origin
            origin.y += clip.bounds.height * 0.5
            clip.scroll(to: origin)
            view.enclosingScrollView?.reflectScrolledClipView(clip)
            view.window?.displayIfNeeded()
            total += (CFAbsoluteTimeGetCurrent() - begin) * 1000
        }
        return (total / Double(frames) * 100).rounded() / 100
    }
}
