import re, glob

KEYS = [
 ("Speed & Grouping", "Speed & Grouping"),
 ("Every Source", "Every Source"),
 ("One Group", "One Group"),
 ("Measure", "Measure"),
 ("Group", "Group"),
 ("Skip readings newer than", "Skip readings newer than"),
 ("Never skip", "Never skip"),
 ("5 minutes", "5 minutes"),
 ("10 minutes", "10 minutes"),
 ("30 minutes", "30 minutes"),
 ("1 hour", "1 hour"),
 ("A source measured inside this window is left alone, so a second sweep costs only what changed. Set it to Never skip to re-measure everything.",
  "A source measured inside this window is left alone, so a second sweep costs only what changed. Set it to Never skip to re-measure everything."),
 ("Scope", "Scope"),
 ("Sweep", "Sweep"),
 ("%lld of %lld measured", "%1$lld of %2$lld measured"),
 ("%lld skipped: measured recently.", "%lld skipped: measured recently."),
 ("Measure This Group", "Measure This Group"),
 ("Measure Every Source", "Measure Every Source"),
 ("%lld sources will be measured.", "%lld sources will be measured."),
 ("%lld to measure, %lld skipped as recent.", "%1$lld to measure, %2$lld skipped as recent."),
 ("Nothing to measure here.", "Nothing to measure here."),
 ("Readings", "Readings"),
 ("Sources", "Sources"),
 ("Answered", "Answered"),
 ("Silent", "Silent"),
 ("Not measured", "Not measured"),
 ("Newest reading", "Newest reading"),
 ("Grouping", "Grouping"),
 ("New group from everything that answered", "New group from everything that answered"),
 ("New group from everything silent", "New group from everything silent"),
 ("Answered into %@", "Answered into %@"),
 ("Silent into %@", "Silent into %@"),
 ("Move a batch into an existing group", "Move a batch into an existing group"),
 ("New group", "New group"),
 ("%lld filed into %@.", "%1$lld filed into %2$@."),
 ("%lld moved into %@.", "%1$lld moved into %2$@."),
 ("Created %@.", "Created %@."),
 ("A source with no reading is left where it is. Filing an unmeasured source is a guess, and a working source hidden in the wrong group is worse than one that is slow.",
  "A source with no reading is left where it is. Filing an unmeasured source is a guess, and a working source hidden in the wrong group is worse than one that is slow."),
 ("Routing", "Routing"),
 ("Answered to Direct, Silent to Proxy", "Answered to Direct, Silent to Proxy"),
 ("%lld to Direct, %lld to Proxy, %lld left unmeasured.", "%1$lld to Direct, %2$lld to Proxy, %3$lld left unmeasured."),
 ("A route changes the address a source API is fetched from. Media comes from whatever CDN the source hands back and is not rewritten, so a source whose API answers but whose segments are blocked still needs hiding.",
  "A route changes the address a source API is fetched from. Media comes from whatever CDN the source hands back and is not rewritten, so a source whose API answers but whose segments are blocked still needs hiding."),
 ("Forget Every Reading", "Forget Every Reading"),
 ("Unreachable", "Unreachable"),
 ("Group %lld", "Group %lld"),
]

for path in glob.glob("Sources/TVCore/Resources/en.lproj/Localizable.strings"):
    text = open(path, encoding="utf-8").read()
    added = 0
    block = []
    for key, value in KEYS:
        if ('"' + key + '"') in text:
            continue
        block.append('"%s" = "%s";' % (key.replace('"', '\\"'), value.replace('"', '\\"')))
        added += 1
    if block:
        text = text.rstrip() + "\n\n/* Speed & Grouping (SourceSpeedLab) */\n" + "\n".join(block) + "\n"
        open(path, "w", encoding="utf-8").write(text)
    print(path, "added", added)
