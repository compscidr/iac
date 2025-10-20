# Dependency Management

This project uses a **dual workflow** for managing Ansible dependencies:

## Overview

- **Molecule Testing**: Dependencies install to isolated directories (`.molecule-roles/`, `.molecule-collections/`)
- **Standalone Playbooks**: Dependencies install to standard Ansible paths (`~/.ansible/roles/`, `~/.ansible/collections/`)

This keeps Molecule test dependencies isolated from your production environment.

## File Structure

```
├── requirements.yml              # External roles and collections
├── roles/                        # Your local custom roles only
├── .molecule-roles/             # External roles for Molecule (gitignored)
├── .molecule-collections/       # External collections for Molecule (gitignored)
└── molecule/
    └── default/
        └── dependency.sh        # Custom script for Molecule dependency installation
```

## For Molecule Testing

Dependencies are **automatically installed** when you run Molecule:

```bash
molecule test
molecule converge
# etc.
```

The custom `dependency.sh` script installs:
- External roles → `.molecule-roles/`
- External collections → `.molecule-collections/`

## For Standalone Playbook Execution

**First-time setup** (or after adding new dependencies to `requirements.yml`):

```bash
# Install external roles and collections
ansible-galaxy install -r requirements.yml
```

This installs:
- External roles → `~/.ansible/roles/`
- External collections → `~/.ansible/collections/`

**Then run your playbooks normally:**

```bash
ansible-playbook -i inventory.yml common.yml
ansible-playbook -i inventory.yml dev.yml
# etc.
```

## How It Works

### Molecule Path Resolution (via molecule.yml)
```
ANSIBLE_ROLES_PATH: ./roles:./.molecule-roles
ANSIBLE_COLLECTIONS_PATH: ./.molecule-collections
```

### Standalone Path Resolution (via ansible.cfg)
```
roles_path = ./roles:~/.ansible/roles
collections_path = ~/.ansible/collections
```

### Why This Approach?

1. **Isolation**: Molecule test dependencies don't pollute your development environment
2. **Consistency**: Standard `ansible-galaxy` workflow for production use
3. **Flexibility**: Can test different dependency versions in Molecule without affecting standalone runs
4. **Git Clean**: `.molecule-*` directories are gitignored

## Updating Dependencies

When you add or update dependencies in `requirements.yml`:

**For Molecule**: No action needed - runs automatically
**For Standalone**: Run `ansible-galaxy install -r requirements.yml --force`

## Troubleshooting

### "Role not found" when running standalone playbooks
→ Run: `ansible-galaxy install -r requirements.yml`

### "Role not found" when running Molecule
→ Run: `molecule destroy && molecule test` (forces fresh install)

### Want to see where Ansible looks for roles/collections?
→ Run: `ansible-config dump | grep -E "ROLES_PATH|COLLECTIONS_PATH"`
