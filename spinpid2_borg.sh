#!/usr/local/bin/bash
# spinpid2.sh for dual fan zones.
VERSION="2017-02-12"
# Run as superuser. See notes at end.

##############################################
#
#  Settings
#
##############################################

#################  LOG SETTINGS ################

# Create logfile and sends all stdout and stderr to the log, as well as to the console.
# If you want to append to existing log, add '-a' to the tee command.
LOG=/root/spinpid2.log  # Change to your desired log location/name
exec > >(tee -i $LOG) 2>&1     

# CPU output sent to a separate log for interim cycles
# To append to existing CPU log, uncomment the APPEND definition
CPU_LOG=/root/Jim/cpu.log
APPEND="-a"

#################  FAN SETTINGS ################

# Supermicro says zone 0 (FAN1-x) is for CPU/system, and
# zone 1 (FANA-x) is for Peripheral (presumably including drives)
# Reverse that here if you want (i.e, if you hook drive cooling fans
# to FAN1-4 and CPU fan to FANA, set ZONE_CPU=1 and ZONE_PER=0)
ZONE_CPU=1
ZONE_PER=0

FAN_MIN=25  # Fan minimum duty cycle (%) (to avoid stalling)
FAN_MAX=100 # Fan maximum duty cycle (%) (to avoid zombie apocalypse)

# Your measured fan RPMs at 30% duty cycle and 100% duty cycle
# RPM_CPU is for FANA if ZONE_CPU=1 or FAN1 if ZONE_CPU=0
# RPM_PER is for the other fan.
# To test, enter [sudo] ipmitool raw 0x30 0x70 0x66 1 <ZONE> <DUTY>
without the brackets; observe RPMs on IPMI GUI
RPM_CPU_30=3300   # demob's system
RPM_CPU_MAX=2000
RPM_PER_30=500
RPM_PER_MAX=7000
# RPM_CPU_30=500   # Jim's system
# RPM_CPU_MAX=1400
# RPM_PER_30=500
# RPM_PER_MAX=1400

#################  DRIVE SETTINGS ################

SP=36   #  Setpoint mean drive temperature (C)

#  Time interval for checking drives (minutes).  Drives change
#  temperature slowly; 5 minutes is probably overkill.
T=3
Kp=8    #  Proportional tunable constant (for drives)
Ki=0    #  Integral tunable constant (for drives)
Kd=60   #  Derivative tunable constant (for drives)

#################  CPU SETTINGS ################

#  Time interval for checking CPU (seconds).  10 or 15
#  may be appropriate, but your CPU may need more frequent
#  monitoring.
CPU_T=10

#  Reference temperature (C) for scaling CPU_DUTY (NOT a setpoint).
#  At and below this temperature, CPU will demand minimum
#  fan speed (FAN_MIN above).  Integer only!
CPU_REF=35
#  Scalar for scaling CPU_DUTY. Integer only!
#  CPU will demand this number of percentage points in additional
#  duty cycle for each degree of temperature above CPU_REF.
CPU_SCALE=3

##############################################
# function get_disk_name
# Get disk name from current LINE of DEVLIST
##############################################
# The awk statement works by taking $LINE as input,
# setting '(' as a _F_ield separator and taking the second field it separates
# (ie after the separator), passing that to another awk that uses
# ',' as a separator, and taking the first field (ie before the separator).
# In other words, everything between '(' and ',' is kept.

