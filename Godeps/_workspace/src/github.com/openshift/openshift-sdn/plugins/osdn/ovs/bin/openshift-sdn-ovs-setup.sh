#!/bin/bash

set -ex

lock_file=/var/lock/openshift-sdn.lock
local_subnet_gateway=$1
local_subnet_cidr=$2
local_subnet_mask_len=$3
cluster_network_cidr=$4
service_network_cidr=$5
mtu=$6
multitenant=$7
printf 'Container network is "%s"; local host has subnet "%s", mtu "%d" and gateway "%s".\n' "${cluster_network_cidr}" "${local_subnet_cidr}" "${mtu}" "${local_subnet_gateway}"
TUN=tun0

# Synchronize code execution with a file lock.
function lockwrap() {
    (
    flock 200
    "$@"
    ) 200>${lock_file}
}

function docker_network_config() {
    if [ -z "${DOCKER_NETWORK_OPTIONS}" ]; then
	DOCKER_NETWORK_OPTIONS="-b=lbr0 --mtu=${mtu}"
    fi

    local conf=/run/openshift-sdn/docker-network
    case "$1" in
	check)
	    if ! grep -q -s "DOCKER_NETWORK_OPTIONS='${DOCKER_NETWORK_OPTIONS}'" $conf; then
		return 1
	    fi
	    return 0
	    ;;

	update)
		mkdir -p $(dirname $conf)
		cat <<EOF > $conf
# This file has been modified by openshift-sdn.

DOCKER_NETWORK_OPTIONS='${DOCKER_NETWORK_OPTIONS}'
EOF
		## linux bridge
		ip link set lbr0 down || true
		brctl delbr lbr0 || true
		brctl addbr lbr0
		ip addr add ${local_subnet_gateway}/${local_subnet_mask_len} dev lbr0
		ip link set lbr0 up

	    if [ ! -f /.dockerinit ]; then
		# disable iptables for lbr0
		# for kernel version 3.18+, module br_netfilter needs to be loaded upfront
		# for older ones, br_netfilter may not exist, but is covered by bridge (bridge-utils)
		#
		# This operation is assumed to have been performed in advance
		# for docker-in-docker deployments.
		modprobe br_netfilter || true
		sysctl -w net.bridge.bridge-nf-call-iptables=0
	    fi
		# when using --pid=host to run docker container, systemctl inside it refuses
		# to work because it detects that it's running in chroot. using dbus instead
		# of systemctl is just a workaround
		dbus-send --system --print-reply --reply-timeout=2000 --type=method_call --dest=org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.Reload
		dbus-send --system --print-reply --reply-timeout=2000 --type=method_call --dest=org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.RestartUnit string:'docker.service' string:'replace'
	    ;;
    esac
}

function setup_required() {
    ip=$(echo `ip a s lbr0 2>/dev/null|awk '/inet / {print $2}'`)
    if [ "$ip" != "${local_subnet_gateway}/${local_subnet_mask_len}" ]; then
        return 0
    fi
    if [ "$multitenant" = "true" ]; then
	flow_rule='NXM_NX_TUN_IPV4'
    else
	flow_rule='table=0.*arp'
    fi
    if ! ovs-ofctl -O OpenFlow13 dump-flows br0 | grep -q $flow_rule; then
        return 0
    fi
    return 1
}

# Delete the subnet routing entry created because of ip link up on device
# ip link adds local subnet route entry asynchronously
# So check for the new route entry every 100 ms upto timeout of 2 secs and
# delete the route entry.
function delete_local_subnet_route() {
    local device=$1
    local time_interval=0.1  # 100 milli secs
    local max_intervals=20   # timeout: 2 secs
    local num_intervals=0
    local cmd="ip route | grep -q '${local_subnet_cidr} dev ${device}'"

    until $(eval $cmd) || [ $num_intervals -ge $max_intervals ]; do
        sleep $time_interval
        num_intervals=$((num_intervals + 1))
    done

    if [ $num_intervals -ge $max_intervals ]; then
        echo "Error: ${local_subnet_cidr} route not found for dev ${device}" >&2
        return 1
    fi
    ip route del ${local_subnet_cidr} dev ${device} proto kernel scope link
}

