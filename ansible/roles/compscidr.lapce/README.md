# ansible-lapce
[![Static Badge](https://img.shields.io/badge/Ansible_galaxy-Download-blue)](https://galaxy.ansible.com/ui/standalone/roles/compscidr/lapce/)
[![ansible lint](https://github.com/compscidr/ansible-lapce/actions/workflows/check.yml/badge.svg)](https://github.com/compscidr/ansible-lapce/actions/workflows/check.yml)
[![Molecule Test](https://github.com/compscidr/ansible-lapce/actions/workflows/molecule.yml/badge.svg)](https://github.com/compscidr/ansible-lapce/actions/workflows/molecule.yml)
[![ansible lint rules](https://img.shields.io/badge/Ansible--lint-rules%20table-blue.svg)](https://ansible.readthedocs.io/projects/lint/rules/)

A simple role to install the Lapce IDE
https://github.com/lapce/lapce

## Development & Testing

This role uses [Molecule](https://molecule.readthedocs.io/) for testing with Docker.

### Prerequisites

- Python 3.8+
- Docker
- Docker daemon running

### Setup

1. Create and activate a virtual environment:
```bash
python3 -m venv venv
source venv/bin/activate  # On Linux/macOS
# or
venv\Scripts\activate  # On Windows
```

2. Install dependencies:
```bash
pip install -r requirements.txt
```

### Running Tests

Run the full molecule test suite:
```bash
molecule test
```

Run individual test stages:
```bash
molecule create    # Create test instances
molecule converge  # Run the role
molecule verify    # Run verification tests
molecule destroy   # Destroy test instances
```

Test on a specific platform:
```bash
molecule test --platform-name ubuntu-22.04
```

### Testing Locally

For faster iteration during development:
```bash
molecule converge  # Apply changes
molecule verify    # Check results
```

When done:
```bash
molecule destroy
```
