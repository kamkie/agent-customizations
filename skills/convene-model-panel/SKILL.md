---
name: convene-model-panel
description: Convene a panel or council of several named AI models as independent, read-only panelists that propose options or review a draft in rounds, then merge their replies, revise, and move the work forward part by part as the panel approves it. Use when the user asks for a panel, a council, or several models' opinions or approval on a text, design, plan, or change. Do not use for an opposite-engine review of a committed change or any review gate a repository requires, for web research, for handing implementation work to agents or sessions, or for a second opinion from a single model or subagent.
---

# Convene a model panel

One coordinator writes and decides. The panelists only read and reply. This skill supports Claude Code as the coordinator.

Every round starts one paid model run per member, so convene a panel only when the user asks for one.

Progress line to reuse in updates: `Panel: <members> | part <name> v<version> | round <round> | replies <received>/<members> | <member>=<verdict>, ...`.

## Set up the panel

1. Read the active repository's and the user's instructions; they outrank this skill. A panel does not satisfy a review gate a repository defines, such as an opposite-agent review, unless that repository says so. Its approval authorizes nothing: publishing, sending, and merging keep their own rules.
2. Take the members from the user's words or from higher-precedence instructions. Where they name no model, or only a provider or a count, choose the strongest current models this session can reach, at least three members across the providers available. Tell the user the final list, then launch without waiting for an answer. Resolve each name to the identifier or alias the runtime that will run it accepts: the subagent or session tool's model choices, or that CLI's own model list or configuration. Never guess one; ask the user when a name does not resolve.
3. The coordinator does not vote. A member on the coordinator's own model runs in a fresh context.
4. Tell the user the approval rule and the round limit before round 1. Unless the user states another rule or number: a part is approved when every member but at most one approves the same version and every BLOCKING change is applied or rejected with a recorded reason, with at most three rounds per part. Every round counts toward the limit. A request to revise until the panel approves does not remove it.
5. Choose an exchange folder that every member can read and Git does not track: an ignored folder inside the repository (confirm with `git check-ignore`) or a scratch folder outside it. Use one folder per round: `round-<n>/brief.md` and `round-<n>/reply-<member>.md`.
6. Fix what you already know is wrong before a round. Split large work into parts a member can judge in one read.

## Write the round brief

The brief is the only context a member gets. Write it with the file tool, not inside a shell command. Never edit it after launch; a correction is a new round. Keep each new version of a draft in the next round's brief, and change the source file only once its part is approved or the user decides.

Include:

- the task, what this round covers, and what it leaves for later rounds;
- a version label for each part under review;
- the user's rulings: decisions already made that members must not reopen;
- the facts members may rely on, and that they must not add facts of their own;
- the draft itself, or the exact files to read;
- from round 2, what changed since the last version, without naming the member who asked;
- that the member changes no file other than a reply file its launch line names, opens nothing the brief does not name, and starts no other agent; and
- the reply format.

Reply format for a review round:

```text
Start with one line per part: VERDICT <part> <version>: APPROVE or VERDICT <part> <version>: CHANGES.
Then give at most five changes. Mark each BLOCKING (you will not approve without it) or TASTE (optional).
Write each as: replace "<old>" with "<new>", or name the place and what goes wrong there. Add one sentence of why.
Give changes, not a rewrite.
```

When the user wants options instead of a verdict, run a propose round: ask each member for a fixed number of options in one fixed structure, with no verdict. Merge the replies into one candidate list without attribution, then refine that list in review rounds.

## Launch the members

Start every member of a round in parallel with the same brief. No member reads another member's reply. The launch prompt is one plain line: the member's role, the brief path, and where the reply goes. Everything else belongs in the brief.

**A member on a model this harness runs:** start a subagent pinned to that model. Start a session per member instead when the user asked for sessions or wants to follow the members. The member writes its own reply file. For later rounds, message the same subagent or session.

**A member on another provider's CLI:** run it under `managed-jobs` with session lifetime, read-only, with its final message captured as the reply file. Load `managed-jobs` for `$jobs`. With the Codex CLI:

