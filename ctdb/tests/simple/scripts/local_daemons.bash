# If we're not running on a real cluster then we need a local copy of
# ctdb (and other stuff) in $PATH and we will use local daemons.

hdir="$CTDB_SCRIPTS_HELPER_BINDIR"
export CTDB_EVENTD="${hdir}/ctdb-eventd"
export CTDB_EVENT_HELPER="${hdir}/ctdb-event"
export CTDB_LOCK_HELPER="${hdir}/ctdb_lock_helper"
export CTDB_RECOVERY_HELPER="${hdir}/ctdb_recovery_helper"
export CTDB_TAKEOVER_HELPER="${hdir}/ctdb_takeover_helper"
export CTDB_CLUSTER_MUTEX_HELPER="${hdir}/ctdb_mutex_fcntl_helper"

if [ -n "$TEST_SOCKET_WRAPPER_SO_PATH" ] ; then
	export LD_PRELOAD="$TEST_SOCKET_WRAPPER_SO_PATH"
	export SOCKET_WRAPPER_DIR="${SIMPLE_TESTS_VAR_DIR}/sw"
	mkdir -p "$SOCKET_WRAPPER_DIR"
fi

# onnode will execute this, which fakes ssh against local daemons
export ONNODE_SSH="${TEST_SUBDIR}/scripts/ssh_local_daemons.sh"

#######################################

# If the given IP is hosted then print 2 items: maskbits and iface
have_ip ()
{
	local addr="$1"
	local bits t

	case "$addr" in
	*:*) bits=128 ;;
	*)   bits=32  ;;
	esac

	t=$(ip addr show to "${addr}/${bits}")
	[ -n "$t" ]
}

setup_nodes ()
{
	local have_all_ips=true
	local i
	for i in $(seq 0 $((TEST_LOCAL_DAEMONS - 1)) ) ; do
		if [ -n "$CTDB_USE_IPV6" ]; then
			local j=$(printf "%04x" $((0x5f00 + 1 + i)) )
			local node_ip="fd00::5357:${j}"
			if have_ip "$node_ip" ; then
				echo "$node_ip"
			else
				cat >&2 <<EOF
ERROR: ${node_ip} not on an interface, please add it
EOF
				have_all_ips=false
			fi
		else
			local c=$(( i / 100 ))
			local d=$(( 1 + (i % 100) ))
			echo "127.0.${c}.${d}"
		fi
	done

	# Fail if we don't have all of the IPv6 addresses assigned
	$have_all_ips
}

setup_public_addresses ()
{
	local pnn_no_ips="$1"

	local i
	for i in $(seq 0 $((TEST_LOCAL_DAEMONS - 1)) ) ; do
		if  [ $i -eq $pnn_no_ips ] ; then
			continue
		fi

		# 2 public addresses on most nodes, just to make
		# things interesting
		if [ -n "$CTDB_USE_IPV6" ]; then
			printf "fc00:10::1:%x/64 lo\n" $((1 + i))
			printf "fc00:10::2:%x/64 lo\n" $((1 + i))
		else
			local c1=$(( 100 + (i / 100) ))
			local c2=$(( 200 + (i / 100) ))
			local d=$(( 1 + (i % 100) ))
			printf "192.168.${c1}.${d}/24 lo\n"
			printf "192.168.${c2}.${d}/24 lo\n"
		fi
	done
}

setup_ctdb ()
{
	local no_public_addresses=false
	local no_event_scripts=false
	local disable_failover=false
	case "$1" in
	--no-public-addresses) no_public_addresses=true ;;
	--no-event-scripts)    no_event_scripts=true    ;;
	--disable-failover)    disable_failover=true    ;;
	esac

	nodes_file="${SIMPLE_TESTS_VAR_DIR}/nodes"
	setup_nodes >"$nodes_file" || return 1

	# If there are (strictly) greater than 2 nodes then we'll
	# randomly choose a node to have no public addresses
	local pnn_no_ips=-1
	if [ $TEST_LOCAL_DAEMONS -gt 2 ] ; then
		pnn_no_ips=$((RANDOM % TEST_LOCAL_DAEMONS))
	fi

	local public_addresses_all="${SIMPLE_TESTS_VAR_DIR}/public_addresses"
	setup_public_addresses $pnn_no_ips >"$public_addresses_all"

	local pnn
	for pnn in $(seq 0 $(($TEST_LOCAL_DAEMONS - 1))) ; do
		setup_ctdb_base "$SIMPLE_TESTS_VAR_DIR" "node.${pnn}" \
				functions notify.sh debug-hung-script.sh

		cp "$nodes_file" "${CTDB_BASE}/nodes"

		local public_addresses="${CTDB_BASE}/public_addresses"

		if  $no_public_addresses || [ $pnn_no_ips -eq $pnn ] ; then
			echo "Node ${pnn} will have no public IPs."
			: >"$public_addresses"
		else
			cp "$public_addresses_all" "$public_addresses"
		fi

		local node_ip=$(sed -n -e "$(($pnn + 1))p" "$nodes_file")

		local db_dir="${CTDB_BASE}/db"
		local d
		for d in "volatile" "persistent" "state" ; do
			mkdir -p "${db_dir}/${d}"
		done

		if $no_event_scripts ; then
			rm -vf "${CTDB_BASE}/events/legacy/"*
		fi

		cat >"${CTDB_BASE}/ctdb.conf" <<EOF
[logging]
	location = file:${CTDB_BASE}/log.ctdb
	log level = INFO

[cluster]
	recovery lock = ${SIMPLE_TESTS_VAR_DIR}/rec.lock
	node address = ${node_ip}

[database]
	volatile database directory = ${db_dir}/volatile
	persistent database directory = ${db_dir}/persistent
	state database directory = ${db_dir}/state

[failover]
	disabled = ${disable_failover}

[event]
	debug script = debug-hung-script.sh
EOF
	done
}

start_ctdb_1 ()
{
	local pnn="$1"

	onnode "$pnn" $VALGRIND ctdbd
}

ctdb_start_all ()
{
	echo "Starting $TEST_LOCAL_DAEMONS ctdb daemons..."

	onnode all $VALGRIND ctdbd
}

stop_ctdb_1 ()
{
	local pnn="$1"

	onnode "$pnn" $CTDB shutdown
}

ctdb_stop_all ()
{
	echo "Stopping $TEST_LOCAL_DAEMONS ctdb daemons..."

	onnode -p all $CTDB shutdown
}

restart_ctdb_1 ()
{
	stop_ctdb_1 "$1"
	start_ctdb_1 "$1"
}

# onnode will use CTDB_BASES to help the ctdb tool connection to each
# daemon
export CTDB_BASES=""
for i in $(seq 0 $(($TEST_LOCAL_DAEMONS - 1))) ; do
	b="${SIMPLE_TESTS_VAR_DIR}/node.${i}"
	CTDB_BASES="${CTDB_BASES}${CTDB_BASES:+ }${b}"
done

# Need a default CTDB_BASE for onnode (to find the functions file).
# Any node will do, so pick the 1st...
export CTDB_BASE="${CTDB_BASES%% *}"
