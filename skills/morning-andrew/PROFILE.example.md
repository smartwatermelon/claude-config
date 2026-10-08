# Daily brief profile (example)

`morning-andrew` and `evening-andrew` share one private profile. It holds the facts
about one person's job that do not belong in this public repo: title, reporting line,
colleague names, chat member IDs, private trackers.

## Where the profile lives

The skills read the first file that exists, in this order, and only that file:

1. `$DAILY_BRIEF_PROFILE`, when the variable is set. If it does not name a readable
   file, the skill stops with an error rather than falling back.
2. `~/.config/daily-brief/PROFILE.md`.

Neither path is inside this repo. `skills/**/PROFILE.md` is also gitignored, so a
copy saved next to this file by mistake is not committed.

## Setup

```bash
mkdir -p ~/.config/daily-brief
cp ~/Developer/claude-config/skills/morning-andrew/PROFILE.example.md ~/.config/daily-brief/PROFILE.md
chmod 600 ~/.config/daily-brief/PROFILE.md
```

Then replace every placeholder below. Delete this "Where" and "Setup" text if you like;
the skills read only the field list.

## Fields

- **Name**: Jane Example
- **Employer**: Example Corp
- **Title**: Site Reliability Engineer
- **Timezone**: Pacific (America/Los_Angeles)
- **Hours**: 9am–5pm PT, Monday–Friday
- **Huddle**: daily Slack huddle at 9am PT
- **GitHub org**: `example-org`
- **GitHub work account**: `jane-example`
- **Slack member ID**: `U00000000`
- **Issue tracker**: `jane-example/work-notes`
- **Manager**: Sam Placeholder
- **Active workstream**: one line on the current main project
