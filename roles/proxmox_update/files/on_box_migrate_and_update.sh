#!/bin/bash
## on_box_migrate_and_update.sh
## version 2.0
## The goal here is to perform a rolling update and reboot of every node.
##
## To do that, this script first shuts down a "pool" of VMs and containers that a human previous said was ok to shut down whenever.
## Then this script migrates offline containers and VMs to the first other online node it finds.
## Then, for each running container and VM, look through each node until one is found that,
## given a margin of safety, has enough resources to accept a live migration.
## Then this script double-checks to make sure everything is migrated off,
## then updates and (assuming the update succeeded) finally reboots.
##
##
## Warning: this script doesn't yet count the number of CPU cores.
## This can be a problem because you always want to make sure the host/node/hypervisor/whatever name you want to call it,
## always has at least one core not spoken for by any VM or container.
## If the hypervisor doesn't have its own core, a runaway VO could DOS its host and thereby kill its neighbors too.
## TODO: count CPU cores.




## If a node is already using more than 50% of its RAM, then don't migrate to it. Type this as a fraction.
## FYI: live VM migrations require a LOT of free RAM on the receiving node.
ramFillLine="5/10"

## If a node is using more than 60% of all its CPU cores, then don't migrate to it. Type this as a percentage number without the % symbol.
cpuFillLine="60"




## Alright, stop editing variables,
## the rest of this is robot stuff.






safeToReboot=false






## migrate offline Containers if the cluster is healthy
printf "\n\n\n"
echo "Migrating offline Containers"
if pvesh get /cluster/status --output-format json-pretty |
grep '\"quorate\" \: 1' > /dev/null
then
	## migrate only the ones that are offline, to the first online node
	for offlinelxc in $(pvesh get /nodes/localhost/lxc --noborder 1 --noheader 1 |
	grep stopped |
	cut -d' ' -f3)
	do
		if /usr/bin/pvesh get "/nodes/localhost/lxc/$offlinelxc/config" --output-format json-pretty | ## check the configuration of each container before you migrate it
		/bin/grep '\"rootfs\"' | ## we don't want to copy the whole filesystem, at least not yet.
		/usr/bin/cut -d':' -f2 | ## remove the JSON name field
		/bin/grep local ## make sure it's not a locally stored filesystem
		then
			true ## do nothing if it's locally stored
		else

			## Now that we have a filtered list of all LXC containers we won't have to migrate the storage of,
			## migrate them off one-at-a-time to the first node you can find that isn't you.
			/usr/bin/pvesh --nooutput create "/nodes/localhost/lxc/$offlinelxc/migrate" --target "$(/usr/bin/pvesh get /nodes --noborder 1 --noheader 1 | ## Start a migration, and get a list of every node you could migrate your LXC containers to.
			/bin/grep -v "$(/bin/hostname)" | ## Remove your own name from the list, because migrating to yourself is useless.
			/bin/grep online | ## Filter the list of nodes down to just the folk online at the moment, thus able to be migrated to
			/usr/bin/cut -d' ' -f1 | ## Remove all the metadata like number of cores each node has, and what its favorite color is. An offline migration doesn't need a lot of resources, just anything with a pulse.
			/usr/bin/head -n1)" ## Just choose the top of the list. A random spray re-rolled for each migration might be better for a lot of reasons, but it's also harder to clean up afterwards.
		fi
	done
fi


## migrate offline VMs if the cluster is healthy
printf "\n\n\n"
echo "Migrating offline VMs"
if pvesh get /cluster/status --output-format json-pretty |
grep '\"quorate\" \: 1' > /dev/null
then
	## Find all VMs using the Proxmox API, then cut out everything except the actual VMID. Same as above.
	for offlineqemu in $(pvesh get /nodes/localhost/qemu --noborder 1 --noheader 1 |
	grep stopped | ## only the ones that are offline
	cut -d' ' -f3)
	do
		if pvesh get "/nodes/localhost/qemu/$offlineqemu/config" --output-format json-pretty | ## check the configuration of each VM
		grep -E '^   "((scsi)|(sata)|(virtio)|(ide))[0-9]*. : "local' ## if it has a locally stored filesystem...
		then
			true ## ...then don't migrate it.
		else

			## otherwise if it's not local, then migrate them off one-at-a-time to the first node that isn't you. Hooray for subshells.
			/usr/bin/pvesh --nooutput create "/nodes/localhost/qemu/$offlineqemu/migrate" --online --target "$(/usr/bin/pvesh get /nodes --noborder 1 --noheader 1 |
			/bin/grep -v "$(/bin/hostname)" |
			/bin/grep online |
			/usr/bin/cut -d' ' -f1 |
			/usr/bin/head -n1)"
		fi
	done
