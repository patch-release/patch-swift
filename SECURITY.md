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

* Module *integrity* (SHA-256 verification of downloaded modules).
  Note: modules are **not** code-signed today — integrity is verified
  against a hash delivered by the same response as the module URL, so it
  proves transport integrity, not authorship. Asymmetric module signing is
  not yet implemented; reports about that gap are welcome but it is a known
  limitation rather than a vulnerability.
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

## Known limitations

The item below is an architectural gap rather than a bug. It is stated here so
nobody has to discover it by reading source, and so a report about it isn't
mistaken for a novel finding.

### The app key is no longer a publish credential (fixed)

This section previously documented a serious flaw: `app_key` (`pak_…`) is baked
into your app by `patchcli init`, so it ships in every IPA and is recoverable
with `strings` — and it was *also* accepted as the CLI's `X-API-Key`. Anyone who
downloaded a published app could push arbitrary WebAssembly to every user of it.

**This is fixed.** The two roles are now separate credentials:

* **`app_key` (`pak_…`)** — a *public* app identifier. It rides the body of the
  unauthenticated device endpoints (`POST /modules/check`, `POST /events`) and
  authorizes nothing. It is rejected as `X-API-Key`.
* **`publish_token` (`ppt_…`)** — the write credential. Never enters your app;
  created by `patchcli login` or the dashboard; scoped to a workspace and
  optionally pinned to one app; revocable; stored server-side as a SHA-256
  digest only.

**If you used Patch before this change:** your `app_key` needs no rotation — it
is now correctly public. Run `patchcli login` once per project to get a publish
token. If your app key was ever used as a *publish* credential in a place it
could have leaked, audit your release history for pushes you didn't make.

### Modules are not code-signed

A downloaded module is verified by SHA-256 against a hash delivered in the *same
response* as the module URL. That proves the bytes arrived intact; it does not
prove who produced them. There is no asymmetric signature and no developer-held
key, so the update channel is only as trustworthy as the control plane serving
it. Notably, webhook payloads *are* HMAC-signed — the low-stakes channel is
authenticated and the code-execution channel is not.

If you self-host, this is on you: anything that can answer the check endpoint can
execute code in your users' apps.
