# Security policy

## Reporting a vulnerability

If you believe you've found a security issue in `flutter_uwb`, do not
open a public GitHub issue. Email the maintainer directly:

- **contact@ahmedhamdan.com**

Include:

- A description of the issue and the impact.
- Reproduction steps (or a minimal proof of concept).
- The plugin version, Flutter version, and platform versions you've
  tested against.

You'll receive an acknowledgement within seven days. If the issue is
confirmed, expect:

1. Confirmation of the vulnerability and an initial severity
   assessment.
2. A patch on a private branch.
3. Coordinated disclosure — a CVE if applicable, a release tagged
   with the fix, and a public advisory once a reasonable upgrade
   window has passed.

## Scope

What's in scope for a security report:

- The Dart, Kotlin, and Swift code shipped under this repository.
- The published `flutter_uwb` package on pub.dev.

What's out of scope:

- Bugs in `androidx.core.uwb`, `NearbyInteraction`, or any platform
  framework — please report those upstream.
- Issues in third-party UWB accessories.
- Vulnerabilities that require physical access to an unlocked device.

## Supported versions

Only the latest minor release receives security patches. Older minor
versions get a fix only if the issue is severe and the upgrade path
to the latest minor is blocked.
