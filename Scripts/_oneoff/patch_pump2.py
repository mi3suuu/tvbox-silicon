p = "Sources/TVCore/DownloadTransfer.swift"
s = open(p, encoding="utf-8").read()

old = '''                } catch is CancellationError {
                    queue.finish(lane: lane)
                    throw CancellationError()
                } catch {
                    // \`get\` has already walked every mirror three times over by the time anything reaches
                    // here, so this is not a retry: it is the end of the line for this lane's range.
                    queue.finish(lane: lane)
                    throw error
                }
                // A connection can end cleanly without delivering the whole range (a proxy closing
                // mid-body, a mirror that truncates). That is not an error \`get\` can see — it finishes
                // when the connection finishes — so the lane checks it and asks again from where it
                // stopped. Each byte is still written exactly once, because the request starts at the
                // cursor rather than at the range's beginning.
                if cursor.value < range.upperBound {
                    shortfalls += 1
                    guard shortfalls <= 2 else {
                        queue.finish(lane: lane)
                        throw TransferError.incomplete
                    }
                }'''

new = '''                } catch is CancellationError {
                    queue.finish(lane: lane)
                    throw CancellationError()
                } catch {
                    // The lane retries too, and it must: \`get\` gives a mirror three attempts, so a server
                    // that answers 503 four times straight is already past its budget by the time the
                    // error surfaces here. Dropping this loop made exactly that case fail — measured, a
                    // five-503 server went from "recovers in 12 s" to "always fails". What it does not do
                    // is retry blindly: the budget is small and the wait grows, so the common case (\`get\`
                    // handled it) never reaches this line.
                    guard Self.worthRetrying(error), attempt < 2, cursor.value < range.upperBound else {
                        queue.finish(lane: lane)
                        throw error
                    }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(800 * attempt))
                    continue
                }
                // A connection can end cleanly without delivering the whole range (a proxy closing
                // mid-body, a mirror that truncates). \`get\` cannot see that — it finishes when the
                // connection finishes — so the lane checks and asks again from where it stopped. Each
                // byte is still written exactly once, because the request starts at the cursor.
                if cursor.value < range.upperBound {
                    shortfalls += 1
                    guard shortfalls <= 2 else {
                        queue.finish(lane: lane)
                        throw TransferError.incomplete
                    }
                }'''

assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)

# 恢复 attempt 计数器（上一版被删掉了）
old2 = '''            var shortfalls = 0
            while cursor.value < range.upperBound {'''
new2 = '''            var shortfalls = 0
            var attempt = 0
            while cursor.value < range.upperBound {'''
assert s.count(old2) == 1, s.count(old2)
s = s.replace(old2, new2)

open(p, "w", encoding="utf-8").write(s)
print("patched")
