# Contributing

Thanks for your interest in improving this project. It exists to help the Nutanix and observability communities, and contributions of all kinds are welcome.

## Ways to Contribute

- **Bug reports** — open an issue with reproduction steps, your environment, and what you expected vs what happened
- **Documentation improvements** — clarifications, additional examples, more troubleshooting recipes
- **Configuration patterns** — share working configs for use cases not yet covered (multi-region, large-scale, HA, etc.)
- **Integration recipes** — Prometheus/Grafana dashboards, alerting rules, anomaly detection pipelines
- **IPAM connectors** — Infoblox, NetBox, BlueCat, phpIPAM integration patterns
- **Scripts** — Ansible playbooks, Terraform modules, Kubernetes manifests

## Before Opening a Pull Request

1. **Open an issue first** to discuss substantial changes — saves time for everyone
2. **Test on a real deployment** when possible — this project is about working software
3. **Keep PRs focused** — one concern per PR makes review easier
4. **Update documentation** alongside code changes

## Style

- **Markdown:** Use ATX-style headers (`#`, `##`), fenced code blocks with language tags, line length not strictly enforced
- **YAML:** 2-space indentation, comments before blocks explaining what and why
- **Bash:** `set -e`, double-quote variables, parameterize configuration at the top of scripts
- **Tone:** technical, direct, helpful — assume the reader is a competent operator

## Code of Conduct

Be respectful. Assume good intent. The project is small and the community matters more than individual contributions. If a discussion becomes heated, take a break and come back.

## License

By contributing, you agree that your contributions are licensed under the Apache License 2.0 (see [`LICENSE`](LICENSE)).
