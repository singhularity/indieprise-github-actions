#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-scan}"
LOG_DIR="/tmp/indieprise-bootstrap-logs"
mkdir -p "$LOG_DIR"

# Pre-flight: verify Ollama endpoint is reachable (Pi depends on it)
if ! curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
  echo "::error::Ollama endpoint not reachable at http://127.0.0.1:11434"
  echo "--- Ollama stderr ---"
  cat "$LOG_DIR/ollama-serve.stderr" 2>/dev/null || echo "(no stderr log)"
  echo "Attempting to check systemd service:"
  systemctl status ollama 2>/dev/null || echo "(not a systemd service)"
  exit 1
fi
echo "Ollama endpoint OK"

case "$MODE" in
  scan)
    echo "::group::Run migrataur scan"

    MIGRATAUR_STDERR="$LOG_DIR/migrataur-scan.stderr"
    MIGRATAUR_STDOUT="$LOG_DIR/migrataur-scan.stdout"

    echo "Running migrataur in scan-only mode on $GITHUB_WORKSPACE..."
    set +e
    migrataur migrate --project-dir "$GITHUB_WORKSPACE" --scan-only \
      >"$MIGRATAUR_STDOUT" 2>"$MIGRATAUR_STDERR"
    MIGRATAUR_EXIT=$?
    set -e

    cat "$MIGRATAUR_STDOUT"

    if [ $MIGRATAUR_EXIT -ne 0 ]; then
      echo "::error::migrataur scan failed (exit $MIGRATAUR_EXIT)"
      echo "--- migrataur stderr (contains Pi/LLM errors) ---"
      cat "$MIGRATAUR_STDERR"
      echo "--- Ollama stderr ---"
      cat "$LOG_DIR/ollama-serve.stderr" 2>/dev/null || echo "(no log)"

      if grep -qi "ECONNREFUSED\|models\.json\|openai-completions\|pi-coding-agent" "$MIGRATAUR_STDERR" 2>/dev/null; then
        echo "::error::Pi LLM agent crash detected. Check models.json and Ollama connectivity."
        echo "Pi config:"
        cat "$HOME/.pi/agent/models.json" 2>/dev/null || echo "(missing)"
        echo "Ollama /v1/models:"
        curl -s http://127.0.0.1:11434/v1/models 2>/dev/null || echo "(unreachable)"
      fi

      exit $MIGRATAUR_EXIT
    fi

    REPORT_DIR="$GITHUB_WORKSPACE/.migrataur"
    if [ ! -f "$REPORT_DIR/scan-report.json" ]; then
      echo "::warning::scan-report.json not found at $REPORT_DIR — migrataur may not have produced output"
      echo "--- migrataur stderr ---"
      cat "$MIGRATAUR_STDERR"
    else
      echo "Scan report written to $REPORT_DIR/scan-report.json"
      if ! jq empty "$REPORT_DIR/scan-report.json" 2>/dev/null; then
        echo "::warning::scan-report.json is not valid JSON"
      fi
    fi

    echo "SCAN_REPORT_DIR=$REPORT_DIR" >> "$GITHUB_ENV"

    # Surface warnings even on success
    if [ -s "$MIGRATAUR_STDERR" ]; then
      echo "::warning::migrataur produced stderr (scan succeeded but with warnings)"
      cat "$MIGRATAUR_STDERR"
    fi

    echo "::endgroup::"
    ;;

  migrate)
    echo "::group::Public repo safety check"

    VISIBILITY=$(gh repo view "$GITHUB_REPOSITORY" --json visibility -q .visibility)
    echo "Repo visibility: $VISIBILITY"

    if [ "$VISIBILITY" = "PUBLIC" ]; then
      echo "::error::PR creation disabled for public repos. Migration scan results are available but PRs will not be created."
      exit 1
    fi

    echo "Repo is private — proceeding with migration"
    echo "::endgroup::"

    echo "::group::Run migrataur migrate"

    MIGRATAUR_STDERR="$LOG_DIR/migrataur-migrate.stderr"
    MIGRATAUR_STDOUT="$LOG_DIR/migrataur-migrate.stdout"

    echo "Running migrataur in pull-request output mode on $GITHUB_WORKSPACE..."
    set +e
    migrataur migrate --project-dir "$GITHUB_WORKSPACE" --output-mode pull-request \
      >"$MIGRATAUR_STDOUT" 2>"$MIGRATAUR_STDERR"
    MIGRATAUR_EXIT=$?
    set -e

    cat "$MIGRATAUR_STDOUT"

    if [ $MIGRATAUR_EXIT -ne 0 ]; then
      echo "::error::migrataur migrate failed (exit $MIGRATAUR_EXIT)"
      echo "--- migrataur stderr ---"
      cat "$MIGRATAUR_STDERR"
      echo "--- Ollama stderr ---"
      cat "$LOG_DIR/ollama-serve.stderr" 2>/dev/null || echo "(no log)"
      exit $MIGRATAUR_EXIT
    fi

    if [ -s "$MIGRATAUR_STDERR" ]; then
      echo "::warning::migrataur produced stderr (migrate succeeded but with warnings)"
      cat "$MIGRATAUR_STDERR"
    fi

    echo "::endgroup::"
    ;;

  *)
    echo "::error::Unknown mode: '$MODE'. Valid modes are 'scan' or 'migrate'."
    exit 1
    ;;
esac

echo "INDIEPRISE_LOG_DIR=$LOG_DIR" >> "$GITHUB_ENV"
