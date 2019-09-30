#!/bin/bash
## on_box_migrate_and_update.sh
## version 3.15
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

## If you're using local storage for a VM, I'll check the receiving node's local storage space. What threshold of available space do you want to always preserve? I'll assume all the numbers are literal, like they're not thin-provisioned--that will give you room to grow and be easier to math out.
## Type this as a percentage, but without the % symbol.
diskMarginPercentage="30"




## Alright, stop editing variables,
## the rest of this is robot stuff.






safeToReboot=false



          #                  ""#          
  #mm   mmm    mmmmm  mmmm     #     mmm  
 #   "    #    # # #  #" "#    #    #"  # 
  #""m    #    # # #  #   #    #    #"""" 
 #mmm"  mm#mm  # # #  ##m#"    "mm  "#mm" 
                      #                   
                      #
          #                           m      "                        
 #mmmm  mmm     mmmm   m mm   mmm   mm#mm  mmm     mmm   m mm    mmm  
 # # #    #    #" "#   #"  " "   #    #      #    #" "#  #"  #  #   " 
 # # #    #    #   #   #     m"""#    #      #    #   #  #   #   """m 
 # # #  mm#mm  "#m"#   #     "mm"#    "mm  mm#mm  "#m#"  #   #  "mmm" 
                #  #                                                  
                 #"                                                   

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







                        #             "                               
  #mm    mmm   m mm   mm#mm   mmm   mmm    m mm    mmm    m mm   mmm  
 #"  "  #" "#  #"  #    #    "   #    #    #"  #  #"  #   #"  " #   " 
 #      #   #  #   #    #    m"""#    #    #   #  #""""   #      """m 
  ##m"  "#m#"  #   #    "mm  "mm"#  mm#mm  #   #  "#mm"   #     "mmm" 

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

		## check its resource requirements, if it's running
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

			
			ram=false
			cpu=false
			disk=false
			## Bash follows the order of operations, even though left-to-right would also work in this case. voMaxRam is always in MiB.
			if pct list | grep -E "$lxcRemaining.*stopped" || ## if the container is either stopped or doesn't take too much RAM
				## a potential migration destination has enough RAM for the thing you want to migrate, and would still stay under "ramFillLine" set at the beginning of this script
				[[ $( echo "$maxRamReal * $ramFillLine - $usedRamReal" |
				bc |
				cut -d'.' -f1) -gt $( echo "$voMaxRam * 1048576" |
				bc |
				cut -d'.' -f1) ]]
			then
				ram=true
			fi

			if pct list | grep -E "$lxcRemaining.*stopped" ||
				## and isn't curretly consuming more than "cpuFillLine" percent of CPU
				[[ $( echo "${resourceArray[0]}" |
				cut -d'%' -f1 |
				cut -d'.' -f1 ) -lt $cpuFillLine ]]
			then
				cpu=true
			fi


				## and, if it's locally stored, the disk isn't more than the recieving node can handle
				if /usr/bin/pvesh get "/nodes/localhost/lxc/$lxcRemaining/config" --output-format json-pretty | ## Are you using local disks?
				/bin/grep '\"rootfs\"' |
				/usr/bin/cut -d':' -f2 | ## remove the JSON name field
				/bin/grep local ## is it a locally stored filesystem?
				then
					## it's locally stored. Better make sure the destination node has enough space.

					## but first: what's the container's specs?

					## Number of things in array	0		1		2		2.5		3		4		5		6		7		8		9		10
					## Name of those things			status	vmid	cpus	lock	maxdisk	dskUnit	maxmem	memUnit	maxswap	swpunit	name	uptime
					voArray=($(pvesh get /nodes/localhost/lxc  --noborder 1 --noheader 1 | grep "$lxcRemaining"))


					## multiply max disk size each by its unit. Proxmox seems to ship with BC.
					case ${voArray[4]} in

						PiB|pib )
							requiredDiskReal=$(echo "${voArray[3]} * 1125899906842624" | bc)
						;;

						TiB|tib )
							requiredDiskReal=$(echo "${voArray[3]} * 1099511627776" | bc)
						;;

						GiB|gib )
							requiredDiskReal=$(echo "${voArray[3]} * 1073741824" | bc)
						;;

						MiB|mib )
							requiredDiskReal=$(echo "${voArray[3]} * 1048576" | bc)
						;;

						KiB|kib )
							requiredDiskReal=$(echo "${voArray[3]} * 1024" | bc)
						;;

					esac

					
					if ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "grep -i zfs /proc/cmdline" ## did the potential desination node boot from ZFS today or any other Filesystem? TODO: check also for BTRFS and other weird filesystems
					## It was many hours after writing the above line that I discovered df -T was a thing :( 
					then
                        #mmmmm mmmmmm  mmmm 
                            #" #      #"   "
                          ##   #mmmmm "#mmm 
                         #"    #          "#
                        ##mmmm #      "mmm#"
                       
						## Number of things in array	0		1		2		3		4		5		6		7		8		9
						## Name of those things			name	size	used	free	expandz	frag	capacty	dedup	health	altroot
						diskArray=($(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "zpool list | grep $(grep ZFS= /proc/cmdline | cut -d' ' -f2 | sed 's/root=ZFS=//' | cut -d'/' -f1)"))

						## Remove all numbers (digits) and periods from ZFS size, so we are left with just a letter
						## find used size
						case $(${arra[2]} | sed 's/[[:digit:]].//g') in 

							P|p )
								usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
							;;

							T|t )
								usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
							;;

							G|g )
								usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
							;;

							M|m )
								usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
							;;

							K|k )
								usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
							;;

						esac

						## find free size
						case $(${arra[3]} | sed 's/[[:digit:]].//g') in 

							P|p )
								availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
							;;

							T|t )
								availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
							;;

							G|g )
								availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
							;;

							M|m )
								availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
							;;

							K|k )
								availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
							;;

						esac


						## find total size
						case $(${arra[1]} | sed 's/[[:digit:]].//g') in 

							P|p )
								totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
							;;

							T|t )
								totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
							;;

							G|g )
								totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
							;;

							M|m )
								totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
							;;

							K|k )
								totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
							;;

						esac


						## Now the moment we've all been waiting for: more math. Is this VO too fat for this potential destination node?
						[[ $( echo "$availableDiskReal - ($totalDiskReal * $diskMarginPercentage / 100) - $requiredDiskReal" |
						bc | ## actual math, before truncating down to an integer for Bash.
						cut -d'.' -f1 ) -gt 1  ]] && disk=true
					else
                                  #    #                           mmmmmm  mmmm 
                          #mm   mm#mm  # mm    mmm    m mm         #      #"   "
                         #" "#    #    #"  #  #"  #   #"  "        #mmmmm "#mmm 
                         #   #    #    #   #  #""""   #            #          "#
                          #m#     "mm  #   #  "#mm"   #            #      "mmm#"
                        
						## you're not using ZFS, so I'm assuming it's something simple like EXT or XFS.

						
						otherFileSystemAvailable=$(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "vgs --noheadings --units b --nosuffix -o lv_size,lv_dmpath --nameprefixes" |
						grep "LVM2_LV_DM_PATH='/dev/mapper/pve-data'" |
						cut -d"'" -f2)

						otherFileSystemTotal=$(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "pvdisplay --units b" | grep -A 1 -E 'VG Name.*pve' | tail -n 1 | awk '{print $3}')

						[[ $( echo "$otherFileSystemAvailable - ($otherFileSystemTotal * $diskMarginPercentage / 100) - $requiredDiskReal" |
						bc | ## actual math, before truncating down to an integer for Bash.
						cut -d'.' -f1 ) -gt 1  ]] && disk=true

					fi ## has enough local disk space
				else
					## not locally stored
					disk=true
				fi ## using local disks


			if $ram && $cpu && $disk

			then
				## ok to migrate
				printf "\n\n\n"
				/usr/bin/pvesh --nooutput create "/nodes/localhost/lxc/$lxcRemaining/migrate" --restart --target "$resourcez"
				break
				## break this loop looking for nodes, and continue the parent loop looking for containers that need migration
			else
				## not enough spare resources.
				echo "$(echo "(($maxRamReal * $ramFillLine) - $usedRamReal) / 1048576" | bc ) MiB of available RAM is apparently not enough on $resourcez to accept LXC $lxcRemaining with its needed $voMaxRam MiB of RAM."
				echo "Or maybe $resourcez was using more than $cpuFillLine% of its CPU? It was at ${resourceArray[0]} when I checked."
				echo "It could also be that the $( echo "$requiredDiskReal / 1073741824" | bc) GiB disk was too big for the available space of $( echo "$otherFileSystemAvailable / 1073741824" | bc) GiB."
				echo "now that I think about it:"
				if $ram ; then echo "The RAM was ok" ; fi
				if $cpu ; then echo "The CPU was ok" ; fi
				if $disk ; then echo "The Disk was ok" ; fi
				printf "Either way, I'm going to look for another node to migrate to.\n\n"
			fi

		done
	done

	if [ -z "$lxcRemaining" ]
	then
		iHaveContainers=false
	fi