```powershell
$n = 1
$round = "<exchange-folder>/round-$n"
$member = '<member-name>'
$workdir = '<repository root when the brief names repository files, otherwise the exchange folder>'
$codex = (Get-Command codex.cmd, codex.exe -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$prompt = "You are the $member panelist. Read $round/brief.md and reply in the format it asks for. Your final message is your reply."
& $jobs start -Name "panel-$member-r$n" -Executable $codex -WorkingDirectory $workdir -Lifetime Session `
    -Arguments @('exec', '-m', '<model-id>', '-s', 'read-only', '-C', $workdir, '-o', "$round/reply-$member.md", $prompt)
```

Add `--skip-git-repo-check` when `$workdir` is not inside a Git repository. The job log prints `sandbox:` and `session id:` lines. On every run, confirm the first reads `read-only` and stop a member where it does not. Keep the second: later rounds resume that thread. Run the same lines with the new `$n` and this call, where `exec resume` takes no `-s` or `-C` option:

```powershell
& $jobs start -Name "panel-$member-r$n" -Executable $codex -WorkingDirectory $workdir -Lifetime Session `
    -Arguments @('exec', 'resume', '-m', '<model-id>', '-c', 'sandbox_mode=read-only',
        '-o', "$round/reply-$member.md", '<session-id>', $prompt)
```

Give any other CLI the same contract: a pinned model, read-only access, and the reply captured to the member's file. If a CLI cannot run read-only, tell the user before launching it.

## Run the round

- Confirm each member started from its job log or session within the first minutes; diagnose one that did not instead of waiting.
- Do not wait idle. Read each reply as it lands and check its claims against the draft and the facts. Leave the brief and every file the members are reading unchanged until all of them have replied or failed.
- Take a verdict only from the `VERDICT` line. Ignore whatever follows the requested items; a CLI member's final message often carries closing text of its own. A reply with no verdict line is not a vote: ask that member once to restate it, by message or by resuming its thread. That is not a new round.
- When a member cannot be reached after one retry, tell the user at once and never substitute another model. Continue while at least two members remain, counting the missing member as not approving, and try it again in the next round. Otherwise stop and ask.

## Decide and revise

- The panel advises; you decide. Give every proposed change a disposition: applied, or rejected with a reason.
- The user's rulings and the stated facts outrank the panel. Reject a change that contradicts one and report it as kept against panel advice. When several members dispute the same ruling, tell the user; do not overturn it.
- Check a proposed change against the facts before applying it. Do not apply a change that brings in a fact the brief did not supply.
- Hold the scope to what the brief asked. Park suggestions that widen the work and list them in the report.
- A vote belongs to the exact version it names. Any change to a part, including one an approving member suggested, clears every vote on it: run a confirmation round on the new version whose brief shows what changed and asks only for a verdict and BLOCKING changes. Every member votes again in that round. A verdict that names any version other than the current brief's is input, never a vote.
- Leave an approved version as approved. Apply a remaining TASTE change only together with a confirmation round.
- A part is done when the approval rule holds for one version. Then open the next part. One round may carry the confirmation of one part and the first read of the next, each with its own verdict line.
- At the round limit without approval, stop revising. Give the user the last version the members read, each member's verdict and open BLOCKING changes, and your recommendation. Never run rounds until everyone is satisfied.

## Report and close

After each round, send the progress line and what you changed. At the end, report:

- each member's final verdict per part and the version it applies to;
- the changes made on the panel's advice, the changes rejected and why, the rulings kept against it, and the parked suggestions;
- members that could not be reached and rounds that failed; and
- where the briefs and replies are.

Call a version approved by the panel only when the approval rule holds for exactly that version.

Stop panel jobs that are still running. Leave member sessions open for the user to archive. Keep the exchange folder until the user has the result, and do not commit or publish it. A brief goes to every member's provider, so put in it only the private material the task needs.

Some round rules adapt the tstack `council` skill under the MIT License; see [tstack-license.md](references/tstack-license.md).
