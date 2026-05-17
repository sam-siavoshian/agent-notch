# recipe_naming / slack-cmd-k-dm

**Pattern.** Three observations of the user opening a DM in Slack via the
quick-switcher: `cmd+k → type <person> → return`. The varying field is just
the person's name; the structure is identical.

**What we're testing.** Mercury must recognize the abstraction (open DM with
person), name it with a verb-phrase a user would naturally say, and produce
a `trigger_pattern` covering the common phrasings ("DM <person>",
"message <person>", "open DM").

Case-insensitive match on both `name` and `trigger_pattern` — any of the
listed strings is acceptable as long as the recipe is recognizable.
