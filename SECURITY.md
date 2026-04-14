# Security Policy

## Reporting a Vulnerability

If you believe that you have identified a security vulnerability in Core-Monitor CLI, please report it privately.

To help protect users, please do not disclose security issues publicly, including through public GitHub issues, discussions, pull requests, or social media, before the issue has been investigated and, if necessary, addressed.

Security reports should be submitted through a private contact method maintained by the repository owner, such as:

- a designated security contact address, if provided by the repository
- GitHub private reporting features, if enabled
- another private contact channel explicitly listed by the project

## What to Include

Please include enough information for the issue to be investigated and reproduced.

A complete report should include, where possible:

- the affected version, commit, or build
- a clear technical description of the issue
- the behavior observed and the behavior expected
- the steps required to reproduce the issue
- a proof of concept, sample input, logs, screenshots, or other supporting material
- an explanation of the potential security impact

Reports that are complete and actionable can generally be investigated more quickly.

## What to Expect

All reports submitted directly through a private reporting channel will be reviewed.

After a report is received:

- an acknowledgement may be provided
- the report will be evaluated for validity, severity, and reproducibility
- additional information may be requested if needed to continue the investigation
- a fix, mitigation, or other appropriate response may be prepared if the issue is confirmed

Resolution time may vary depending on the complexity and impact of the issue.

## Disclosure

For the protection of users, Core-Monitor CLI does not publicly disclose, discuss, or confirm security issues until the investigation has been completed and any necessary fix or mitigation is available.

Coordinated disclosure is appreciated.

## Scope

This policy applies to vulnerabilities in the officially maintained Core-Monitor CLI codebase and release artifacts.

The following are generally outside the scope of this policy:

- unsupported forks or unofficial builds
- issues introduced solely by local modifications
- development environment misconfiguration
- third-party dependencies or external tools, except where the project’s own integration introduces a distinct security issue
- non-security bugs, feature requests, or usability issues

## Supported Versions

Security fixes are provided for the latest released version of Core-Monitor CLI.

Users should run the most recent available release to receive the latest security improvements.

| Version | Supported |
| ------- | --------- |
| Latest release | Yes |
| Earlier releases | No |

## Security Notes

Core-Monitor CLI may interact with privileged or system-level functionality, depending on how it is configured and used.

Users should:

- install software only from trusted sources
- review any request for elevated privileges carefully
- treat custom scripts, presets, and local modifications as untrusted unless they have been reviewed
- avoid granting unnecessary permissions

## Acknowledgement

Responsible reports that help improve the security of Core-Monitor CLI are appreciated.
