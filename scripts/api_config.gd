extends RefCounted
## Address of the ranking API. Empty in the repository (development builds: the page's own
## origin, or ?api= for tests). tools/build_web.sh writes the production address here for the
## duration of a production export, then puts this file back.
## A production build (URL set) ignores the test-only page options (see main.gd _read_opts).

const URL := ""
