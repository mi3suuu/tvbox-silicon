p = "Sources/TVCore/DownloadTransfer.swift"
s = open(p, encoding="utf-8").read()

old = '''                    guard cursor.value >= range.upperBound else { throw TransferError.incomplete }
                } catch is CancellationError {
                    queue.finish(lane: lane)
                    throw CancellationError()
                } catch {
                    // `get` has already tried every mirror three times over by the time anything reaches
                    // here, so this is not a retry: it is the end of the line for this lane's range.
                    queue.finish(lane: lane)
                    throw error
                }
                // The connection ended early without an error (a proxy closing cleanly mid-body).
                // Ask once more from the cursor; each byte is still written exactly once, because the
                // range is re-requested from where it stopped rather than from its start.
                shortfalls += 1
                guard shortfalls <= 2, cursor.value < range.upperBound else {
                    queue.finish(lane: lane)
                    throw TransferError.incomplete
                }'''

new = '''                } catch is CancellationError {
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

assert s.count(old) == 1, s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("patched")
