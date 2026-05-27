# Security policy

## Audit status

> **Warning: these contracts have not been independently audited.** Use at your own risk. Production deployments should commission an audit before handling significant value or governance authority.

## Supported versions

Only the current `main` branch is supported. There are no tagged releases yet; once the code is audited and tagged, this section will list supported release lines.

## Reporting a vulnerability

Please report security issues privately:

- Email: **contact@blockful.io**
- Subject line: `[security] ranked-choice-voting: <short summary>`

Do **not** open a public GitHub issue or PR for security-sensitive reports.

Include in your report:
- A clear description of the issue and its impact.
- Steps to reproduce, ideally as a Foundry test case.
- The commit hash you observed it on.
- Any suggested mitigations, if you have them.

## Disclosure timeline

We aim to acknowledge new reports within 3 business days and to ship a fix or mitigation within 90 days of receipt. We'll coordinate public disclosure with the reporter; the default is 90-day responsible disclosure unless the issue is being actively exploited, in which case we may accelerate.

## Scope

In scope: any contract under `src/`, including the libraries in `src/libraries/`.

Out of scope: tests, deploy scripts, OS / toolchain issues, and anything in `lib/` (those are upstream dependencies — please report directly to the upstream maintainers).
