#!/bin/bash

# ------------------------------------------------------------------------------
# Configure a basic firewall,
# by generating a set of iptables rules (ipv4 and ipv6),
# and saving those to /etc/firewall/ipv4 and /etc/firewall/ipv6 .
# The accompanying script /etc/rc.d/rc.firewall will restore these configs.
#
# This script and rc.firewall are part of liveslak,
# a project by Eric Hameleers, see https://download.liveslak.org/
#
# Iptables ruleset handling courtesy of Easy Firewall Generator for IPTables,
# Copyright 2002 Timothy Scott Morizot
# ------------------------------------------------------------------------------

# The script accepts one parameter: the target filesystem:
DESTDIR="$1"

# This tmp directory is only writable by root:
TMP=${TMP:-"/var/log/setup/tmp"}
if [ ! -d $TMP ]; then
  mkdir -p $TMP
fi

# The script defaults to curses dialog but Xdialog is a good alternative:
DIALOG=${DIALOG:-"dialog"}

# The iptables tools we use:
IPT="/usr/sbin/iptables"
IP6T="/usr/sbin/ip6tables"
IPTS="/usr/sbin/iptables-save"
IP6TS="/usr/sbin/ip6tables-save"
IPTR="/usr/sbin/iptables-restore"
IP6TR="/usr/sbin/ip6tables-restore"

# Localhost Interface
LO_IFACE="lo"
LO_IP="127.0.0.1"
LO_IP6="::1"

# The default gateway device will be our primary candidate to firewall:
GWDEV=$(/sbin/ip route show |grep ^default |cut -d' ' -f5)

# Generate a list of network devices, minus the default gateway and loopback:
AVAILDEV=$(ls --indicator-style=none /sys/class/net/ |sed -e "s/${GWDEV}//" -e "s/lo//")

# Store all network interfaces in an associative array:
declare -A NETDEVARR
NETDEVARR=( [$GWDEV]=on )
for INDEV in $AVAILDEV ; do NETDEVARR+=( [$INDEV]=off ) ; done
unset INDEV

# Store network services in another array:
declare -A SERVARR=( 
  ['SSH']=off
  ['RSYNC']=off
  ['GIT']=off
  ['HTTP']=off
  ['HTTPS']=off
  ['SMTP']=off
  ['SMPTS']=off
  ['IMAP']=off
  ['IMAPS']=off
  ['NTP']=off
)

# Store the list of custom ports/port ranges:
CUSTOM_TCP_LIST=""
CUSTOM_UDP_LIST=""

# Will we auto-configure a restrictive firewall?
AUTOCONFIG="YES"

# User pressing ESC will change the default choice in the 1st dialog:
DEFAULTNO=""

