# r-ansible-scripts
Random Ansible scripts. Typically written for Ubuntu.

What's in the repo
------------------
The following directories:

- roles/installnagios -- Installs Nagios on a fresh Ubuntu server.

    - Tested on Ubuntu Server 16.04.03 and 17.04.
    - Tested with Nagios 4.3.4. 
    - Tested with Apache 2.4.18-2ubuntu3.4 and Apache 2.4.25-3ubuntu2.2. 
    - Assumes you already have Python installed to, you know, run Ansible tasks. You should probably first run a role containing `raw: bash -c "test -e /usr/bin/python || (apt -qqy update && apt install -qy python-minimal)"`

- roles/updatenagios -- Updates Nagios on an Ubuntu server.

    - Tested on Ubuntu Server 16.04.03 and 17.04.
    - Tested with Nagios 4.3.2.

- roles/provisionxenservervm -- Create many machines from nothing, onto which you can automatically install Nagios or something else in the future

    - Tested on XenServer 7.1.0

- playbooks/proxmox-upgrade -- Rolling update on one or more Proxmox Clusters

    - Tested on PVE 5.4-13

proxmox-upgrade
---------------
This one I'm really happy about, though there are some bits where I compromised. Basically at run-time you tell it what Ansible Group (or group of group, or host) you want to run this on, and also tell it what Proxmox Group of VMs (called a "pool" for whatever reason) that you don't mind being shut down just whenever. It first checks for updates, then shuts down the VM/Container group (pool) you specified to free up resources and make the migration process so much faster. Then it goes down the list of host (proxmox node) that actually need an update: it migrates off all offline VMs and containers, then checks the leftover VMs and containers, figures out how much RAM each needs, and then live-migrates them to another node that has MORE than enough RAM to pick up the slack. My script doesn't count CPU cores yet, though it does check each Proxmox box for how much CPU percentage is already being used. Anyway, it migrates all the VMs and Containers off the first box needing an update, then updates that box, reboots, and if the Proxmox box comes back online: goes onto the next box migrating, updating, and rebooting.

I've run this a lot in testing and a few times in production. It's not to a point where I feel comfortable scheduling it to happen on its own--I still want to supervise it, but it hasn't caused any trouble yet.
