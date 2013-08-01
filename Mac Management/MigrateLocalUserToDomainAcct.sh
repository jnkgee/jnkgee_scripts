#!/bin/sh
# MigrateUserHomeToDomainAcct.sh
# Modified 30 July 2013
#
# Written By - Patrick Gallagher, Emory College
#	 Modified by Rich Trouton
#	 Modified by Joshua Gee (JMG)
#
# Version 1.2 - Added the ability to check if the OS is running on Mac OS X 10.7, and run "killall opendirectoryd"
# instead of "killall DirectoryService" if it is.
#
# Version 1.3 - Added the ability to check if the OS is running on Mac OS X 10.7 or higher (including 10.8)
# and run "killall opendirectoryd"  instead of "killall DirectoryService" if it is.
#
# Version 1.4 - Changed the admin rights function from using dscl append to using dseditgroup
# 
# Version 1.5 - Code review, cleanup, documentation, and streamlining - JMG
#			  - Removed unused variables
#			  - Remove dependence on hard-coded AD account name
#			  - Exclude current user from list of users
#			  - Automate check for Domain Users Membership
#			  - Move sanity checks to before destructive actions
#			  - ONLY TESTED on 10.8.4


Version=1.5
FullScriptName=`basename "$0"`

#osvers only checks the second digit of the version i.e. 10.8.4 becomes just "8"
osvers=$(sw_vers -productVersion | awk -F. '{print $2}')

currentUser=`who | grep console | awk '{print $1}'`
listUsers="$(/usr/bin/dscl . list /Users | grep -v _ | grep -v root | grep -v uucp | grep -v amavisd | grep -v nobody | grep -v messagebus | grep -v daemon | grep -v www | grep -v Guest | grep -v xgrid | grep -v windowserver | grep -v unknown | grep -v unknown | grep -v tokend | grep -v sshd | grep -v securityagent | grep -v mailman | grep -v mysql | grep -v postfix | grep -v qtss | grep -v jabber | grep -v cyrusimap | grep -v clamav | grep -v appserver | grep -v appowner | grep -v $currentUser) FINISHED"

check4AD=`/usr/bin/dscl localhost -list . | grep "Active Directory"`

########### Functions ###########
	RunAsRoot()
	# This function ensures that the script runs with superuser priveleges.  If not, it forces authentication and restarts itself.
	{
        ##  Pass in the full path to the executable as $1
        if [[ "${USER}" != "root" ]] ; then
                echo
                echo "***  This application must be run as root.  Please authenticate below.  ***"
                echo
                sudo "${1}" && exit 0
        fi
	}

	RefreshDirectoryServices()
	{
		echo "Refreshing Directory Services connection"
		if [[ ${osvers} -ge 7 ]]; then
			/usr/bin/killall opendirectoryd
		else
			/usr/bin/killall DirectoryService
		fi
			
		# Wait for Directory Services to restart
		sleep 20
	}

######### Begin main code ##########

clear
echo "********* Running $FullScriptName Version $Version *********"

# If the machine is not bound to AD, then there's no purpose going any further. 
if [ "${check4AD}" != "Active Directory" ]; then
	echo "This machine is not bound to Active Directory.\nPlease bind to AD first. "; exit 1
fi


RunAsRoot "${0}"

