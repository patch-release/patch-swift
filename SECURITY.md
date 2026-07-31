# Security Policy

## Reporting a vulnerability

**Please do not open a public GitHub issue, pull request, or discussion for a
security vulnerability.** A public report exposes the issue to everyone running
Patch before a fix is available.

Report it privately to **security@patchrelease.com**.

If you would like to encrypt your report, say so in a first message with no
details and we will reply with a key.

### What to include

The more of this you can provide, the faster we can confirm and fix it:

* A description of the issue and why you believe it is a security problem.
* The affected component and version — SDK (`sdk/`), engine/CLI (`cli/`), or the
  update protocol — plus `patchcli --version` and the PatchSDK version if
  relevant.
* Steps to reproduce, ideally a minimal proof of concept.
* The impact you think it has, and any conditions required to trigger it
  (specific configuration, self-hosted vs. hosted, network position).

### What to expect

* **Acknowledgement within 3 working days** that we received your report.
* An initial assessment, and whether we consider it a vulnerability, within
  10 working days.
* Regular updates while we work on a fix.
* Credit in the release notes when the fix ships, unless you prefer to remain
  anonymous — tell us which you want.

We ask that you give us a reasonable opportunity to release a fix before
disclosing publicly. If you have a disclosure deadline, tell us up front and we
will work to it or explain why we cannot.

## Scope

Because Patch delivers code to devices over the air, we are particularly
interested in reports concerning:

* The **update protocol** — module authenticity, integrity and confidentiality
  in transit or at rest; anything that lets a party deliver, alter, suppress or
  read a patch it should not be able to.
* The **on-device runtime** — sandbox escape from a WebAssembly guest, memory
  safety in the host bridges, or a guest reaching host capability it was not
  granted.
* The **engine's safety guarantees** — in particular any way to make the
  fingerprint accept a change to native code that it should reject, since that
  gate is what keeps an OTA patch from silently diverging from the signed app.
* Credential handling — app keys, CLI tokens, and anything that leaks them.

Out of scope: findings against third-party dependencies that are already public
and unfixed upstream (report those upstream, and tell us so we can track them);
reports produced solely by an automated scanner with no demonstrated impact; and
issues requiring physical access to an unlocked device or a compromised
developer machine.

## Safe harbour

We will not pursue or support legal action against anyone who makes a good-faith
effort to comply with this policy while researching and reporting a
vulnerability. Good faith means: only testing against systems and accounts you
own or have permission to test, avoiding privacy violations and service
degradation, and not accessing or retaining more data than is needed to
demonstrate the issue.

## Supported versions

Security fixes land on the latest released version of each package. We do not
backport to older releases; please upgrade to receive them.
