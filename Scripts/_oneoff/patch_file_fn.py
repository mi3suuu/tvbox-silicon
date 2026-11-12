p = "App/SourceSpeedLab.swift"
s = open(p, encoding="utf-8").read()

old = '''    private func file(_ sites: [Site], named name: String) {
        guard !sites.isEmpty else { return }
        guard let group = store.createSourceGroup(named: name) else { return }
        let moved = store.fileSources(sites, intoGroup: group.id)
        note = L10n.text("%lld filed into %@.", moved, group.name)
        revision += 1
    }'''

new = '''    /// Files `sites` into a group of that name.
    ///
    /// `add(name:)` hands back the existing group when the name is taken, which is right for a name the
    /// viewer typed and wrong here: pressing "new group from everything that answered" a second time
    /// after another sweep would silently merge the second batch into the first group, and the note
    /// would say "12 filed into Answered" while the group now holds 24. A numbered suffix makes each
    /// press its own batch without asking the viewer to name it.
    private func file(_ sites: [Site], named name: String) {
        guard !sites.isEmpty else { return }
        let taken = Set(store.sourceGroupBook.groups.map(\.name))
        var candidate = name, n = 2
        while taken.contains(candidate) {
            candidate = name + " " + String(n)
            n += 1
        }
        guard let group = store.createSourceGroup(named: candidate) else { return }
        let moved = store.fileSources(sites, intoGroup: group.id)
        note = L10n.text("%lld filed into %@.", moved, group.name)
        revision += 1
    }'''

assert s.count(old) == 1, s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
print("patched")
