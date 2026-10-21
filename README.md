# UNIX Ansible Playbook
Inspired by [geerlingguy/mac-dev-playbook](https://github.com/geerlingguy/mac-dev-playbook), 
this playbook sets up most of the software, and their configuration on my unix machines, MacOS, and Ubuntu.

# Usage
```sh
ansible-playbook main.yml --ask-become-pass
```

On the first run, the playbook installs the Galaxy roles and collections from `requirements.yml` into `.ansible/` inside the repository before executing the OS-specific roles.

## WIP
This playbook is currently work-in-progress.