fi







iHaveContainers=true

## migrate running Containers if the cluster is healthy
printf "\n\n\n"
echo "Migrating running containers"
if pvesh get /cluster/status --output-format json-pretty |
grep '\"quorate\" \: 1' > /dev/null
then
	## For each Container running on localhost
	for lxcRemaining in $(pvesh get /nodes/localhost/lxc --noborder 1 --noheader 1 |
	cut -d' ' -f3)
	do
		## Wait a bit for previous migrations to boot up and consume resources, before evaluating further migration targets
		sleep 20

		## check its resource requirements
		voMaxRam=$(pvesh get "/nodes/localhost/lxc/$lxcRemaining/config" --output-format json-pretty |
		grep '\"memory\" \: ' |
		awk -F'[(: )|,]' '{print $7}')

		## find all online nodes,
		for resourcez in $(/usr/bin/pvesh get "/nodes" --noborder 1 --noheader 1 |
		/bin/grep -v "$(/bin/hostname)" |
		/bin/grep online |
		/usr/bin/cut -d' ' -f1)
		do
			## if you ask for just a single node's resources you get text that's more difficult to parse.
			## So we're going to ask for the resources for all nodes, once for each node in the cluster.
			## Also I don't really need awk here at all. I could delete it entirely and just shift the array numbers.

			##		0	1		2		3		4
			## in AWK	cpu=3	maxRam=5	usedRam=7	maxRamUnits=6	usedRamUnits=8
			resourceArray=($(pvesh get /nodes/ --noborder 1 --noheader 1 |
			grep "$resourcez" |
			awk -F' ' '{print $3  " "  $5  " "  $7  " "  $6  " "  $8}'))

#			cpu=$(pvesh get /nodes/ --noborder 1 --noheader 1 | grep $resourcez | awk -F' ' '{print $3}')
#			maxRam=$(pvesh get /nodes/ --noborder 1 --noheader 1 | grep $resourcez | awk -F' ' '{print $5}')
#			usedRam=$(pvesh get /nodes/ --noborder 1 --noheader 1 | grep $resourcez | awk -F' ' '{print $7}')
#			maxRamUnits=$(pvesh get /nodes/ --noborder 1 --noheader 1 | grep $resourcez | awk -F' ' '{print $6}')
#			usedRamUnits=$(pvesh get /nodes/ --noborder 1 --noheader 1 | grep $resourcez | awk -F' ' '{print $8}')

			## multiplication chart
			## if PiB, 1125899906842624
			## if TiB, 1099511627776
			## if GiB, 1073741824
			## if MiB, 1048576
			## if KiB, 1024

			## multiply max RAM each by their unit. Proxmox seems to ship with BC.
			case ${resourceArray[3]} in

				PiB|pib )
					maxRamReal=$(echo "${resourceArray[1]} * 1125899906842624" | bc)
				;;

				TiB|tib )
					maxRamReal=$(echo "${resourceArray[1]} * 1099511627776" | bc)
				;;

				GiB|gib )
					maxRamReal=$(echo "${resourceArray[1]} * 1073741824" | bc)
				;;

				MiB|mib )
					maxRamReal=$(echo "${resourceArray[1]} * 1048576" | bc)
				;;

				KiB|kib )
					maxRamReal=$(echo "${resourceArray[1]} * 1024" | bc)
				;;

			esac

			## multiply used RAM each by their unit. Proxmox seems to ship with BC.
			case ${resourceArray[4]} in

				PiB|pib )
					usedRamReal=$(echo "${resourceArray[2]} * 1125899906842624" | bc)
				;;

				TiB|tib )
					usedRamReal=$(echo "${resourceArray[2]} * 1099511627776" | bc)
				;;

				GiB|gib )
					usedRamReal=$(echo "${resourceArray[2]} * 1073741824" | bc)
				;;

				MiB|mib )
					usedRamReal=$(echo "${resourceArray[2]} * 1048576" | bc)
				;;

				KiB|kib )
					usedRamReal=$(echo "${resourceArray[2]} * 1024" | bc)
				;;

			esac

			## Let's do a lazy truncate down to an integer. Will work even if it's already an integer.