fi

                   #                                m             "          
  #mm   m mm    mmm#          mmm    mmm   m mm   mm#mm   mmm   mmm    m mm  
 #"  #  #"  #  #" "#         #"  "  #" "#  #"  #    #    "   #    #    #"  # 
 #""""  #   #  #   #         #      #   #  #   #    #    m"""#    #    #   # 
  #mm"  #   #  "#m##         "#mm"  "#m#"  #   #    "mm  "mm"#  mm#mm  #   #







## migrating something will wait until the migration is complete and then go onto the next task
## migrating something under HA, on the other hand, send a migration request,
## and then goes onto the next task before the migration have even started, let alone completed.
## Let's wait some seconds after all HA requests have been sent to see if any are actually in progress.
## TODO: look for RAM migration and LVM local disks.
if $iHaveContainers ; then
	printf "\n\n\n"
	echo "Looking for in-progress migrations to or from this node..."
	sleep 30
	while ps aux |
	grep -v grep |
	grep -E "((zfs )(recv)|(send))|(/usr/bin/perl /usr/sbin/pvesm import)|(ssh.*HostKeyAlias=.*ExitOnForwardFailure=yes.*-L /run.*migrate.*tunnel)|(ssh.*HostKeyAlias=.*pvesr)|(ssh.*HostKeyAlias=.*pct st)" ||
	pvesh get /cluster/ha/status/current --noborder --noheader | grep migrate
	do
		sleep 5
		echo "Still migrating stuff"
	done
	sleep 20
	echo "I think everything has finished migrating."