function setup() {
    # clear config file
    rm -f /etc/openshift-sdn/config.env

    ## openvswitch
    ovs-vsctl del-br br0 || true
    ovs-vsctl add-br br0 -- set Bridge br0 fail-mode=secure
    ovs-vsctl set bridge br0 protocols=OpenFlow13
    ovs-vsctl del-port br0 vxlan0 || true
    ovs-vsctl add-port br0 vxlan0 -- set Interface vxlan0 type=vxlan options:remote_ip="flow" options:key="flow" ofport_request=1
    ovs-vsctl add-port br0 ${TUN} -- set Interface ${TUN} type=internal ofport_request=2

    ip link del vlinuxbr || true
    ip link add vlinuxbr type veth peer name vovsbr
    ip link set vlinuxbr up
    ip link set vovsbr up
    ip link set vlinuxbr txqueuelen 0
    ip link set vovsbr txqueuelen 0
    brctl addif lbr0 vlinuxbr

    if [ "$multitenant" = "true" ]; then
	ovs-vsctl del-port br0 vovsbr || true
	ovs-vsctl add-port br0 vovsbr -- set Interface vovsbr ofport_request=3

	# Table 0; learn MAC addresses and continue with table 1
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0, actions=learn(table=8, priority=200, hard_timeout=900, NXM_OF_ETH_DST[]=NXM_OF_ETH_SRC[], load:NXM_NX_TUN_IPV4_SRC[]->NXM_NX_TUN_IPV4_DST[], output:NXM_OF_IN_PORT[]), goto_table:1"

	# Table 1; initial dispatch
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, arp, actions=goto_table:8"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, in_port=1, actions=goto_table:2" # vxlan0
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, in_port=2, actions=goto_table:5" # tun0
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, in_port=3, actions=goto_table:5" # vovsbr
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=1, actions=goto_table:3"            # container

	# Table 2; incoming from vxlan
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, arp, actions=goto_table:8"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=200, ip, nw_dst=${local_subnet_gateway}, actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, tun_id=0, actions=goto_table:5"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=2, priority=100, ip, nw_dst=${local_subnet_cidr}, actions=move:NXM_NX_TUN_ID[0..31]->NXM_NX_REG0[], goto_table:6"

	# Table 3; incoming from container; filled in by openshift-sdn-ovs

	# Table 4; services; mostly filled in by controller.go
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=4, priority=200, reg0=0, ip, nw_dst=${service_network_cidr}, actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=4, priority=100, ip, nw_dst=${service_network_cidr}, actions=drop"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=4, priority=0, actions=goto_table:5"

	# Table 5; general routing
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=200, ip, nw_dst=${local_subnet_gateway}, actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=150, ip, nw_dst=${local_subnet_cidr}, actions=goto_table:6"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=100, ip, nw_dst=${cluster_network_cidr}, actions=goto_table:7"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=5, priority=0, ip, actions=output:2"

	# Table 6; to local container; mostly filled in by openshift-sdn-ovs
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=6, priority=200, ip, reg0=0, actions=goto_table:8"

	# Table 7; to remote container; filled in by controller.go

	# Table 8; MAC dispatch / ARP, filled in by Table 0's learn() rule
	# and with per-node vxlan ARP rules by controller.go
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=8, priority=0, arp, actions=flood"
    else
	ovs-vsctl del-port br0 vovsbr || true
	ovs-vsctl add-port br0 vovsbr -- set Interface vovsbr ofport_request=9

	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0,priority=100,arp,nw_dst=${local_subnet_gateway},actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0,priority=100,ip,nw_dst=${local_subnet_gateway},actions=output:2"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0,priority=75,ip,nw_dst=${local_subnet_cidr},actions=output:9"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0,priority=75,arp,nw_dst=${local_subnet_cidr},actions=output:9"
	ovs-ofctl -O OpenFlow13 add-flow br0 "table=0,priority=50,actions=output:2"
    fi

    # setup tun address
    ip addr add ${local_subnet_gateway}/${local_subnet_mask_len} dev ${TUN}
    ip link set ${TUN} up
    ip route add ${cluster_network_cidr} dev ${TUN} proto kernel scope link

    # Cleanup docker0 since docker won't do it
    ip link set docker0 down || true
    brctl delbr docker0 || true

    # enable IP forwarding for ipv4 packets
    sysctl -w net.ipv4.ip_forward=1
    sysctl -w net.ipv4.conf.${TUN}.forwarding=1

    mkdir -p /etc/openshift-sdn
    echo "export OPENSHIFT_CLUSTER_SUBNET=${cluster_network_cidr}" >> "/etc/openshift-sdn/config.env"

    # delete unnecessary routes
    delete_local_subnet_route lbr0 || true
    delete_local_subnet_route ${TUN} || true
}

set +e
if ! docker_network_config check; then
  lockwrap docker_network_config update
fi

if ! setup_required; then
    echo "SDN setup not required."
    exit 140
fi
set -e

lockwrap setup
