# indieprise-github-actions

GitHub Actions composite action for Indieprise — scans repos for migration opportunities and executes migrations with PR output.

## What it does

- Downloads `migrataur` and `prexplainer` binaries from GitHub Releases (cached between runs)
- Installs Ollama and pulls the configured model (cached between runs)
- Installs and configures Pi with Ollama as the model provider
- Pulls migration patterns from the Indieprise runtime
- Runs `migrataur` in `scan` or `migrate` mode

## Usage

### Scan mode (runs on cron)

```yaml
name: Indieprise Scan
on:
  schedule:
    - cron: '0 3 * * 1'   # every Monday at 03:00 UTC
  workflow_dispatch:

jobs:
  scan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: singhularity/indieprise-github-actions/run@main
        with:
          mode: scan
        env:
          INDIEPRISE_CONFIG_KEY: ${{ secrets.INDIEPRISE_CONFIG_KEY }}
```

### Migrate mode (runs on workflow_dispatch)

```yaml
name: Indieprise Migrate
on:
  workflow_dispatch:

jobs:
  migrate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: singhularity/indieprise-github-actions/run@main
        with:
          mode: migrate
        env:
          INDIEPRISE_CONFIG_KEY: ${{ secrets.INDIEPRISE_CONFIG_KEY }}
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `mode` | No | `scan` | `scan` to detect migration opportunities, `migrate` to create a PR |
| `gh-token` | No | `github.token` | GitHub token for downloading binaries from private repos |
| `runtime-key` | No | | Runtime authentication key for model access |
| `runtime-origin` | No | | Runtime configuration origin |

## Secrets

| Secret | Required | Description |
|--------|----------|-------------|
| `INDIEPRISE_CONFIG_KEY` | No | API key for Indieprise runtime. Without it, scanning is limited to language version detection only. |

## Outputs

### Scan mode
- Uploads `scan-report.json` and `scan-report.md` as a GitHub Actions artifact (`indieprise-scan-report`) retained for 90 days.
- Sets `SCAN_REPORT_DIR` in `GITHUB_ENV` for downstream steps.

### Migrate mode
- Opens a pull request in the repository with the proposed changes.
- **PRs are not created for public repos.** Migrate mode will exit with an error on public repositories.

## Safety

The migrate mode includes a visibility check before creating any PRs. If the repository is public, the action refuses to open a PR and exits with a clear error message. This prevents unwanted noise on open-source projects.
