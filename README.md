# r-ansible-scripts
Random Ansible scripts. Typically written for Ubuntu.

What's in the repo
------------------
The following directories:

- roles/installnagios -- Installs Nagios on a fresh Ubuntu server.

    - Tested on Ubuntu Server 16.04.03 and 17.04.
    - Tested with Nagios 4.3.4. 
    - Tested with Apache 2.4.18-2ubuntu3.4 and Apache 2.4.25-3ubuntu2.2. 
    - Assumes you already have Python installed to, you know, run Ansible tasks. You should probably first run a role containing `raw: sudo bash -c "test -e /usr/bin/python || (apt -qqy update && apt install -qy python-minimal)"`
