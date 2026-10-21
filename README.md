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

## SSH between LAN machines
The `ssh` role sets up a key-only SSH server on Ubuntu (restricted to `ssh_server_allowed_networks`)
and adds the `ubuntu` host alias to `~/.ssh/config` on macOS. Public keys are not managed here;
append the client's public key to `~/.ssh/authorized_keys` on the server manually.

```sh
# on the Mac
ssh ubuntu 'uname -a'
rsync -avz ./some-dir/ ubuntu:/tmp/some-dir/
```
