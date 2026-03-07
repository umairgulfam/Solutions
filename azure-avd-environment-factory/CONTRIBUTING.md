# Contributing

1. Create a feature branch.
2. Run `terraform fmt -recursive`.
3. Run `make validate lint security`.
4. Update an example and documentation for interface changes.
5. Open a pull request and attach the sanitized plan summary.

Never commit credentials, Terraform state, plan files, or organization data.