#			maxRamReal=$(echo "$maxRamReal" | cut -d'.' -f1)
#			usedRamReal=$(echo "$usedRamReal" | cut -d'.' -f1)
#			voMaxRam=$(echo "$voMaxRam" | cut -d'.' -f1)

			## Bash follows the order of operations, even though left-to-right would also work in this case. voMaxRam is always in MiB.
			if [[ $( echo "$maxRamReal * $ramFillLine - $usedRamReal" | bc | cut -d'.' -f1) -gt $( echo "$voMaxRam * 1048576" | bc | cut -d'.' -f1) ]] &&
			[[ $( echo "${resourceArray[0]}" | cut -d'%' -f1 | cut -d'.' -f1 ) -lt 60 ]]; then
				## ok to migrate
				/usr/bin/pvesh --nooutput create "/nodes/localhost/lxc/$lxcRemaining/migrate" --restart --target "$resourcez"
				break
				## break this loop looking for nodes, and continue the parent loop looking for containers that need migration
			else
				## not enough spare resources.
				echo "$(echo "(($maxRamReal * $ramFillLine) - $usedRamReal) / 1048576" | bc ) MiB of available RAM is apparently not enough on $resourcez to accept LXC $lxcRemaining with its needed $voMaxRam MiB of RAM."
				echo "Or maybe $resourcez was using more than $cpuFillLine of its CPU? It was at ${resourceArray[0]} when I checked."
				printf "Either way, I'm going to look for another node to migrate to.\n\n"
			fi

		done
	done

	if [ -z "$lxcRemaining" ]
	then
		iHaveContainers=false
	fi
fi


## migrating something will wait until the migration is complete and then go onto the next task
## migrating something under HA, on the other hand, send a migration request,
## and then goes onto the next task before the migration have even started, let alone completed.
## Let's wait some seconds after all HA requests have been sent to see if any are actually in progress.
## TODO: look for RAM migration and LVM local disks.
if $iHaveContainers ; then
	printf "\n\n\n"
	echo "Looking for in-progress migrations to or from this node..."
	sleep 40
	while ps aux |
	grep -v grep |
	grep -E "((zfs )(recv)|(send))|(/usr/bin/perl /usr/sbin/pvesm import)"
	do
		sleep 5
		echo "Still migrating stuff"
	done
	sleep 20
	echo "I think everything has finished migrating."
fi

## it only took me 8 tries to write that grep regex. I'm obviously transcending to a greater form of consciousness.


## Were all Containers migrated off? If so, start migrating VMs
printf "\n\n\n"
echo "Migrating running VMs"
if [[ $(pvesh get /nodes/localhost/lxc --noborder 1 --noheader 1 | wc -l) -gt 0 ]]
then
	echo "I've tried to migrate off all LXC containers, but I couldn't find any nodes big enough for some of these containers. I will not keep going, nor will I attempt to migrate any VMs."
	echo "Here are the remaining containers"
	pvesh get /nodes/localhost/lxc
	safeToReboot=false