# Loop over the configuration until the user is done:
MAINSELECT="start"
while [ "$MAINSELECT" != "done" ]; do
  if [ "$MAINSELECT" = "start" ]; then
    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "CONFIGURE FIREWALL" ${DEFAULTNO} \
      --yesno "Would you like to protect the system with a basic firewall?\n\n\
You can either block all external connections,
or you can expose specific TCP/UDP ports.\n\n\
DHCP will never be blocked." 11 68
    if [ $? != 0 ]; then
      # Not needed.
      exit 0
    else
      DEFAULTNO=""
    fi
    MAINSELECT="devices"
  fi

  if [ "$MAINSELECT" = "devices" ]; then
    # Populate the network device checklist for the dialog:
    NETDEVLIST="$(for I in ${!NETDEVARR[@]};do echo $I ${NETDEVARR[$I]};done)"
    unset I
    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "PICK INTERFACES" \
      --stdout --separate-output \
      --no-items \
      --ok-label "Next" --no-cancel --extra-button --extra-label "Previous" \
      --checklist "\
Select the network interface(s) exposed to the outside world.\n\
Your default gateway is pre-selected.\n\
Un-selected interfaces will accept all incoming traffic." 13 68 5 $NETDEVLIST \
    > $TMP/SeTnics
    RETVAL=$?
    # Zero out the array values and re-enable only the ones we got returned:
    for INDEV in ${!NETDEVARR[@]} ; do NETDEVARR[$INDEV]=off ; done
    for INDEV in $(cat $TMP/SeTnics) ; do  NETDEVARR[$INDEV]=on ; done
    unset INDEV
    case "$RETVAL" in
      0) MAINSELECT="autoselect" ;;
      3) MAINSELECT="start" ;;
      *) MAINSELECT="start" ; DEFAULTNO="--defaultno" ;;
    esac
    rm -f $TMP/SeTnics
  fi

  if [ "$MAINSELECT" = "autoselect" ]; then
    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "ALL CLOSED?" \
      --yesno "Do you want to block all incoming external connections?\n\
If 'no', then you will be able to specify ports that need to be open." 7 68
    RETVAL=$?
    case "$RETVAL" in
      0) AUTOCONFIG="YES"
         MAINSELECT="done" ;;
      1) AUTOCONFIG="NO"
         MAINSELECT="services" ;;
      *) MAINSELECT="start" ; DEFAULTNO="--defaultno" ;;
    esac
  fi

  if [ "$MAINSELECT" = "services" ]; then
    # Populate the services checklist for the dialog:
    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "OPEN PORTS" \
      --stdout --separate-output \
      --ok-label "Next" --no-cancel --extra-button --extra-label "Previous" \
      --checklist "\
Select the service ports you want to remain open for the outside world.\n\
You can enter more ports or portranges in the next dialog." 19 68 13 \
SSH    'SSH (port 22)'                             ${SERVARR['SSH']} \
RSYNC  'RSYNC (port 873)'                          ${SERVARR['RSYNC']} \
GIT    'GIT (port 9418)'                           ${SERVARR['GIT']} \
HTTP   'Web Server (HTTP port 80)'                 ${SERVARR['HTTP']} \
HTTPS  'Secure Web Server (HTTPS port 443)'        ${SERVARR['HTTPS']} \
SMTP   'Receiving Email (SMTP port 25)'            ${SERVARR['SMTP']} \
SMTPS  'Secure Receiving Email (SMPTS port 587)'   ${SERVARR['SMPTS']} \
IMAP   'IMAP Email Server (IMAP port 143)'         ${SERVARR['IMAP']} \
IMAPS  'Secure IMAP Email Server (IMAPS port 993)' ${SERVARR['IMAPS']} \
NTP    'Time Server (NTP port 123)'                ${SERVARR['NTP']} \
    > $TMP/SeTservices
    RETVAL=$?
    # Zero out the array values and re-enable only the ones we got returned:
    for INSRV in ${!SERVARR[@]} ; do SERVARR[$INSRV]=off ; done
    for INSRV in $(cat $TMP/SeTservices) ; do  SERVARR[$INSRV]=on ; done
    unset INSRV
    case $RETVAL in
      0) MAINSELECT="customports" ;;
      3) MAINSELECT="autoselect" ;;
      *) MAINSELECT="start" ; DEFAULTNO="--defaultno" ;;
    esac
    rm -f $TMP/SeTservices
  fi

  if [ "$MAINSELECT" = "customports" ]; then
    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "CUSTOM PORTS" \
      --stdout \
      --ok-label "Next" --no-cancel --extra-button --extra-label "Previous" \
      --form "\
Enter additional ports or port ranges.\n\
Port ranges consist of two numbers separated by a colon (example: 3000:3011).\n\
Separate multiple entries with commas,\n\
for example: 22,465,3000:3011,6660:6669,7000" \
13 68 2 \
"TCP ports/portranges:"  1 1 "$CUSTOM_TCP_LIST" 1 25 40 0 \
"UDP ports/portranges:"  2 1 "$CUSTOM_UDP_LIST" 2 25 40 0 \
    > $TMP/SeTcustomports
    RETVAL=$?
    CUSTOM_TCP_LIST=$(head -1 $TMP/SeTcustomports)
    CUSTOM_UDP_LIST=$(tail -1 $TMP/SeTcustomports)
    case $RETVAL in
      0) MAINSELECT="confirm" ;;
      3) MAINSELECT="services" ;;
      *) MAINSELECT="start" ; DEFAULTNO="--defaultno" ;;
    esac
    rm -f $TMP/SeTcustomports
  fi

  if [ "$MAINSELECT" = "confirm" ]; then
    # Collect all service ports that need to be remotely accessible.
    # TCP:
    TCP_LIST=""
    if [ "${SERVARR['HTTP']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 80"
    fi
    if [ "${SERVARR['HTTPS']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 443"
    fi
    if [ "${SERVARR['SMTP']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 25"
    fi
    if [ "${SERVARR['SMTPS']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 587"
    fi
    if [ "${SERVARR['IMAP']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 143"
    fi
    if [ "${SERVARR['IMAPS']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 993"
    fi
    if [ "${SERVARR['SSH']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 22"
    fi
    if [ "${SERVARR['GIT']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 9418"
    fi
    if [ "${SERVARR['RSYNC']}" = "on" ]; then
      TCP_LIST="$TCP_LIST 873"
    fi
    TCP_LIST=$(echo $TCP_LIST | sed 's/^ *//g' | tr ' ' ',')
    # UDP:
    UDP_LIST=""
    if [ "${SERVARR['NTP']}" = "on" ]; then
      UDP_LIST="$UDP_LIST 123"
    fi
    if [ "${SERVARR['RSYNC']}" = "on" ]; then
      UDP_LIST="$UDP_LIST 873"
    fi
    UDP_LIST=$(echo $UDP_LIST | sed 's/^ *//g' | tr ' ' ',')

    TCP_LIST=$(echo $TCP_LIST $CUSTOM_TCP_LIST | sed 's/^ *//g' | tr ' ' ',')
    UDP_LIST=$(echo $UDP_LIST $CUSTOM_UDP_LIST | sed 's/^ *//g' | tr ' ' ',')
    DEV_LIST=$(for INDEV in ${!NETDEVARR[@]} ; do if [ "${NETDEVARR[$INDEV]}" = "on" ]; then echo -n $INDEV" " ; fi ; done)

    ${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
      --title "CONFIRM CONFIGURATION" \
      --yes-label "Generate" --no-label "Redo" \
      --yesno "These are the ports you configured. Are you OK with them?\n\n\
Press 'Generate' to generate the firewall configuration.\n\
Else press 'Redo' to re-do the setup.\n\n\
Firewalled interface(s): $DEV_LIST \n\
TCP Ports: $TCP_LIST \n\
UDP Ports: $UDP_LIST" 12 68
    RETVAL=$?
    case $RETVAL in
      0) MAINSELECT="done" ;;
      1) MAINSELECT="devices" ;;
      *) MAINSELECT="start" ; DEFAULTNO="--defaultno" ;;
    esac
  fi

done

# ------------------------------------------------------------------------------
# End of configuration, let's get to work.
# ------------------------------------------------------------------------------

#
# Flush Any Existing Rules or Chains
#

${DIALOG} --backtitle "@UDISTRO@ (@LIVEDE@) Basic Firewall Setup" \
  --infobox "Configuring your firewall ..." 4 68

# Reset Default Policies
$IPT -P INPUT ACCEPT
$IPT -P FORWARD ACCEPT
$IPT -P OUTPUT ACCEPT
$IPT -t nat -P PREROUTING ACCEPT
$IPT -t nat -P POSTROUTING ACCEPT
$IPT -t nat -P OUTPUT ACCEPT
$IPT -t mangle -P PREROUTING ACCEPT
$IPT -t mangle -P OUTPUT ACCEPT
#
$IP6T -P INPUT ACCEPT
$IP6T -P FORWARD ACCEPT
$IP6T -P OUTPUT ACCEPT
$IP6T -t mangle -P PREROUTING ACCEPT
$IP6T -t mangle -P OUTPUT ACCEPT

# Flush all rules
$IPT -F
$IPT -t nat -F
$IPT -t mangle -F
#
$IP6T -F
$IP6T -t mangle -F

# Erase all non-default chains
$IPT -X
$IPT -t nat -X
$IPT -t mangle -X
#
$IP6T -X
$IP6T -t mangle -X

#
# Rules Configuration
#
# Filter Table
#

# Set Policies
$IPT -P INPUT DROP
$IPT -P OUTPUT DROP
$IPT -P FORWARD DROP
#
$IP6T -P INPUT DROP
$IP6T -P OUTPUT DROP
$IP6T -P FORWARD DROP

#
# User-Specified Chains
#
# Create user chains to reduce the number of rules each packet must traverse.
#

# Create a chain to filter INVALID packets
$IPT -N bad_packets
$IP6T -N bad_packets

# Create another chain to filter bad tcp packets
$IPT -N bad_tcp_packets
$IP6T -N bad_tcp_packets

# Create separate chains for icmp, tcp (incoming and outgoing),
# and incoming udp packets.
$IPT -N icmp_packets
$IP6T -N icmp_packets

# Used for UDP packets inbound from the Internet
$IPT -N udp_inbound
$IP6T -N udp_inbound

# Used to block outbound UDP services from internal network
# Default to allow all
$IPT -N udp_outbound
$IP6T -N udp_outbound

# Used to allow inbound services if desired
# Default fail except for established sessions
$IPT -N tcp_inbound
$IP6T -N tcp_inbound

# Used to block outbound services from internal network
# Default to allow all
$IPT -N tcp_outbound
$IP6T -N tcp_outbound

#
# Populate User Chains
#
# bad_packets chain
#

# Drop INVALID packets immediately
$IPT -A bad_packets -p ALL -m state --state INVALID -j DROP
$IP6T -A bad_packets -p ALL -m state --state INVALID -j DROP

# Then check the tcp packets for additional problems
$IPT -A bad_packets -p tcp -j bad_tcp_packets
$IP6T -A bad_packets -p tcp -j bad_tcp_packets

# All good, so return
$IPT -A bad_packets -p ALL -j RETURN
$IP6T -A bad_packets -p ALL -j RETURN

# bad_tcp_packets chain
#
# All tcp packets will traverse this chain.
# Every new connection attempt should begin with
# a syn packet.  If it doesn't, it is likely a
# port scan.  This drops packets in state
# NEW that are not flagged as syn packets.
$IPT -A bad_tcp_packets -p tcp ! --syn -m state --state NEW -j DROP
$IP6T -A bad_tcp_packets -p tcp ! --syn -m state --state NEW -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags ALL NONE -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags ALL NONE -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags ALL ALL -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags ALL ALL -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags ALL FIN,URG,PSH -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags ALL SYN,RST,ACK,FIN,URG -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
$IPT -A bad_tcp_packets -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
$IP6T -A bad_tcp_packets -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP

# All good, so return
$IPT -A bad_tcp_packets -p tcp -j RETURN
$IP6T -A bad_tcp_packets -p tcp -j RETURN

# icmp_packets chain
#
# This chain is for inbound (from the Internet) icmp packets only.
# Type 8 (Echo Request) is not accepted by default
# Enable it if you want remote hosts to be able to reach you.
# 11 (Time Exceeded) is the only one accepted
# that would not already be covered by the established
# connection rule.  Applied to INPUT on the external interface.
# 
# See: http://www.ee.siue.edu/~rwalden/networking/icmp.html
# for more info on ICMP types.
#
# Note that the stateful settings allow replies to ICMP packets.
# These rules allow new packets of the specified types.

# ICMP packets should fit in a Layer 2 frame, thus they should
# never be fragmented.  Fragmented ICMP packets are a typical sign
# of a denial of service attack.
$IPT -A icmp_packets --fragment -p icmp -j DROP
$IP6T -A icmp_packets -p ipv6-icmp -m ipv6header --header frag --soft -j DROP

# Echo - uncomment to allow your system to be pinged.
# $IPT -A icmp_packets -p icmp -s 0/0 --icmp-type 8 -j ACCEPT
# $IP6T -A icmp_packets -p ipv6-icmp -s 0/0 --icmpv6-type 8 -j ACCEPT

# By default, however, drop pings without logging. Blaster
# and other worms have infected systems blasting pings.
# Comment the line below if you want pings logged, but it
# will likely fill your logs.
$IPT -A icmp_packets -p icmp -s 0/0 --icmp-type 8 -j DROP
$IP6T -A icmp_packets -p ipv6-icmp -s 0/0 --icmpv6-type 8 -j DROP

# Time Exceeded
$IPT -A icmp_packets -p icmp -s 0/0 --icmp-type 11 -j ACCEPT
$IP6T -A icmp_packets -p ipv6-icmp -s 0/0 --icmpv6-type 11 -j ACCEPT

# Not matched, so return so it will be logged
$IPT -A icmp_packets -p icmp -j RETURN
$IP6T -A icmp_packets -p ipv6-icmp -j RETURN

# TCP & UDP
# Identify ports at:
#    http://www.chebucto.ns.ca/~rakerman/port-table.html
#    http://www.iana.org/assignments/port-numbers

# udp_inbound chain
#
# This chain describes the inbound UDP packets it will accept.
# It's applied to INPUT on the external or Internet interface.
# Note that the stateful settings allow replies.
# These rules are for new requests.
# It drops netbios packets (windows) immediately without logging.

# Drop netbios calls
# Please note that these rules do not really change the way the firewall
# treats netbios connections.  Connections from the localhost and
# internal interface (if one exists) are accepted by default.
# Responses from the Internet to requests initiated by or through
# the firewall are also accepted by default.  To get here, the
# packets would have to be part of a new request received by the
# Internet interface.  You would have to manually add rules to
# accept these.  I added these rules because some network connections,
# such as those via cable modems, tend to be filled with noise from
# unprotected Windows machines.  These rules drop those packets
# quickly and without logging them.  This prevents them from traversing
# the whole chain and keeps the log from getting cluttered with
# chatter from Windows systems.
$IPT -A udp_inbound -p udp -s 0/0 --dport 137 -j DROP
$IPT -A udp_inbound -p udp -s 0/0 --dport 138 -j DROP
$IP6T -A udp_inbound -p udp -s 0/0 --dport 137 -j DROP
$IP6T -A udp_inbound -p udp -s 0/0 --dport 138 -j DROP

# Ident requests (Port 113) must have a REJECT rule rather than the
# default DROP rule.  This is the minimum requirement to avoid
# long delays while connecting.  Also see the tcp_inbound rule.
$IPT -A udp_inbound -p udp -s 0/0 --dport 113 -j REJECT
$IP6T -A udp_inbound -p udp -s 0/0 --dport 113 -j REJECT

# A more sophisticated configuration could accept the ident requests.
# $IPT -A udp_inbound -p udp -s 0/0 --dport 113 -j ACCEPT
# $IP6T -A udp_inbound -p udp -s 0/0 --dport 113 -j ACCEPT

# IPv4 only:
# Allow DHCP client request packets inbound from external network
$IPT -A udp_inbound -p udp -s 0/0 --source-port 68 --dport 67 \
   -j ACCEPT
# Dynamic Address
# If DHCP, the initial request is a broadcast. The response
# doesn't exactly match the outbound packet.  This explicitly
# allow the DHCP ports to alleviate this problem.
# If you receive your dynamic address by a different means, you
# can probably comment this line.
$IPT -A udp_inbound -p udp -s 0/0 --source-port 67 --dport 68 \
   -j ACCEPT

# Open the custom UDP ports if they have been configured:
if [ -n "$UDP_LIST" ]; then 
  $IPT -A INPUT -p udp -m multiport --dport $UDP_LIST -j ACCEPT
  $IP6T -A INPUT -p udp -m multiport --dport $UDP_LIST -j ACCEPT
fi

# Not matched, so return for logging
$IPT -A udp_inbound -p udp -j RETURN
$IP6T -A udp_inbound -p udp -j RETURN

# udp_outbound chain
#
# This chain is used with a private network to prevent forwarding for
# UDP requests on specific protocols.  Applied to the FORWARD rule from
# the internal network.  Ends with an ACCEPT


# No match, so ACCEPT
$IPT -A udp_outbound -p udp -s 0/0 -j ACCEPT
$IP6T -A udp_outbound -p udp -s 0/0 -j ACCEPT

# tcp_inbound chain
#
# This chain is used to allow inbound connections to the
# system/gateway.  Use with care.  It defaults to none.
# It's applied on INPUT from the external or Internet interface.

# Ident requests (Port 113) must have a REJECT rule rather than the
# default DROP rule.  This is the minimum requirement to avoid
# long delays while connecting.  Also see the tcp_inbound rule.
$IPT -A tcp_inbound -p tcp -s 0/0 --dport 113 -j REJECT
$IP6T -A tcp_inbound -p tcp -s 0/0 --dport 113 -j REJECT

# A more sophisticated configuration could accept the ident requests.
# $IPT -A tcp_inbound -p tcp -s 0/0 --dport 113 -j ACCEPT
# $IP6T -A tcp_inbound -p tcp -s 0/0 --dport 113 -j ACCEPT

# Open the requested TCP service ports if they have been configured:
if [ -n "$TCP_LIST" ]; then 
  $IPT -A INPUT -p tcp -m multiport --dport $TCP_LIST -j ACCEPT
  $IP6T -A INPUT -p tcp -m multiport --dport $TCP_LIST -j ACCEPT
fi

# Not matched, so return so it will be logged
$IPT -A tcp_inbound -p tcp -j RETURN
$IP6T -A tcp_inbound -p tcp -j RETURN

# tcp_outbound chain
#
# This chain is used with a private network to prevent forwarding for
# requests on specific protocols.  Applied to the FORWARD rule from
# the internal network.  Ends with an ACCEPT

# No match, so ACCEPT
$IPT -A tcp_outbound -p tcp -s 0/0 -j ACCEPT
$IP6T -A tcp_outbound -p tcp -s 0/0 -j ACCEPT

#
# INPUT Chain
#
# Allow all on localhost interface
$IPT -A INPUT -p ALL -i $LO_IFACE -j ACCEPT
$IP6T -A INPUT -p ALL -i $LO_IFACE -j ACCEPT

# Allow all on other internal interfaces:
for INDEV in ${!NETDEVARR[@]} ; do
  if [ "${NETDEVARR[$INDEV]}" = "off" ] ; then
    $IPT -A INPUT -p ALL -i $INDEV -j ACCEPT
    $IP6T -A INPUT -p ALL -i $INDEV -j ACCEPT
  fi
done
unset INDEV

# Drop bad packets
$IPT -A INPUT -p ALL -j bad_packets
$IP6T -A INPUT -p ALL -j bad_packets

# DOCSIS compliant cable modems
# Some DOCSIS compliant cable modems send IGMP multicasts to find
# connected PCs.  The multicast packets have the destination address
# 224.0.0.1.  You can accept them.  If you choose to do so,
# Uncomment the rule to ACCEPT them and comment the rule to DROP
# them  The firewall will drop them here by default to avoid
# cluttering the log.  The firewall will drop all multicasts
# to the entire subnet (224.0.0.1) by default.  To only affect
# IGMP multicasts, change '-p ALL' to '-p 2'.  Of course,
# if they aren't accepted elsewhere, it will only ensure that
# multicasts on other protocols are logged.
# Drop them without logging.
$IPT -A INPUT -p ALL -d 224.0.0.1 -j DROP
# The rule to accept the packets.
# $IPT -A INPUT -p ALL -d 224.0.0.1 -j ACCEPT

# Inbound Internet Packet Rules

for INDEV in ${!NETDEVARR[@]} ; do
  if [ "${NETDEVARR[$INDEV]}" = "on" ] ; then
    # Accept Established Connections
    $IPT -A INPUT -p ALL -i $INDEV -m state --state ESTABLISHED,RELATED \
         -j ACCEPT
    $IP6T -A INPUT -p ALL -i $INDEV -m state --state ESTABLISHED,RELATED \
         -j ACCEPT

    # Route the rest to the appropriate user chain
    $IPT -A INPUT -p tcp -i $INDEV -j tcp_inbound
    $IP6T -A INPUT -p tcp -i $INDEV -j tcp_inbound
    $IPT -A INPUT -p udp -i $INDEV -j udp_inbound
    $IP6T -A INPUT -p udp -i $INDEV -j udp_inbound
    $IPT -A INPUT -p icmp -i $INDEV -j icmp_packets
    $IP6T -A INPUT -p ipv6-icmp -i $INDEV -j icmp_packets
  fi
done
unset INDEV

# Drop without logging broadcasts that get this far.
# Cuts down on log clutter.
# Comment this line if testing new rules that impact
# broadcast protocols.
$IPT -A INPUT -m pkttype --pkt-type broadcast -j DROP
$IP6T -A INPUT -m pkttype --pkt-type broadcast -j DROP

# Log packets that still don't match
$IPT -A INPUT -m limit --limit 3/minute --limit-burst 3 -j LOG \
    --log-prefix "INPUT packet died: "
$IP6T -A INPUT -m limit --limit 3/minute --limit-burst 3 -j LOG \
    --log-prefix "INPUT packet ipv6 died: "

#
# FORWARD Chain
#
# Used if forwarding for a private network

#
# OUTPUT Chain
#
# Generally trust the firewall on output

# However, invalid icmp packets need to be dropped
# to prevent a possible exploit.
$IPT -A OUTPUT -m state -p icmp --state INVALID -j DROP
$IP6T -A OUTPUT -m state -p ipv6-icmp --state INVALID -j DROP

# Localhost
$IPT -A OUTPUT -p ALL -s $LO_IP -j ACCEPT
$IP6T -A OUTPUT -p ALL -s $LO_IP6 -j ACCEPT
$IPT -A OUTPUT -p ALL -o $LO_IFACE -j ACCEPT
$IP6T -A OUTPUT -p ALL -o $LO_IFACE -j ACCEPT

# Allow all on other internal interfaces:
for OUTDEV in ${!NETDEVARR[@]} ; do
  if [ "${NETDEVARR[$OUTDEV]}" = "off" ] ; then
    $IPT -A OUTPUT -p ALL -o $OUTDEV -j ACCEPT
    $IP6T -A OUTPUT -p ALL -o $OUTDEV -j ACCEPT
  fi
done
unset OUTDEV

# To internet
for OUTDEV in ${!NETDEVARR[@]} ; do
  if [ "${NETDEVARR[$OUTDEV]}" = "on" ] ; then
    $IPT -A OUTPUT -p ALL -o $OUTDEV -j ACCEPT
    $IP6T -A OUTPUT -p ALL -o $OUTDEV -j ACCEPT
  fi
done

# Log packets that still don't match
$IPT -A OUTPUT -m limit --limit 3/minute --limit-burst 3 -j LOG \
    --log-prefix "OUTPUT packet died: "
$IP6T -A OUTPUT -m limit --limit 3/minute --limit-burst 3 -j LOG \
    --log-prefix "OUTPUT packet ipv6 died: "

#
# nat table
#
# The nat table is where network address translation occurs if there
# is a private network.  If the gateway is connected to the Internet
# with a static IP, snat is used.  If the gateway has a dynamic address,
# masquerade must be used instead.  There is more overhead associated
# with masquerade, so snat is better when it can be used.
# The nat table has a builtin chain, PREROUTING, for dnat and redirects.
# Another, POSTROUTING, handles snat and masquerade.

#
# PREROUTING chain
#

#
# POSTROUTING chain
#


#
# mangle table
#
# The mangle table is used to alter packets.  It can alter or mangle them in
# several ways.  For the purposes of this generator, we only use its ability
# to alter the TTL in packets.  However, it can be used to set netfilter
# mark values on specific packets.  Those marks could then be used in another
# table like filter, to limit activities associated with a specific host, for
# instance.  The TOS target can be used to set the Type of Service field in
# the IP header.  Note that the TTL target might not be included in the
# distribution on your system.  If it is not and you require it, you will
# have to add it.  That may require that you build from source.

# Save the firewall configuration so that 'rc.firewall' can load it:
mkdir -p $DESTDIR/etc/firewall
${IPTS} > $DESTDIR/etc/firewall/ipv4
${IP6TS} > $DESTDIR/etc/firewall/ipv6