until [ "$user" == "FINISHED" ]; do

	printf "%b" "\a\n\nSelect a user to convert or select FINISHED:\n" >&2
	select user in $listUsers; do

		if [ "$user" = "FINISHED" ]; then
			echo "Finished converting users to AD"
			break
		elif [ -n "$user" ]; then
			
			# Never try to convert the logged in user.  This shouldn't happen since we don't list the current user, so this is just a sanity check.
			if [ "$currentUser" == "$user" ]; then
				echo "This user is logged in.\nPlease log this user out and log in as another admin"
				exit 1
			fi

			# Get Network Account to Migrate to
			read -p "Please enter the AD account for this user in the form DOMAIN\\Username: " -r adusername

			adsimplename=`echo $adusername | awk -F\\\\ '{print $NF}'`

			# Verify both AD Connection and User existence
			if [[ -n "`/usr/bin/id $adusername | awk '/Domain Users/ {print $0}'`" ]] && [[ -n $adsimplename ]]; then
        		echo "Great! It looks like this Mac is communicating with AD correctly and the users exists. \nThis script will migrate local user $user to AD User $adusername."
			else
        		echo "AD User lookup failed. AD is not configured correctly or AD account does not exist. Exiting the script."
				exit 0
			fi

			# If local username and network username don't match, 
			# check to make sure there isn't an existing home directory for the network username.
			# If they do match, the home directory will be backed up during this process.
			if [[ "$user" != "$adsimplename" ]] && [[ -f /Users/$adsimplename ]]; then
				echo "Error: A home folder already exists for $adsimplename.\nYou should backup and/or remove this home folder before proceeding."
				exit 0
			fi

			# Get the local user's guid, home folder, and group membership
			guid="$(/usr/bin/dscl . -read "/Users/$user" GeneratedUID | /usr/bin/awk '{print $NF;}')"
			userHome=`/usr/bin/dscl . read /Users/$user NFSHomeDirectory | cut -c 19-`
			lgroups="$(/usr/bin/id -Gn $user)"

			# If there have been no errors, and if dscl also reports group memberships (Why do we check this?)
			if [[ $? -eq 0 ]] && [[ -n "$(/usr/bin/dscl . -search /Groups GroupMembership "$user")" ]]; then 

				# Delete local user from each group it is a member of
				for lg in $lgroups; 
					do
						/usr/bin/dscl . -delete /Groups/${lg} GroupMembership $user >&/dev/null
					done
			fi

			# Delete the primary group if it exists (doesn't appear to exist in 10.8)
			if [[ -n "$(/usr/bin/dscl . -search /Groups name "$user")" ]]; then
  				/usr/sbin/dseditgroup -o delete "$user"
			fi

			# Delete Password hash if it exists (on 10.8 seems to only exist for Mobile Accounts, but I can't confirm this from documentation)
			if [[ -f "/private/var/db/shadow/hash/$guid" ]]; then
 				/bin/rm -f /private/var/db/shadow/hash/$guid
			fi

			# Archive the local user's home folder and delete the local user
			echo "Backing up Home Directory for local user: $user to /Users/old_$user\n"
			/bin/mv $userHome /Users/old_$user

			echo "Deleting local user: $user"
			/usr/bin/dscl . -delete "/Users/$user"

			RefreshDirectoryServices

			# Confirm that Directory Services is back up? or Possibly force to reconnect/refresh
			/usr/bin/id $adsimplename

			# Double check the destination Home Directory to avoid over-write/merge issues
			if [ -f /Users/$adsimplename ]; then
				echo "Error: A home folder already exists for $adsimplename, and the local user has already been deleted. This must be repaired by hand."
				exit 1
			else
				echo "Restoring saved Home Directory to /Users/$adsimplename\n"
				/bin/mv /Users/old_$user /Users/$adsimplename
				/usr/sbin/chown -R ${adsimplename} /Users/$adsimplename
					
				echo "Creating Mobile Account for $adsimplename"			
				echo "Please note that vproc_swap_integer errors appear to be benign and do not indicate a failure.\n\n"
				/System/Library/CoreServices/ManagedClient.app/Contents/Resources/createmobileaccount -n $adsimplename -h /Users/$adsimplename
			fi


			# NOTE: I attempted this as below and also with "/usr/bin/dscl . -append /Groups/admin".  
			# The user gets added to this group, but not granted full administrator rights.
			# Since I couldn't find documentation on this problem, I left it as a manual step.

#			echo "Do you want to give the $adsimplename account admin rights?"
#			select yn in "Yes" "No"; do
#    			case $yn in
#        			Yes) /usr/sbin/dseditgroup -o edit -a $adsimplename -t user admin; echo "Admin rights given to this account"; break;;
#        			No ) echo "No admin rights given"; break;;
#    			esac
#			done
			
			RefreshDirectoryServices

			echo "Script Complete. Local user: $user migrated to Mobile Account: $adusername"
			echo "\nNote: Making a domain user an admin seems to be unreliable from a script."
			echo "Please use the GUI to assign these permissions if required.\n\n"
			echo "\nAlso Note: The user will need to use their old password to update their keychain on first login."

			break
		else
			echo "Invalid selection!"
		fi
	done
done

