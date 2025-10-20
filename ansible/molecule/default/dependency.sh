#!/bin/bash
set -e

# Molecule Dependency Installation Script
#
# This script installs external dependencies to isolated directories
# for Molecule testing. For standalone playbook execution, use:
#   ansible-galaxy install -r requirements.yml
#
# See DEPENDENCIES.md for more information.

# Get the project directory (two levels up from this script)
PROJECT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

echo "Installing Molecule dependencies to isolated directories..."

# Install roles to .molecule-roles
ansible-galaxy role install \
  -r "${PROJECT_DIR}/requirements.yml" \
  --roles-path "${PROJECT_DIR}/.molecule-roles" \
  --force

# Install collections to .molecule-collections
ansible-galaxy collection install \
  -r "${PROJECT_DIR}/requirements.yml" \
  --collections-path "${PROJECT_DIR}/.molecule-collections" \
  --force

echo "Molecule dependencies installed successfully!"