fi

## it only took me 8 tries to write that grep regex. I'm obviously transcending to a greater form of consciousness.







          #                           m                  m    m m    m       
 #mmmm  mmm     mmmm   m mm   mmm   mm#mm   mmm          "m  m" ##  ##  mmm  
 # # #    #    #" "#   #"  " "   #    #    #"  #          #  #  # ## # #   " 
 # # #    #    #   #   #     m"""#    #    #""""          "mm"  # "" #  """m 
 # # #  mm#mm  "#m"#   #     "mm"#    "mm  "#mm"           ##   #    # "mmm" 
                #  #                                                         
                 #"

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
			grep '\"memory\"' |
			awk -F'(: )' '{print $2}' |
			cut -d',' -f1)

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


				ram=false
				cpu=false
				disk=false
				## Bash follows the order of operations, even though left-to-right would also work in this case. qemuMaxRam is always in MiB.
					if qm list | grep -E "$qemuRemaining.*stopped" || ## if it's either off or small enough
						## if has enough RAM
						[[ $( echo "$maxRamReal * $ramFillLine - $usedRamReal" |
						bc |
						cut -d'.' -f1) -gt $( echo "$qemuMaxRam * 1048576" |
						bc |
						cut -d'.' -f1) ]]
					then
						ram=true
					fi


					if qm list | grep -E "$qemuRemaining.*stopped" || ## either off or the destination has enough CPU
						[[ $( echo "${resourceArray[0]}" |
						cut -d'%' -f1 |
						cut -d'.' -f1 ) -lt 60 ]]
					then
						cpu=true
					fi


					## and, if local, it has enough disk space
					if
						pvesh get "/nodes/localhost/qemu/$qemuRemaining/config" --output-format json-pretty | ## check the configuration of each VM
						grep -E '^   "((scsi)|(sata)|(virtio)|(ide))[0-9]*. : "local' ## if it has a locally stored filesystem...
					then
						## it's locally stored. Better make sure the destination node has enough space.

						## but first: what's the container's specs?

						## # things in array	0		1		2		2.5		3		4		5		6		7		8		8.5		10
						## Name of things		status	vmid	cpus	lock	maxdisk	dskUnit	maxmem	memUnit	name	pid		qmpstat	uptime
						voArray=($(pvesh get /nodes/localhost/qemu --noborder 1 --noheader 1 | grep "$qemuRemaining"))


						## multiply max disk size each by its unit. Proxmox seems to ship with BC.
						case ${voArray[4]} in

							PiB|pib )
								requiredVmDiskReal=$(echo "${voArray[3]} * 1125899906842624" | bc)
							;;

							TiB|tib )
								requiredVmDiskReal=$(echo "${voArray[3]} * 1099511627776" | bc)
							;;

							GiB|gib )
								requiredVmDiskReal=$(echo "${voArray[3]} * 1073741824" | bc)
							;;

							MiB|mib )
								requiredVmDiskReal=$(echo "${voArray[3]} * 1048576" | bc)
							;;

							KiB|kib )
								requiredVmDiskReal=$(echo "${voArray[3]} * 1024" | bc)
							;;

						esac
						if ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "grep -i zfs /proc/cmdline" ## did the potential desination node boot from ZFS today or any other Filesystem? TODO: check also for BTRFS and other weird filesystems
						then
        	                #mmmmm mmmmmm  mmmm 
    	                        #" #      #"   "
	                          ##   #mmmmm "#mmm 
	                         #"    #          "#
	                        ##mmmm #      "mmm#"
						
							## Number of things in array	0		1		2		3		4		5		6		7		8		9
							## Name of those things			name	size	used	free	expandz	frag	capacty	dedup	health	altroot
							diskArray=($(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "zpool list | grep $(grep ZFS= /proc/cmdline | cut -d' ' -f2 | sed 's/root=ZFS=//' | cut -d'/' -f1)"))

							## Remove all numbers (digits) and periods from ZFS size, so we are left with just a letter
							## find used size
							case $(${arra[2]} | sed 's/[[:digit:]].//g') in 

								P|p )
									usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
								;;

								T|t )
									usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
								;;

								G|g )
									usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
								;;

								M|m )
									usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
								;;

								K|k )
									usedDiskReal=$(echo "$(echo "${arra[2]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
								;;

							esac

							## find free size
							case $(${arra[3]} | sed 's/[[:digit:]].//g') in 

								P|p )
									availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
								;;

								T|t )
									availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
								;;

								G|g )
									availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
								;;

								M|m )
									availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
								;;

								K|k )
									availableDiskReal=$(echo "$(echo "${arra[3]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
								;;

							esac


							## find total size
							case $(${arra[1]} | sed 's/[[:digit:]].//g') in 

								P|p )
									totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1125899906842624" | bc)
								;;

								T|t )
									totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1099511627776" | bc)
								;;

								G|g )
									totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1073741824" | bc)
								;;

								M|m )
									totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1048576" | bc)
								;;

								K|k )
									totalDiskReal=$(echo "$(echo "${arra[1]}" | sed 's/[[:alpha:]]//') * 1024" | bc)
								;;

							esac


							## Now the moment we've all been waiting for: more math. Is this VO too fat for this potential destination node?
							[[ $( echo "$availableDiskReal - ($totalDiskReal * $diskMarginPercentage / 100) - $requiredVmDiskReal" |
							bc | ## actual math, before truncating down to an integer for Bash.
							cut -d'.' -f1 ) -gt 1  ]] && disk=true
						else
									 #    #                           mmmmmm  mmmm 
							 #mm   mm#mm  # mm    mmm    m mm         #      #"   "
							#" "#    #    #"  #  #"  #   #"  "        #mmmmm "#mmm 
							#   #    #    #   #  #""""   #            #          "#
							 #m#     "mm  #   #  "#mm"   #            #      "mmm#"
							
							## you're not using ZFS, so I'm assuming it's something simple like EXT or XFS.

							
							otherFileSystemAvailable=$(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "vgs --noheadings --units b --nosuffix -o lv_size,lv_dmpath --nameprefixes" |
							grep "LVM2_LV_DM_PATH='/dev/mapper/pve-data'" |
							cut -d"'" -f2)

							otherFileSystemTotal=$(ssh -o ConnectTimeout=30 -o BatchMode=yes -o HostKeyAlias=$resourcez $( grep -A 3 $resourcez /etc/pve/corosync.conf | grep ring0_addr | awk -F '(: )' '{print $2}' ) "pvdisplay --units b" | grep -A 1 -E 'VG Name.*pve' | tail -n 1 | awk '{print $3}')

							[[ $( echo "$otherFileSystemAvailable - ($otherFileSystemTotal * $diskMarginPercentage / 100) - $requiredVmDiskReal" |
							bc | ## actual math, before truncating down to an integer for Bash.
							cut -d'.' -f1 ) -gt 1  ]] && disk=true

						fi ## has enough local disk space
					
					else
						## not locally stored
						disk=true
					fi ## local disk?

				if $ram && $cpu && $disk
				then
					## ok to migrate
					printf "\n\n\n"
					/usr/bin/pvesh --nooutput create "/nodes/localhost/qemu/$qemuRemaining/migrate" --online --with-local-disks --target "$resourcez"
					break
					## break this loop looking for nodes, and continue the parent loop looking for VMs that need migration
				else
					## not enough spare resources.
					echo "$(echo "($maxRamReal * $ramFillLine - $usedRamReal) / 1048576" | bc ) MiB of available RAM is apparently not enough on $resourcez to accept QEMU $lxcRemaining with its needed $qemuMaxRam MiB of RAM."
					echo "Or maybe $resourcez was using more than $cpuFillLine% of its CPU? It was at ${resourceArray[0]} when I checked."
					echo "It could also be that the $( echo "$requiredVmDiskReal / 1073741824" | bc) GiB disk was too big for the available space of $( echo "$availableDiskReal / 1073741824" | bc) GiB."
					echo "now that I think about it:"
					if $ram ; then echo "The RAM was ok" ; fi
					if $cpu ; then echo "The CPU was ok" ; fi
					if $disk ; then echo "The Disk was ok" ; fi
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
	sleep 30
	while ps aux |
	grep -v grep |
	grep -E "((zfs )(recv)|(send))|(/usr/bin/perl /usr/sbin/pvesm import)|(ssh.*HostKeyAlias=.*ExitOnForwardFailure=yes.*-L /run.*migrate.*tunnel)|(ssh.*HostKeyAlias=.*pvesr)|(ssh.*HostKeyAlias=.*pct st)|(task UPID:.*:qmigrate:.*:root@pam:)" ||
	pvesh get /cluster/ha/status/current --noborder --noheader | grep migrate
	do
		sleep 15
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
                   #         m    m m    m       
  #mm   m mm    mmm#         "m  m" ##  ##  mmm  
 #"  #  #"  #  #" "#          #  #  # ## # #   " 
 #""""  #   #  #   #          "mm"  # "" #  """m 
  #mm"  #   #  "#m##           ##   #    # "mmm" 







## update and if updated successfully, then reboot
printf "\n\n\n"
echo "Updating, finally"
if $safeToReboot
then
	## Thanks to Robert Oliver for the apt-get install line
	## https://linuxhint.com/debian_frontend_noninteractive/
	apt-get update &&
	DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -q -y \
	-o Dpkg::Options::="--force-confdef" \
	-o Dpkg::Options::="--force-confold" &&
	shutdown -r +1

	echo "I assume everything has worked perfectly. I'm gonna reboot in one minute, but first lemme hand this back to Ansible."

	exit 0 ## passing back to Ansible
else
	echo "$(hostname) is still hosting Virtual Objects so I am not going to update or reboot."
	exit 1
fi

## go onto next node


echo "this line should be logically impossible to run, so since it has... know this script is messed up somehow. I am 
$(pwd -P)/$0)
The time is
$(date)"
exit 1
