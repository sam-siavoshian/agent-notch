# recipe_naming / browser-cmd-l-url

**Pattern.** Three observations of URL bar navigation in Arc:
`cmd+l → type <url> → return`. Varying field is the URL itself; structure is
constant.

**What we're testing.** Mercury must produce a generic "navigate to URL"
recipe — not three separate recipes for the three URLs. Acceptable verbs
include navigate / open / go / visit. The trigger_pattern should generalize
the URL ("<url>" placeholder) rather than enumerate the seen examples.