# camcontrol output for disks on HBA seems to change every version,
# so need 2 options to get ada/da disk name.
function get_disk_name {
   if [[ $LINE == *",p"* ]] ; then     # for ([a]da#,pass#)
      DEVID=$(echo $LINE | awk -F '(' '{print $2}' | awk -F ',' '{print$1}')
   else                                # for (pass#,[a]da#)
      DEVID=$(echo $LINE | awk -F ',' '{print $2}' | awk -F ')' '{print$1}')
   fi
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header {
   DATE=$(date +"%A, %b %d")
   let "SPACES = DEVCOUNT * 5 + 48"  # 5 spaces per drive
   printf "\n%-*s %3s %16s %29s \n" $SPACES "$DATE" "CPU" "New_Fan%" "New_RPM_____________________"
   echo -n "          "
   while read LINE ; do
      get_disk_name
      printf "%-5s" $DEVID
   done <<< "$DEVLIST"             # while statement works on DEVLIST
   printf "%4s %5s %6s %6s %5s %6s %3s %-7s %s %-4s %5s %5s %5s %5s %5s" "Tmax" "Tmean" "ERRc" "P" "I" "D" "TEMP" "MODE" "CPU" "PER" "FANA" "FAN1" "FAN2" "FAN3" "FAN4"
}

#################################################
# function read_fan_data
#################################################
function read_fan_data {

   # Read duty cycles, convert to decimal.
   # Duty cycle isn't provided reliably by all boards.  If necessary,
   # disable the next 5 lines, and we'll just assume it is what we last set.
   DUTY_CPU=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_CPU) # in hex with leading space
   DUTY_CPU=$((0x$(echo $DUTY_CPU)))  # strip leading space and decimalize
   DUTY_PER=$($IPMITOOL raw 0x30 0x70 0x66 0 $ZONE_PER)
   DUTY_PER=$((0x$(echo $DUTY_PER)))
   DUTY_PER_LAST=$DUTY_PER

   # Read fan mode, convert to decimal, get text equivalent.
   MODE=$($IPMITOOL raw 0x30 0x45 0) # in hex with leading space
   MODE=$((0x$(echo $MODE)))  # strip leading space and decimalize
   # Text for mode
   case $MODE in
      0) MODEt="Standard" ;;
      1) MODEt="Full" ;;
      2) MODEt="Optimal" ;;
      4) MODEt="HeavyIO" ;;
   esac

   # Get reported fan speed in RPM from sensor data repository.
   # Takes the pertinent FAN line, then 3 to 5 consecutive digits
   SDR=$($IPMITOOL sdr)
   FAN1=$(echo "$SDR" | grep "FAN1" | grep -Eo '[0-9]{3,5}')
   FAN2=$(echo "$SDR" | grep "FAN2" | grep -Eo '[0-9]{3,5}')
   FAN3=$(echo "$SDR" | grep "FAN3" | grep -Eo '[0-9]{3,5}')
   FAN4=$(echo "$SDR" | grep "FAN4" | grep -Eo '[0-9]{3,5}')
   FANA=$(echo "$SDR" | grep "FANA" | grep -Eo '[0-9]{3,5}')
}

##############################################
# function CPU_check_adjust
# Get CPU temp.  Calculate a new DUTY_CPU.
# Send to function adjust_fans.
##############################################
function CPU_check_adjust {
   CPU_TEMP=$($IPMITOOL sdr | grep "CPU Temp" | grep -Eo '[0-9]{2,5}')
   # This will break if settings have non-integers
   let DUTY_CPU=(CPU_TEMP-CPU_REF)*CPU_SCALE+FAN_MIN
      
   adjust_fans $ZONE_CPU $DUTY_CPU $DUTY_CPU_LAST

   sleep $CPU_T
        
   print_interim_CPU | tee -a $CPU_LOG >/dev/null
}