else


	echo "$(hostname) is drained of LXC containers. Time to move onto QEMU VMs."

	## migrate running VMs if the cluster is healthy
	if pvesh get /cluster/status --output-format json-pretty |
	grep '\"quorate\" \: 1'
	then
		## For each VM running on localhost
		for qemuRemaining in $(pvesh get /nodes/localhost/qemu --output-format json-pretty |
		/bin/grep '\"vmid\"' |
		/usr/bin/cut -d':' -f2 |
		/usr/bin/cut -d'"' -f2)
		do
			## Wait a bit for previous migrations to boot up and consume resources, before evaluating further migration targets
			sleep 40

			## check its resource requirements
			qemuMaxRam=$(pvesh get "/nodes/localhost/qemu/$qemuRemaining/config" --output-format json-pretty |
			grep -A 1 '\"memory\"\: ' |
			tail -n 1 |
			awk -F'(: )' '{print $2}')

			## find all online nodes,
			for resourcez in $(/usr/bin/pvesh get /nodes --noborder 1 --noheader 1 |
			/bin/grep -v "$(/bin/hostname)" |
			/bin/grep online |
			/usr/bin/cut -d' ' -f1)
			do
				## if you ask for just a single node's resources you get text that's more difficult to parse.
				## So we're going to ask for the resources for all nodes, once for each node in the cluster.
				## Also I don't really need awk here at all. I could delete it entirely and just shift the array numbers.

				##		0	1		2		3		4
				## in AWK	cpu=3	maxRam=5	usedRam=7	maxRamUnits=6	usedRamUnits=8
				resourceArray=($(pvesh get /nodes/ --noborder 1 --noheader 1 |
				grep "$resourcez" |
				awk -F' ' '{print $3  " "  $5  " "  $7  " "  $6  " "  $8}'))


				## multiplication chart
				## if PiB, 1125899906842624
				## if TiB, 1099511627776
				## if GiB, 1073741824
				## if MiB, 1048576
				## if KiB, 1024

				## multiply max RAM each by their unit. Proxmox seems to ship with BC.
				case ${resourceArray[3]} in

					PiB|pib )
						maxRamReal=$(echo "${resourceArray[1]} * 1125899906842624" | bc)
					;;

					TiB|tib )
						maxRamReal=$(echo "${resourceArray[1]} * 1099511627776" | bc)
					;;

					GiB|gib )
						maxRamReal=$(echo "${resourceArray[1]} * 1073741824" | bc)
					;;

					MiB|mib )
						maxRamReal=$(echo "${resourceArray[1]} * 1048576" | bc)
					;;

					KiB|kib )
						maxRamReal=$(echo "${resourceArray[1]} * 1024" | bc)
					;;

				esac

				## multiply used RAM each by their unit. Proxmox seems to ship with BC.
				case ${resourceArray[4]} in

					PiB|pib )
						usedRamReal=$(echo "${resourceArray[2]} * 1125899906842624" | bc)
					;;

					TiB|tib )
						usedRamReal=$(echo "${resourceArray[2]} * 1099511627776" | bc)
					;;

					GiB|gib )
						usedRamReal=$(echo "${resourceArray[2]} * 1073741824" | bc)
					;;

					MiB|mib )
						usedRamReal=$(echo "${resourceArray[2]} * 1048576" | bc)
					;;

					KiB|kib )
						usedRamReal=$(echo "${resourceArray[2]} * 1024" | bc)
					;;

				esac


				## Bash follows the order of operations, even though left-to-right would also work in this case. qemuMaxRam is always in MiB.
				if [[ $( echo "$maxRamReal * $ramFillLine - $usedRamReal" | bc | cut -d'.' -f1) -gt $( echo "$qemuMaxRam * 1048576" | bc | cut -d'.' -f1) ]] &&
				[[ $( echo "${resourceArray[0]}" | cut -d'%' -f1 | cut -d'.' -f1 ) -lt 60 ]]; then
					## ok to migrate
					/usr/bin/pvesh --nooutput create "/nodes/localhost/qemu/$qemuRemaining/migrate" --online --with-local-disks --target "$resourcez"
					break
					## break this loop looking for nodes, and continue the parent loop looking for VMs that need migration
				else
					## not enough spare resources.
					echo "$(echo "($maxRamReal * $ramFillLine - $usedRamReal) * 1048576" | bc ) MiB of available RAM is apparently not enough on $resourcez to accept QEMU $lxcRemaining with its needed $qemuMaxRam MiB of RAM."
					echo "Or maybe $resourcez was using more than $cpuFillLine of its CPU? It was at ${resourceArray[0]} when I checked."
					echo "Either way, I'm going to look for another node to migrate to."
				fi

			done
		done
	fi

	## migrating something will wait until the migration is complete and then go onto the next task
	## migrating something under HA, on the other hand, send a migration request,
	## and then goes onto the next task before the migration have even started, let alone completed.
	## Let's wait some seconds after all HA requests have been sent to see if any are actually in progress.
	## TODO: look for RAM migration and LVM local disks.

	printf "\n\n\n"
	echo "Looking for in-progress migrations to or from this node..."
	sleep 40
	while ps aux |
	grep -v grep |
	grep -E "((zfs )(recv)|(send))|(/usr/bin/perl /usr/sbin/pvesm import)"
	do
		sleep 5
		echo "Still migrating stuff"
	done
	sleep 20
	echo "I think everything has finished migrating."


	## Were all VMs migrated off? If so, then both VMs and Containers were successfully migrated off, and we're safe to reboot.
	if [[ $(pvesh get /nodes/localhost/qemu --noborder 1 --noheader 1 | wc -l) -gt 0 ]]
	then
		echo "I've tried to migrate off all VMs, but I couldn't find any nodes big enough for some of them. I will not keep going."
		echo "here is what's left"
		pvesh get /nodes/localhost/qemu
		safeToReboot=false
	else
		safeToReboot=true
	fi
fi






## update and if updated successfully, then reboot
printf "\n\n\n"
echo "Updating, finally"
if $safeToReboot
then
	apt update &&
	apt upgrade -y &&
	exit 0 ## passing back to Ansible for a reboot
else
	echo "$(hostname) is still hosting Virtual Objects, so I'm not going to update or reboot."
	exit 1
fi

## go onto next node
