#!/usr/bin/perl -w

###############################################################################
# Written by Brian Christiansen <brian@schedmd.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
###############################################################################
# Sets up multiple slurm clusters on the same box using different ports.
#
# Builds/expects the following heirarchy:
# ${prefix}/slurm -- source
# ${prefix}/fed1  -- cluster config files and binaries
# ${prefix}/fed2  -- cluster config files and binaries
# ${prefix}/fed3  -- cluster config files and binaries
###############################################################################

use strict;
use Getopt::Long;

my $ACCT_PORT = 30000;
my $BASE_PORT = 30001;
my $CLUSTER_PREFIX  = "fed";

my $DB_USER   = "";
my $DB_PASSWD = "";

my $GIT_BRANCH = "federation";
my $GIT_REPO   = "https://github.com/SchedMD/slurm.git";

my $NUM_CLUSTERS  = 3;
my $SLURM_DB_NAME = "slurm_fed";
my $user = `whoami`;
chomp($user);

my $opt_prefix = "$ENV{HOME}/slurm/federation/";
my $opt_help;

my $full_prefix; # Expanded full path of prefix.

my $usage =<<"END";
USAGE: --prefix=<prefix> where to setup federation configuration [$opt_prefix]
       --help            print this message
END

GetOptions("prefix=s" => \$opt_prefix,
	   "help"     => \$opt_help)
	or die($usage);
if (defined $opt_help) {
	print $usage;
	exit 1;
}

print "Creating prefix: $opt_prefix\n";
die "Failed to create $opt_prefix: $!" if system("mkdir -p $opt_prefix");
chdir $opt_prefix or die "Couldn't chdir to $opt_prefix: $!";
$full_prefix = `pwd`; # Get full path
chomp($full_prefix);

print "\n";
while (!-d "$full_prefix/slurm") {
	print "I don't see a $full_prefix/slurm directory containing the slurm src.\n";
	print "Should I get the slurm source from github? [y|n]";
	my $answer = <STDIN>;
	if ($answer =~ m/[yY]/) {
		die "Couldn't get src: $!" if system("git clone -b $GIT_BRANCH $GIT_REPO");
	} else {
		print "Ok, put the src in $full_prefix/slurm\n";
		print "Hit enter when done.\n";
		$answer = <STDIN>;
	}
}
print "\n\n";

print "Start Env Setup\n";
for (1..$NUM_CLUSTERS) {
	my $pid;
	my $cname = get_cluster_name($_);
	unless ($pid = fork()) {
		print "$cname: setting up env\n";
		setup_env($_);
		print "$cname: running configure\n";
		configure_src($_);
		print "$cname: env and configure done\n";
		exit 0;
	}
}
while (my $pid = wait() != -1) {
	my $rc = $? >> 8;
	die "ERROR: forked pid:$pid returned an error (rc:$rc): $!" if ($?);
}

print "Install html seprately\n";
for (1..$NUM_CLUSTERS) {
	chdir($full_prefix);
	my $cname = get_cluster_name($_);
	print "$cname: installing html\n";
	install_html($_);
	print "$cname: done installing html\n";
}

print "Install rest of binaries in parallel\n";
for (1..$NUM_CLUSTERS) {
	my $pid;
	my $cname = get_cluster_name($_);
	unless ($pid = fork()) {
		print "$cname: building and installing binaries\n";
		install_src($_);
		print "$cname: done installing binaries\n";
		exit 0;
	}
	print "Done Setting up " . get_cluster_name($_) . "\n";
}
while (my $pid = wait() != -1) {
	my $rc = $? >> 8;
	die "ERROR: forked pid:$pid returned an error (rc:$rc): $!" if ($?);
}
print "Env Setup Done\n\n";

print "Starting Daemons\n";
for (1..$NUM_CLUSTERS) {
	start_dbd($_) if ($_ == 1);
	my $cname = get_cluster_name($_);

	print "$cname: adding cluster to dbd\n";
	run_cmd_expect_error("$full_prefix/$cname/bin/sacctmgr -i add cluster $cname",
			     "This cluster $cname already exists.  Not adding.");

	if ($_ == $NUM_CLUSTERS) {
		run_cmd_expect_error("$full_prefix/$cname/bin/sacctmgr -i add account tacct", "Nothing new added.");
		run_cmd_expect_error("$full_prefix/$cname/bin/sacctmgr -i add user $user account=tacct", "Nothing new added");
		run_cmd("$full_prefix/$cname/bin/sacctmgr -i mod user $user set admin=admin");
	}
}
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	print "$cname: starting ctld\n";
	start_ctld($_);
	print "$cname: starting slurmds\n";
	start_slurmds($_);
	print "$cname: done starting daemons\n";
}
print "Done starting all daemons\n\n";