##############################################
# function DRIVES_check_adjust
# Print time on new log line.
# Go through each drive, getting and printing
# status and temp.  Calculate max and mean
# temp, then calculate PID and new duty.
# Call adjust_fans.
##############################################
function DRIVES_check_adjust {
   echo  # start new line
   # print time on each line
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   Tmax=0; Tsum=0  # initialize drive temps for new loop through drives
   i=0  # initialize count of spinning drives
   while read LINE ; do
      get_disk_name
      /usr/local/sbin/smartctl -n standby "/dev/$DEVID" > /var/tempfile
      RETURN=$?               # need to preserve because $? changes with each 'if'
      TEMP=""
      if [[ $RETURN == "0" ]] ; then
         TEMP=$(/usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" | grep "Temperature_Celsius" | grep -o "..$")
         STATE="*"  # spinning
      elif [[ $RETURN == "2" ]] ; then
         STATE="_"  # standby
      else
         STATE="?"  # state unknown
      fi
      printf "%s%2s  " "$STATE" "${TEMP:---}"
      # Update temperatures each drive; spinners only
      if [ "$STATE" == "*" ] ; then
         let "Tsum += $TEMP"
         if [[ $TEMP > $Tmax ]]; then Tmax=$TEMP; fi;
         let "i += 1"
      fi
   done <<< "$DEVLIST"

   # if no disks are spinning
   if [ $i -eq 0 ]; then
      Tmean=""; Tmax=""; P=""; D=""; ERRc=""
      DUTY_PER=$FAN_MIN
   else
      # summarize, calculate PID and print Tmax and Tmean
      if [ $ERRc == "" ]; then ERRc=0; fi  # Need value if all drives had been spun down last time
      Tmean=$(echo "scale=3; $Tsum / $i" | bc)
      ERRp=$ERRc
      ERRc=$(echo "scale=3; ($Tmean - $SP) / 1" | bc)
      # For accurate calc of D, we should round ERRc now as ERRp is
      ERRc=$(printf %0.2f $ERRc)
      P=$(echo "scale=3; ($Kp * $ERRc) / 1" | bc)
      ERR=$(echo "$ERRc * $T + $I" | bc)
      I=$(echo "scale=2; ($Ki * $ERR) / 1" | bc)
      D=$(echo "scale=3; $Kd * ($ERRc - $ERRp) / $T" | bc)
      PID=$(echo "$P + $I + $D" | bc)  # add 3 corrections

      # round for printing
      Tmean=$(printf %0.2f $Tmean)
      P=$(printf %0.2f $P)
      D=$(printf %0.2f $D)
      PID=$(printf %0.f $PID)  # must be integer for duty

      let "DUTY_PER = $DUTY_PER_LAST + $PID"
   fi

   # DIAGNOSTIC variables - uncomment for troubleshooting:
   # printf "\n DUTY_PER=%s, DUTY_PER_LAST=%s, DUTY=%s, Tmean=%s, ERRp=%s \n" "${DUTY_PER:---}" "${DUTY_PER_LAST:---}" "${DUTY:---}" "${Tmean:---}" $ERRp

   # pass to the function adjust_fans
   adjust_fans $ZONE_PER $DUTY_PER $DUTY_PER_LAST
   
   # DIAGNOSTIC variables - uncomment for troubleshooting:
   # printf "\n DUTY_PER=%s, DUTY_PER_LAST=%s, DUTY=%s, Tmean=%s, ERRp=%s \n" "${DUTY_PER:---}" "${DUTY_PER_LAST:---}" "${DUTY:---}" "${Tmean:---}" $ERRp

   # print current Tmax, Tmean
   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
}


##############################################
# function adjust_fans
# Zone, new duty, and last duty are passed as parameters
##############################################
function adjust_fans {

   # parameters passed to this function
   ZONE=$1
   DUTY=$2
   DUTY_LAST=$3

   # Don't allow duty cycle below FAN_MIN nor above 95%
   if [[ $DUTY -gt $FAN_MAX ]]; then DUTY=$FAN_MAX; fi
   if [[ $DUTY -lt $FAN_MIN ]]; then DUTY=$FAN_MIN; fi

   # Change if different from last duty, update last duty.
   if [[ $DUTY -ne $DUTY_LAST ]] || [[ FIRST_TIME -eq 1 ]]; then
      # Set new duty cycle. "echo -n ``" prevents newline generated in log
      echo -n `$IPMITOOL raw 0x30 0x70 0x66 1 $ZONE $DUTY`
      if [[ ZONE -eq ZONE_CPU ]]; then
        DUTY_CPU_LAST=$DUTY
      else
        DUTY_PER_LAST=$DUTY
      fi
   fi
}

##############################################
# function print_interim_CPU 
# Sent to a separate file by the call
# in CPU_check_adjust{}
##############################################
function print_interim_CPU {
   RPM=$(echo "$($IPMITOOL sdr)" | grep $RPM_CPU | grep -Eo '[0-9]{3,5}')
   # print time on each line
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   printf "%7s %5d %5d \n" "${RPM:----}" $CPU_TEMP $DUTY
}

#####################################################
# All this happens only at the beginning
# Initializing values, list of drives, print header
#####################################################
CPU_LOOPS=$( echo "$T * 60 / $CPU_T" | bc )  # Number of whole CPU loops per drive loop
IPMITOOL=/usr/local/bin/ipmitool
I=0; ERRc=0  # Initialize errors to 0
FIRST_TIME=1

# Alter RPM thresholds to allow some slop
RPM_CPU_30=$(echo "scale=0; 1.2 * $RPM_CPU_30 / 1" | bc)
RPM_CPU_MAX=$(echo "scale=0; 0.8 * $RPM_CPU_MAX / 1" | bc)
RPM_PER_30=$(echo "scale=0; 1.2 * $RPM_PER_30 / 1" | bc)
RPM_PER_MAX=$(echo "scale=0; 0.8 * $RPM_PER_MAX / 1" | bc)

# Get list of drives
DEVLIST1=$(/sbin/camcontrol devlist)
# Remove lines with flash drives or SSD; edit as needed
# You could use another strategy, e.g., find something in the camcontrol devlist
# output that is unique to the drives you want, for instance only WDC drives:
# if [[ $LINE != *"WDC"* ]] . . .
DEVLIST="$(echo "$DEVLIST1"|sed '/KINGSTON/d;/ADATA/d;/SanDisk/d;/OCZ/d;/LSI/d;/SSD/d')"
DEVCOUNT=$(echo "$DEVLIST" | wc -l)

# These variables hold the name of the other variables, whose
# value will be obtained by indirect reference
if [[ ZONE_PER -eq 0 ]]; then
   RPM_PER=FAN2
   RPM_CPU=FANA
else
   RPM_PER=FANA
   RPM_CPU=FAN2
fi

read_fan_data

# If mode not full, set it to avoid BMC changing duty cycle
# Need to wait a tick or it may not get next command
# "echo -n" to avoid annoying newline generated in log
if [[ MODE -ne 1 ]]; then
   echo -n `$IPMITOOL raw 0x30 0x45 1 1`
   sleep 1
fi

# Need to start drive duty at a reasonable value if fans are
# going fast or we didn't read DUTY_PER in read_fan_data
# (second test is TRUE if unset).  Also initialize DUTY_PER_LAST
if [[ ${!RPM_PER} -ge RPM_PER_MAX || -z ${DUTY_PER+x} ]]; then
   echo -n `$IPMITOOL raw 0x30 0x70 0x66 1 $ZONE_PER 50`
   DUTY_PER_LAST=50
else DUTY_PER_LAST=$DUTY_PER
fi

printf "\nKey to drive status symbols:  * spinning;  _ standby;  ? unknown               Version $VERSION \n"
print_header

# for first round of printing
CPU_TEMP=$(echo "$SDR" | grep "CPU Temp" | grep -Eo '[0-9]{2,5}')

# Initialize CPU log
printf "%s \n%s \n%17s %5s %5s \n" "$DATE" "Printed every CPU cycle" $RPM_CPU "Temp" "Duty" | tee $APPEND $CPU_LOG >/dev/null

###########################################
# Main loop through drives every T minutes
# and CPU every CPU_T seconds
###########################################
while [ 1 ] ; do
   # Print header every quarter day.  Expression removes any
   # leading 0 so it is not seen as octal
   HM=$(date +%k%M); HM=`expr $HM + 0`
   R=$(( HM % 600 ))  # remainder after dividing by 6 hours
   if (( $R < $T )); then
      print_header;
   fi
   
   DRIVES_check_adjust
   sleep 5  # Let fans equilibrate to duty before reading fans and testing for reset
   read_fan_data
   FIRST_TIME=0

   printf "%7s %6s %5s %6.6s %4s %-7s %3d %3d %6s %5s %5s %5s %5s" "${ERRc:----}" "${P:----}" $I "${D:----}" $CPU_TEMP $MODEt $DUTY_CPU $DUTY_PER "${FANA:----}" "${FAN1:----}" "${FAN2:----}" "${FAN3:----}" "${FAN4:----}"

   # See if BMC reset is needed
   # ${!RPM_CPU} gets updated value of the variable RPM_CPU points to
   # If testing on 1-zone system, comment out 1st if statement to avoid BMC reset
# 	if [[ (DUTY_CPU -ge 95 && ${!RPM_CPU} -lt RPM_CPU_MAX) || \
# 			(DUTY_CPU -le 30 && ${!RPM_CPU} -gt RPM_CPU_30) ]] ; then
# 		$IPMITOOL bmc reset cold
# 		printf "\n%s\n" "DUTY_CPU=$DUTY_CPU; RPM_CPU=${!RPM_CPU} -- I reset the BMC because RPMs were too high or low for DUTY_CPU"
# 		sleep 60
# 	fi
	if [[ (DUTY_PER -ge 95 && ${!RPM_PER} -lt RPM_PER_MAX) || \
			(DUTY_PER -le 30 && ${!RPM_PER} -gt RPM_PER_30) ]] ; then
		$IPMITOOL bmc reset cold
		printf "\n%s\n" "DUTY_PER=$DUTY_PER; RPM_PER=${!RPM_PER} -- I reset the BMC because RPMs were too high or low for DUTY_PER"
		sleep 60
	fi

   i=0
   while [ $i -lt $CPU_LOOPS ]; do
      CPU_check_adjust
      let i=i+1
   done
done

# For SuperMicro motherboards with dual fan zones.  Per Supermicro:
# Zone 0 - CPU or System fans, labelled with a number (e.g., FAN1, FAN2, etc.)
# Zone 1 - Peripheral fans, labelled with a letter (e.g., FANA, FANB, etc.)
# You can reverse the zones if you wish so zone 1 controls CPU.

# Adjusts fans based on drive and CPU temperatures.

# Mean temp among drives is maintained at a setpoint
# using a PID algorithm.  CPU temp need not and cannot be maintained
# at a setpoint, so PID is not used; instead fan duty cycle is simply
# increased with temp using reference and scale settings.

# Drives are checked and fans adjusted on a set interval, such as 5 minutes.
# Logging is done at that point.  CPU temps can spike much faster,
# so are checked at a shorter interval, such as 5-15 seconds.  CPUs with
# high TDP probably require short intervals.

# Logs:
#   - Disk status (* spinning or _ standby)
#   - Disk temperature (Celsius) if spinning
#   - Max and mean disk temperature
#   - Temperature error and PID variables
#   - CPU temperature
#   - RPM for FANA and FAN1-4 before new duty cycles
#   - Fan mode
#   - New fan duty cycle in each zone
#   - In CPU log:
#        - RPM of the first fan in CPU zone (FANA or FAN1
#        - CPU temperature
#        - new CPU duty cycle

# Includes disks on motherboard and on HBA.

#  Relation between percent duty cycle, hex value of that number,
#  and RPMs for my fans.  RPM will vary among fans, is not
#  precisely related to duty cycle, and does not matter to the script.
#  It is merely reported.
#
#  Percent      Hex         RPM
#  10         A     300
#  20        14     400
#  30        1E     500
#  40        28     600/700
#  50        32     800
#  60        3C     900
#  70        46     1000/1100
#  80        50     1100/1200
#  90        5A     1200/1300
# 100        64     1300

# Because some Supermicro boards report incorrect duty cycle,
# you have the option of not reading that, assuming it is what we set.

# Tuning suggestions
# PID tuning advice on the internet generally does not work well in this application.
# First run the script spincheck.sh and get familiar with your temperature and fan variations without any intervention.
# Choose a setpoint that is an actual observed Tmean, given the number of drives you have.  It should be the Tmean associated with the Tmax that you want.
# Set Ki=0 and leave it there.  You probably will never need it.
# Start with Kp low.  Use a value that results in a rounded correction=1 when error is the lowest value you observe other than 0  (i.e., when ERRc is minimal, Kp ~= 1 / ERRc)
# Set Kd at about Kp*10
# Get Tmean within ~0.3 degree of SP before starting script.
# Start script and run for a few hours or so.  If Tmean oscillates (best to graph it), you probably need to reduce Kd.  If no oscillation but response is too slow, raise Kd.
# Stop script and get Tmean at least 1 C off SP.  Restart.  If there is overshoot and it goes through some cycles, you may need to reduce Kd.
# If you have problems, examine PK and PD in the log and see which is messing you up.  If all else fails you can try Ki. If you use Ki, make it small, ~ 0.1 or less.

# Uses joeschmuck's smartctl method for drive status (returns 0 if spinning, 2 in standby)
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
# Other method (camcontrol cmd -a) doesn't work with HBA
