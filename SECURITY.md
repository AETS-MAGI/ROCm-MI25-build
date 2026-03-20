# Security Policy

## Supported scope

This repository contains scripts and documentation for lab validation.
It is not a production security product and does not provide guaranteed
hardening guidance.

## Reporting a vulnerability

If you find a security issue in this repository (for example a script
that can unintentionally expose credentials or execute unsafe commands):

1. Do not publish exploit details in a public issue first.
2. Report privately to repository maintainers.
3. Include reproduction steps, impact, and affected file paths.

## Handling secrets

- Do not commit API keys, tokens, passwords, or private certificates.
- Redact sensitive values in logs before sharing.
- Treat machine-specific identifiers as potentially sensitive evidence.

## Response expectations

Maintainers will triage reports and provide mitigation guidance or fixes
as soon as practical for active branches.
