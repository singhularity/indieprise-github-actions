#!/usr/bin/env bash
set -euo pipefail

# ── Config key ────────────────────────────────────────────────────────────────
echo "::group::Pull Indieprise config"

if [ -z "${INDIEPRISE_CONFIG_KEY:-}" ]; then
  echo "::warning::INDIEPRISE_CONFIG_KEY is not set. Scan will be limited to language version detection only. Set the INDIEPRISE_CONFIG_KEY secret to enable full migration pattern scanning."
else
  echo "INDIEPRISE_CONFIG_KEY is present — exporting to migrataur env vars"
  echo "MIGRATAUR_INTERNAL_TOKEN=${INDIEPRISE_CONFIG_KEY}" >> "$GITHUB_ENV"
  echo "INDIEPRISE_API_KEY=${INDIEPRISE_CONFIG_KEY}" >> "$GITHUB_ENV"
  if [ -n "${INDIEPRISE_RUNTIME_ORIGIN:-}" ]; then
    echo "MIGRATAUR_SERVER_URL=${INDIEPRISE_RUNTIME_ORIGIN}" >> "$GITHUB_ENV"
  fi
fi

echo "::endgroup::"

# ── SSH key ───────────────────────────────────────────────────────────────────
echo "::group::Configure SSH access"

if [ -n "${INDIEPRISE_SSH_KEY:-}" ]; then
  echo "INDIEPRISE_SSH_KEY is present — writing to ~/.ssh/id_indieprise"
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"

  printf '%s\n' "$INDIEPRISE_SSH_KEY" > "${HOME}/.ssh/id_indieprise"
  chmod 600 "${HOME}/.ssh/id_indieprise"

  # Register the key with ssh-agent if running, otherwise add to ssh config
  if ssh-add -l &>/dev/null 2>&1; then
    ssh-add "${HOME}/.ssh/id_indieprise" || true
  fi

  # Add to SSH config so migrataur's git operations pick it up automatically
  cat >> "${HOME}/.ssh/config" <<EOF

Host *
  IdentityFile ~/.ssh/id_indieprise
  StrictHostKeyChecking accept-new
EOF

  echo "SSH key configured"
else
  echo "INDIEPRISE_SSH_KEY not set — migrataur will resolve keys from runtime"
fi

echo "::endgroup::"
