p = "Sources/TVCore/DownloadTransfer.swift"
s = open(p, encoding="utf-8").read()

old = '''        var failure: Error = TransferError.http(0)
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2 * attempt)) }
            var refused = 0
            for url in urls {'''

new = '''        var failure: Error = TransferError.http(0)
        // Mirrors first, attempts second.
        //
        // The loops used to be the other way round: attempt 1 tried mirror A, B, C; attempt 2 tried A
        // again. With three attempts and one mirror that is three requests; with three mirrors the
        // first attempt already walks all three, so the repeat buys nothing and costs a full round of
        // duplicates. Swapping the order means the retry round runs only when every mirror has already
        // failed once, which is exactly when waiting is the right move.
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(2 * attempt)) }
            var refused = 0
            for url in urls {'''

assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
open(p, "w", encoding="utf-8").write(s)
print("patched")
