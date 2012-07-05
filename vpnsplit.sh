#!/bin/bash
# VPN Split Tunnel routing for OSX - mcowger


if [[ $EUID -ne 0 ]]; then
	echo "Please run me as root or under sudo - bailing out."
	exit 1
fi

echo "Locating Interfaces"
# Get the original Gateway
ORGGWDEFR=`netstat -nr -f inet | grep default | grep -v utun`
echo ORGGWDEFR = $ORGGWDEFR 
ORGGW=`echo $ORGGWDEFR | awk '{print \$2}'`
echo ORGGW = $ORGGW 
# Get the original Gateway Interface
ORGGWIF=`echo $ORGGWDEFR | awk '{print \$6}'`
echo ORGGWIF = $ORGGWIF 
# Get the original Gateway Network
ORGGWNW=`netstat -I $ORGGWIF -n | grep -v : | grep -v Link |grep $ORGGWIF | awk '{print \$3}'`
echo ORGGWNW = $ORGGWNW 
mask2cidr() {
	echo obase=2.$1|tr . \;|bc|tr -d 0\\n|wc -c | awk '{print $1}'
}
MASK=`system_profiler SPNetworkDataType | grep -A15 $ORGGWIF | grep "Subnet Masks" | awk '{print \$3}'`
numbits=$(mask2cidr $MASK)
NM=$MASK
IP=`ifconfig $ORGGWIF | grep netmask | awk '{print \$2}'`
l="${IP%.*}";r="${IP#*.}";n="${NM%.*}";m="${NM#*.}"
subnetid=$((${IP%%.*}&${NM%%.*})).$((${r%%.*}&${m%%.*})).$((${l##*.}&${n##*.})).$((${IP##*.}&${NM##*.}))
ORGGWNWN=$subnetid/$numbits
echo ORGGWNWN = $ORGGWNWN  
# Get the VPN tunnel interface
TUNGW=`netstat -nr -f inet | grep default | grep utun | awk '{print \$2}'`
echo TUNGW = $TUNGW



# # Put the original default Gateway back
route change default $ORGGW
# Put the original default Gateway subnet back
# Cisco AnyConnect SSL seems to need this now
# Will probably produce an error if you are using IPSEC
route change $ORGGWNWN -interface $ORGGWIF
# Let us direct all the internal only routed networks we know about
# to the VPN tunnel interface
# Non-Internet-Routed Internal


echo "...changing 10.0.0.0/8"
route add 10.0.0.0/8 -interface $TUNGW  
# Isilon
echo "...changing 74.85.160.0/19"
route add 74.85.160.0/19 -interface $TUNGW  
# Data General
echo "...changing 152.62.0.0/16"
route add 152.62.0.0/16 -interface $TUNGW   
# EMC-B2
echo "...changing 128.221.0.0/16"
route add 128.221.0.0/16 -interface $TUNGW  
# EMC-B3
echo "...changing 128.222.0.0/16"
route add 128.222.0.0/16 -interface $TUNGW   
# Legato
echo "...changing 137.69.0.0/16"
route add 137.69.0.0/16 -interface $TUNGW   
# EMC B1 
echo "...changing 168.159.0.0/16"
route add 168.159.0.0/16 -interface $TUNGW   
# VCEportal
echo "...changing 208.80.57.0/24"
route add 208.80.57.0/24 -interface $TUNGW
route add 208.80.56.11/32 -interface $TUNGW
route add 208.80.59.87/24 -interface $TUNGW
#EMC Charlotte vLabs
echo "...changeing 72.15.252.44/32"
route add 72.15.252.44/32 -interface $TUNGW
echo "...changing 204.14.232.0/21 for SFDC"
route add 204.14.232.0/21 -interface $TUNGW

route add 24.147.105.75/32 -interface $TUNGW

# Let's get rid of any ipfw meddling

echo "Adjust firewall"

sudo ipfw delete `sudo ipfw -a list | grep "deny ip from any to any" | cut -c1-5`
sudo ipfw delete set 0  

echo "Adjusting DNS resolution"
#Lets make DNS work the way we want.
# First copy the existing resolv.conf that the VPN wrote to a tmp file
cp /etc/resolv.conf /tmp/resolv.conf.$$
#Now replace it with a generic one:
cat > /etc/resolv.conf <<EOM
domain corp.emc.com
search corp.emc.com
nameserver 8.8.8.8
nameserver 8.8.4.4
EOM

#And lets put a specific resolver for EMC & Isilon in resolvers rather than specifying exceptions, because thats a PITA.
mkdir /etc/resolver > /dev/null 2>&1
cat /tmp/resolv.conf.$$ | grep nameserver > /etc/resolver/emc.com
echo "port 53" >>  /etc/resolver/emc.com
cp /etc/resolver/emc.com /etc/resolver/isilon.com

#We will have to clean this up after we drop the VPN connection because the EMC - see later for the cleverness. 
echo "Testing the connection"

# Let's do a basic test of resolution and routing
echo "...testing ping of email.emc.com"
ping -o -t 2 email.emc.com | grep "64 bytes from" > /dev/null
if [[ $? -ne 0 ]]; then
	echo "Ping of email.emc.com failed - please check it out"
fi
echo "...resolution of email.emc.com"
ping -o -t 2 email.emc.com | grep "64 bytes from 10" > /dev/null
if [[ $? -ne 0 ]]; then
	echo "We are still seeing email.emc.com's IP as the external, not internal.  You should check it out."
fi
echo "...testing ping of www.google.com"
ping -o -t 2 www.google.com | grep "64 bytes from" > /dev/null
if [[ $? -ne 0 ]]; then
	echo "Couldn't ping google.  You should check it out."
fi
echo "...testing routing to www.google.com"
traceroute -n -w 1 -m 3 www.google.com 2>&1 | tail -1 | awk '{print $2}' | grep "10.13"
if [[ $? -eq 0 ]]; then
	echo "Routing changes didn't work, we are still routing to google via VPN tunnel"
fi

#Now lets spawn off a daemon that will just constantly check if the VPN connection is still up, 
#and if its not it will delete those emc specific resolvers we created

echo "Spawning VPN Watch Daemon..."

cat > /tmp/watchvpn.sh.$$ <<EOM
TESTIP="`grep nameserver /etc/resolver/emc.com | head -1 | awk '{print $2}'`"
while :
do
	sleep 5
	ping -t 1 -c 1 \$TESTIP > /dev/null 2>&1
	if [[ \$? -ne 0 ]];
	then
		echo "VPN is failed / disconnected - dropping emc specific resolvers"
		rm -rf /etc/resolver/emc.com
		rm -rf /etc/resolver/isilon.com
		rm -rf /tmp/watchvpn.sh.*
		exit 0
	fi
done
EOM
sh /tmp/watchvpn.sh.$$ > /dev/null 2>&1 &
echo "Script Complete - Enjoy"