my $test_cname = get_cluster_name(1);
print "Running regression tests\n";
my $test_dir = "$full_prefix/slurm/testsuite/expect";
$ENV{SLURM_LOCAL_GLOBALS_FILE} = "$test_dir/globals.$test_cname";
chdir $test_dir or die "Couldn't chdir to $test_dir: $!";
run_cmd("./test37.1 && " .
	"./test37.2 && " .
	"./test37.3 && " .
	"./test37.4 && " .
	"./test37.5 && " .
	"./test37.6 && " .
	"./test37.7 && " .
	"./test37.8 && " .
	"./test37.9 && " .
	"./test37.10 && " .
	"./test37.11 && " .
	"./test37.12 && " .
	"./test37.13 && " .
	"./test37.14");

print "All tests ran sucessfully.\n\n";

exit 0;



################
# Routines
################

sub run_cmd
{
	my $cmd    = shift;
	my $ignore = shift;
	print "cmd: $cmd\n";
	my $rc = system($cmd);
	die "ERROR: running $cmd: $!" if (!$ignore && $rc);
}

sub run_cmd_expect_error
{
	my $cmd            = shift;
	my $expected_error = shift;
	print "cmd: $cmd\n";
	my $output = `$cmd`;
	if (($? >> 8) && !($output =~ m/$expected_error/)) {
		die "ERROR: running $cmd: $!";
	}
}

sub setup_env
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	chdir $full_prefix or die "Couldn't chdir to $full_prefix $!";

	print "Setting up $cname\n";

	my $loc_port = $BASE_PORT + (1000 * $index);
	run_cmd("mkdir -p $cname/state");
	run_cmd("mkdir -p $cname/spool");
	run_cmd("mkdir -p $cname/run");
	run_cmd("mkdir -p $cname/log");
	run_cmd("mkdir -p $cname/slurm");
	run_cmd("mkdir -p $cname/etc");

	# slurm.conf
	open FILE, ">$cname/etc/slurm.conf" or die "Couldn't create slurm.conf: $!";
	print FILE make_slurm_conf($cname, $loc_port);
	close FILE;

	# slurmdbd.conf
	open FILE, ">$cname/etc/slurmdbd.conf" or die "Couldn't create slurmdbd.conf: $!";
	print FILE make_slurmdbd_conf($cname);
	close FILE;

	# globals.local
	open FILE, ">$full_prefix/slurm/testsuite/expect/globals.$cname" or die "Couldn't create globals.$cname $!";
	print FILE <<"END";
set my_slurm_base "$opt_prefix"
set src_dir "\$my_slurm_base/slurm"
set slurm_dir "\$my_slurm_base/$cname"
set build_dir "\$slurm_dir/slurm"
set partition "debug"

set fed_slurm_base "\$my_slurm_base"
set fedc1 "fed1"
set fedc2 "fed2"
set fedc3 "fed3"
END

	close FILE;
}

sub get_cluster_name
{
	my $index = shift;
	return "$CLUSTER_PREFIX$index";
}

sub get_src_loc
{
	return "$full_prefix/slurm";
}

sub configure_src
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	my $src_loc = get_src_loc();
	chdir "$full_prefix/$cname/slurm" or die "Couldn't chdir to $full_prefix/$cname/slurm: $!";
	print run_cmd("$src_loc/configure --prefix=$full_prefix/$cname \\
					  --enable-multiple-slurmd \\
					  --enable-developer \\
					  >/dev/null");
}

sub install_src
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	chdir "$full_prefix/$cname/slurm" or die "Couldn't chdir to $full_prefix/$cname/slurm: $!";
	print run_cmd("make -j install >/dev/null")
}

sub install_html
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	chdir "$full_prefix/$cname/slurm/doc" or die "Couldn't chdir to $full_prefix/$cname/slurm: $!";
	print run_cmd("make -j install >/dev/null");
	chdir $full_prefix;
}

sub start_dbd
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	print run_cmd("$full_prefix/$cname/sbin/slurmdbd");

	sleep 2;
	my $pid_file = "$full_prefix/$cname/run/slurmdbd.pid";
	die "$pid_file doesn't exist: $!" unless (-f $pid_file);

	my $dbd_pid = `cat $pid_file`;
	chomp $dbd_pid;
	die "dbd pid pid not found" unless (kill 0, $dbd_pid);

	#verify it's up
	my $dbd_resp = 0;
	for (1..3) {
		sleep 2;
		my $output = `$full_prefix/$cname/bin/sacctmgr show config`;
		if ($output =~ m/^Configuration data as/) {
			$dbd_resp = 1;
			last;
		}
		print "ERROR: dbd not responding. Will wait a sec and if it comes up\n"
	}
	die "ERROR: dbd not responding." if (!$dbd_resp);

	print "$full_prefix/$cname/sbin/slurmdbd started\n";
}

