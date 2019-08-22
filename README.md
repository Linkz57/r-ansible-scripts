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
    
- roles/provisionproxmox -- Create many machines from nothing, onto which you can automatically install Nagios or more importantly automatically test backups by spinning them up on isolated VLANs and checking them with Nagios, reporting the results and automaticvally deleting both.

    - Tested on Proxmox 5.2-10 and 5.4-5

- playbooks/proxmox-upgrade -- Rolling update on one or more Proxmox Clusters

    - Tested on PVE 5.4-13
    
    
provisionproxmox
----------------
This is going to be super dope when it's done. What's the use of backups? To restore them in an emergency. How do we know if a backup can be restored? Well, we can restore them and then test if they do what they should. How do we test to see if a machine is doing what it should? Nagios is handy with that.

The plan is: we get a physically seperate Proxmox box/cluster and spin up a bunch of backup onto it, automatically. We'll also spin up a Nagios container that tests the restored backup for a bit, and then both Nagios and the backup is deleted, and another backup is restored into a VM and we do it all over again, over and over for each backup. The whole time this will be a physically seperate network because we don't want any backup machines running on the same network as their origionals, causing collisions. Some humans come in Monday and check the status of the backup test.

How will this look? Nagios has this "Host Group Grid" view that seems like a nice way to see all test results in rows and columns, color-coded. Maybe instead of building and destroying Nagios 60 times every weekend, we keep the same instance running all week, and then tell it 60 times to "Enable active checks of this service" while that backup has spun up, wait 10 minutes, then tell it to "Disable active checks of this service" and then destroy the restored machine. Then on Monday morning we can go to the seperate network, or be emailed a screenshot, and see what's red, what's green, and what service hasn't been checked in more than a week (nagios can sort by 'date last checked').

How will this cluster be powered? We have a lot of fairly powerful workstations that are (with some exception) used for 8 hours every weekday and ignored at all other times, right? Here's some half-formed thoughts on how we can gain a large ammount of compute power for little cost:
- employees shut down their workstations when they leave for the night
- at 6pm send a WOL packet to all workstations, which are set to PXE boot either always or just on WOL
- workstations still running are either being used by a human or doing what a human told them to do, and ignore the WOL and certainly don't PXE boot
- at any time besides 6pm, PXE booting does nothing. at 6pm it boots to a unique Proxmox live environment, and checks our backups
- or maybe instead of proxmox just a regular ubuntu that runs a virus scan or calculates shasums of files unfortunate enough to not be on a ZFS volume.
- When they're done, they shut down. When 5am rolls around their PXE images are all set to shut down forcefully-mid job.
- Eventually we'll see a pattern of reports saying 'check failed because 5am happened' about one or two of our biggest backups, and then we can either relegate those tests to just the weekend, or invest in dedicated hardware for these one or two backups if they're important enough. Maybe that hardware will be in the form of a very fast workstation for a lucky employee. The majority of our servers run Linux or Unix, and as such have very small backups that can be tested much quicker.

proxmox-upgrade
---------------
This one I'm really happy about, though there are some bits where I compromised. Basically at run-time you tell it what Ansible Group (or group of group, or host) you want to run this on, and also tell it what Proxmox Group of VMs (called a "pool" for whatever reason) that you don't mind being shut down just whenever. It first checks for updates, then shuts down the VM/Container group (pool) you specified to free up resources and make the migration process so much faster. Then it goes down the list of host (proxmox node) that actually need an update: it migrates off all offline VMs and containers, then checks the leftover VMs and containers, figures out how much RAM each needs, and then live-migrates them to another node that has MORE than enough RAM to pick up the slack. My script doesn't count CPU cores yet, though it does check each Proxmox box for how much CPU percentage is already being used. Anyway, it migrates all the VMs and Containers off the first box needing an update, then updates that box, reboots, and if the Proxmox box comes back online: goes onto the next box migrating, updating, and rebooting.

I've run this a lot in testing and a few times in production. It's not to a point where I feel comfortable scheduling it to happen on its own--I still want to supervise it, but it hasn't caused any trouble yet.
