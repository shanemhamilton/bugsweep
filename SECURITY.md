# Security policy

bugsweep is a developer tool that reads source code and runs shell and git commands
locally on the user's machine. It is designed to be safe to run unattended, but it is
still software that executes commands — treat it accordingly.

## What bugsweep does and does not do

By design, bugsweep:
- works only on a throwaway `bugsweep/<timestamp>` branch and never commits to the user's
  original branch;
- never pushes, pulls, merges, force-pushes, or rewrites history;
- never deletes files or directories and never runs destructive resets on user content;
- stashes and restores the user's uncommitted work;
- re-runs the project's checks after each fix and auto-reverts any fix that regresses them.

These guarantees are enforced by the scripts in `scripts/`, not by model judgment. Read
them before running on code you care about. The model layer affects detection quality and
fix correctness, not the irreversible safety boundary — keep a human review at merge time.

## Reporting a vulnerability

If you find a security issue in bugsweep itself (for example, a path by which it could
push, delete, escape the throwaway branch, exfiltrate data, or execute unintended
commands), please report it privately rather than opening a public issue:

- Use GitHub's **"Report a vulnerability"** (Security advisories) on this repository, or
- contact the maintainer directly.

Please include the version/commit, your OS and shell, and reproduction steps. We aim to
acknowledge reports promptly and will credit reporters who wish to be named once a fix is
released.

## Scope

In scope: any defect in bugsweep that breaks one of the safety guarantees above. Out of
scope: bugs in the user's own codebase that bugsweep does or doesn't find (that's the
tool's job, not a vulnerability in the tool), and issues requiring the user to have
already configured an obviously unsafe override.