sub start_ctld
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	print run_cmd("$full_prefix/$cname/sbin/slurmctld");

	sleep 2;
	my $pid_file = "$full_prefix/$cname/run/slurmctld.pid";
	die "$pid_file doesn't exist: $!" unless (-f $pid_file);

	my $ctld_pid = `cat $pid_file`;
	chomp $ctld_pid;

	print "$full_prefix/$cname/sbin/slurmctld started\n";
}

sub start_slurmds
{
	my $index = shift;
	my $cname = get_cluster_name($index);
	for (1..10) {
		my $node = "${cname}_$_";
		my $cmd = "$full_prefix/$cname/sbin/slurmd -N $node";
		print run_cmd($cmd);

		sleep 2;
		my $pid_file = "$full_prefix/$cname/run/slurmd-$node.pid";
		die "$pid_file doesn't exist: $!" unless (-f $pid_file);

		my $node_pid = `cat $pid_file`;
		chomp $node_pid;
		die "$node pid not found" unless (kill 0, $node_pid);

		print "$full_prefix/$cname/sbin/slurmd ($node) started\n";
	}
}

sub make_slurm_conf
{
	my $cname    = shift;
	my $loc_port = shift;

	my $ctld_port  = $loc_port++;
	my $host_ports = $loc_port . "-" . ($loc_port+9);

	my $conf =<<"END";
ClusterName=$cname
ControlMachine=localhost
AuthType=auth/munge
AuthInfo=cred_expire=30 #quicker requeue time
CacheGroups=0
CryptoType=crypto/munge
MpiDefault=none
ProctrackType=proctrack/pgid
SlurmctldPidFile=$full_prefix/$cname/run/slurmctld.pid
SlurmctldPort=$ctld_port
SlurmdPidFile=$full_prefix/$cname/run/slurmd-%n.pid
SlurmdSpoolDir=$full_prefix/$cname/spool/slurmd-%n
SlurmUser=$user
SlurmdUser=$user
StateSaveLocation=$full_prefix/$cname/state
SwitchType=switch/none
TaskPlugin=affinity
InactiveLimit=0
KillWait=30
MessageTimeout=60
MinJobAge=300
SlurmctldTimeout=120
SlurmdTimeout=30
Waittime=0
DefMemPerCPU=100
FastSchedule=2
SchedulerType=sched/backfill
SelectType=select/cons_res
SelectTypeParameters=CR_CORE_Memory
PriorityType=priority/multifactor
AccountingStorageEnforce=associations,limits,qos,safe
AccountingStorageHost=localhost
AccountingStoragePort=$ACCT_PORT
AccountingStorageType=accounting_storage/slurmdbd
AccountingStoreJobComment=YES

JobAcctGatherType=jobacct_gather/linux

SlurmctldDebug=info
SlurmctldLogFile=$full_prefix/$cname/log/slurmctld.log
SlurmdDebug=debug
SlurmdLogFile=$full_prefix/$cname/log/slurmd-%n.log
DebugFlags=protocol,federation
LogTimeFormat=thread_id

NodeName=DEFAULT CPUs=8 Sockets=1 CoresPerSocket=4 ThreadsPerCore=2 State=UNKNOWN RealMemory=7830
NodeName=${cname}_[1-10] NodeAddr=localhost Port=$host_ports

PartitionName=debug Nodes=${cname}_[1-10] Default=YES MaxTime=INFINITE State=UP

RequeueExit=5
RequeueExitHold=6

FederationParameters=fed_display
END

	return $conf
}

sub make_slurmdbd_conf
{
	my $cname = shift;

	my $conf =<<"END";
AuthType=auth/munge
DbdHost=localhost
DbdPort=$ACCT_PORT

DebugFlags=FEDERATION
DebugLevel=info
LogFile=$full_prefix/$cname/log/slurmdbd.log
PidFile=$full_prefix/$cname/run/slurmdbd.pid

SlurmUser=$user

StorageType=accounting_storage/mysql
StorageLoc=$SLURM_DB_NAME
StorageHost=localhost
END

	if ($DB_USER ne "") {
		$conf .= "StorageUser=$DB_USER\n";
	}
	if ($DB_PASSWD ne "") {
		$conf .= "StoragePass=$DB_PASSWD\n";
	}

	return $conf;
}
