#!/bin/zsh
# Reproduces the performance figures in README.md. Run after scripts/build-app.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/PS.app
BIN=$APP/Contents/MacOS/PS
WORK=$(mktemp -d)

echo "Bundle size: $(du -sh $APP | cut -f1)"
lipo -info $BIN

echo "\nLaunch to first frame + idle memory (5 runs):"
for i in 1 2 3 4 5; do "$BIN" --measure 2>/dev/null; done

# A 10,000-line Swift file and a >5 MB JavaScript file.
python3 - "$WORK" <<'PY'
import sys, os
work = sys.argv[1]
swift = '''import Foundation

/// A tiny greeter.
struct Greeter {
    let name: String
    func greet() -> String {
        // Repeat the greeting
        (0..<3).map { "Hello, \\(name)! #\\($0)" }.joined(separator: "\\n")
    }
}
'''.splitlines()
with open(os.path.join(work, "big10k.swift"), "w") as f:
    f.write("\n".join(swift[i % len(swift)] for i in range(10000)) + "\n")
line = 'function f%d(a, b) { /* sum */ return a + b * %d; } // line %d\nconst s%d = "string value %d";\n'
with open(os.path.join(work, "big5mb.js"), "w") as f:
    n = size = 0
    while size < 5 * 1024 * 1024 + 1000:
        chunk = line % (n, n, n, n, n); f.write(chunk); size += len(chunk); n += 1
PY
head -c 4700000 "$WORK/big5mb.js" > "$WORK/big45.js"

echo "\nLarge files (open, main-thread stalls, typing, scrolling):"
for f in big10k.swift big45.js big5mb.js; do "$BIN" --bench "$WORK/$f" 2>/dev/null; done
rm -rf "$WORK"
