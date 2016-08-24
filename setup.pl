#!/usr/bin/perl -w
#######################################################################
# Written by Brian Christiansen <brian@schedmd.com>

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
#######################################################################
use strict;

my $ACCT_PORT       = 30000;
my $BASE_PORT       = 30001;
my $CLUSTER_PREFIX  = "fed";
my $DOCKER_NETWORK  = "federation";

# ubuntu1604 settings:
#my $DOCKER_IMAGE    = "gaijin03/slurm_build_ubuntu1604";
#my $DOCKER_DB_IMAGE = "mysql:5";
#my $MUNGE_START_CMD = "service munge start";

# centos7 settings:
my $DOCKER_IMAGE    = "gaijin03/slurm_build_centos7";
my $DOCKER_DB_IMAGE = "mariadb:5.5";
my $MUNGE_START_CMD = "runuser -u munge /usr/sbin/munged";

my $GIT_BRANCH      = "federation";
my $GIT_REPO        = "https://github.com/SchedMD/slurm.git";
my $DB_HOST         = "dbhost";
my $DB_PASSWD       = "12345";
my $DB_PERSIST      = "db_persist";
my $NUM_CLUSTERS    = 3;
my $REMOTE_PATH     = "/slurm";
my $SLURM_DB_NAME   = "slurm_fed";
my $SLURM_USER      = "root";

my $CWD = `pwd`; # Get full path
chomp($CWD);

#Check that docker is installed
if (system("which docker")) {
	print <<"END";
ERROR: couldn't find docker in the current path.
       Please install docker before continuing:
       https://docs.docker.com/engine/installation/
END
	exit 1;
}

# Verify docker service is running
if (system("ps -C docker") && system("ps -C dockerd")) {
	print <<"END";
ERROR: Doesn't appear that the docker engine is running.
       Please start the docker engine and try again.
END
	exit 1;
}

# Verify that current user can run docker.
if (system("docker run hello-world")) {
	print <<"END";
ERROR: failed to run "docker run hello-world".
       This is most likely a permissions issue. Either add your user to the
       docker group or run this script with elevated privileges.
END
	exit 1;
}

#Make sure containers are gone.
print "Cleaning up any existing docker containers/networks\n";
run_cmd("docker stop $DB_HOST", 1);
run_cmd("docker rm -f $DB_HOST", 1);
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	run_cmd("docker stop $cname", 1);
	run_cmd("docker rm  -f $cname", 1);
}

#create docker network for federation
run_cmd("docker network rm $DOCKER_NETWORK", 1);
run_cmd("docker network create --driver bridge $DOCKER_NETWORK", 0);


# clone federation repo
if (-d "slurm") {
	print "get latest from $GIT_BRANCH branch\n";
	run_cmd("git -C slurm pull", 0);
} else {
	print "cloning $GIT_BRANCH\n";
	run_cmd("git clone -b $GIT_BRANCH $GIT_REPO", 0);
}

# setup environments
print "Creating Slurm Environments\n";
for (1..$NUM_CLUSTERS) {
	setup_env($_);
}
print "Done done setting up Slurm Environments\n";

# pull docker image now so that it doesn't get pulled multiple times before
# the forks happen to build the source.
print "Pulling docker image to run slurm in\n";
run_cmd("docker pull $DOCKER_IMAGE", 0);

# create containers and build slurm into environments
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	print "Configuring source for $cname -- in parallel\n";
	run_cmd_fork("docker run -P " .				#make ports available to localhost
				"-h $cname " .			#hostname
			   	"--name=$cname " .		#container name
			   	"--net=$DOCKER_NETWORK " .	#docker user network
			   	"-v $CWD:/slurm " .		#mount current directory
			   	"-w /slurm/$cname/slurm " .	#working directory
			   	"--rm " .			#remove container after done
			   	"$DOCKER_IMAGE " .		#docker image
			   	"bash -c '/slurm/slurm/configure " .
					"--prefix=/slurm/$cname " .
					"--enable-developer " .
					"--enable-multiple-slurmd >/dev/null'"); #command to run
}
while (my $pid = wait() != -1) {
	my $rc = $? >> 8;
	die "ERROR: forked pid:$pid returned an error (rc:$rc): $!" if ($?);
}

# Can't parallize making of docs because make it makes copies of the man pages
# in the src directory.
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	print "Making docs for $cname -- in serial\n";
	run_cmd("docker run -P " .			#make ports available to localhost
			   "-h $cname " .		#hostname
			   "--name=$cname " .		#container name
			   "--net=$DOCKER_NETWORK " .	#docker user network
			   "-v $CWD:/slurm " .		#mount current directory
			   "-w /slurm/$cname/slurm/doc " . #working directory
			   "--rm " .			#remove container after done
			   "$DOCKER_IMAGE " .		#docker image
			   "bash -c 'make -j install >/dev/null'"); #command to run
}

for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	print "Installing source for $cname -- in parallel\n";
	run_cmd_fork("docker run -P " .				#make ports available to localhost
				"-h $cname " .			#hostname
				"--name=$cname " .		#container name
				"--net=$DOCKER_NETWORK " .	#docker user network
				"-v $CWD:/slurm " .		#mount current directory
				"-w /slurm/$cname/slurm " .	#working directory
				"--rm " .			#remove container after done
				"$DOCKER_IMAGE " .		#docker image
				"bash -c 'make -j install >/dev/null'"); #command to run
}
while (my $pid = wait() != -1) {
	my $rc = $? >> 8;
	die "ERROR: forked pid:$pid returned an error (rc:$rc): $!" if ($?);
}
print "Done building source binaries\n";

# start daemons
print "Start Daemons\n";

#start mysql server
print "Start mysql server\n";
#create persistent mysql storage dir
run_cmd("mkdir -p $DB_PERSIST");
run_cmd("docker run -P " .			#make ports available to localhost
		   "-h $DB_HOST " .		#hostname
		   "--name=$DB_HOST " .		#container name
		   "--net=$DOCKER_NETWORK " .	#docker user network
		   "-e MYSQL_ROOT_PASSWORD=$DB_PASSWD " .	#root passwd
		   "-v $CWD/$DB_PERSIST:/var/lib/mysql " .	#mount mysql persist directory
		   "-d " .			#daemonize
		   $DOCKER_DB_IMAGE);		#docker image

#start 3 instances of ubuntu
print "Start slurm daemons\n";

#grab the current PATH from the container since it can't be set globally with -e
#because it won't take the $PATH of the container -- takes $PATH from the
#localhost.
my $path_cmd = "docker run --rm $DOCKER_IMAGE bash -c 'echo \$PATH'";
my $cont_path = `$path_cmd`;
die "ERROR: running $path_cmd: $!" if ($?);
chomp($cont_path);

for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	my $path_env = "PATH=/slurm/$cname/sbin:/slurm/$cname/bin:$cont_path";
	my $testsuite_env = "SLURM_LOCAL_GLOBALS_FILE=globals.$cname";
	run_cmd("docker run -P " .			#make ports available to localhost
			   "-h $cname " .		#hostname
			   "--name=$cname " .		#container name
			   "--net=$DOCKER_NETWORK " .	#docker user network
			   "-v $CWD:/slurm " .		#mount current directory
			   "-w /slurm/$cname " .	#working directory
			   "-d " .			#detach run in background
			   "-e $path_env " .		#set PATH env variable
			   "-e MANPATH=/slurm/$cname/share/man " . #set MANPATH env variable
			   "-e $testsuite_env " .	#set testsuite env variable
			   "-t " .			#allocate a tty.
			   "--security-opt='seccomp=unconfined' " . #allows gdb to work
			   "$DOCKER_IMAGE " .		#docker image
			   "tail -f /dev/null");	#keep container running

	run_cmd("docker exec $cname $MUNGE_START_CMD");
	run_cmd("docker exec $cname /slurm/$cname/sbin/slurmdbd") if ($_ == 1);
	sleep 5;
	run_cmd_expect_error("docker exec $cname /slurm/$cname/bin/sacctmgr -i add cluster $cname",
			     "This cluster $cname already exists.  Not adding.");
	sleep 5;
	run_cmd("docker exec $cname /slurm/$cname/sbin/slurmctld -c");

	#start nodes
	for (1..10) {
		run_cmd("docker exec $cname /slurm/$cname/sbin/slurmd -N ${cname}_$_");
	}
}

#print sinfo for each cluster
print "Making sure everything is responding:\n";
sleep 3; #Give time for last slurmds to come up.
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	run_cmd("docker exec $cname sinfo");
}

#Now run the relevant federation expect tests
print "Running federation tests.\n";
my $cname = get_cluster_name(1);
run_cmd("docker exec $cname bash -c 'cd /slurm/slurm/testsuite/expect && ./test37.1'");
run_cmd("docker exec $cname bash -c 'cd /slurm/slurm/testsuite/expect && ./test37.2'");
run_cmd("docker exec $cname bash -c 'cd /slurm/slurm/testsuite/expect && ./test37.3'");

print "\nAll tests passed!\n\n";

print <<"END";
You can now interact with the setup.
See the README for information and examples on how to interact with the setup.

END

exit 0;


###############################################################################
# Sub routines
###############################################################################

sub run_cmd_fork
{
	my $cmd    = shift;
	my $ignore = shift;

	my $pid = fork();
	die "failed to fork/exec $cmd: $!" if ($pid == -1);

	if (!$pid) {
		run_cmd($cmd, $ignore);
		exit 0;
	};
}

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
	chdir $CWD or die "Couldn't chdir to $CWD $!";

	print "Setting up $cname\n";

	run_cmd("mkdir -p $cname", 0);
	run_cmd("mkdir -p $cname/state", 0);
	run_cmd("mkdir -p $cname/spool", 0);
	run_cmd("mkdir -p $cname/run",   0);
	run_cmd("mkdir -p $cname/log",   0);
	run_cmd("mkdir -p $cname/slurm", 0);
	run_cmd("mkdir -p $cname/etc",   0);

	# slurm.conf
	open FILE, ">$cname/etc/slurm.conf" or die "Couldn't create slurm.conf: $!";
	print FILE make_slurm_conf($cname, $BASE_PORT);
	close FILE;

	# slurmdbd.conf
	open FILE, ">$cname/etc/slurmdbd.conf" or die "Couldn't create slurmdbd.conf: $!";
	print FILE make_slurmdbd_conf($cname);
	close FILE;

	# globals.local
	open FILE, ">$CWD/slurm/testsuite/expect/globals.$cname" or die "Couldn't create globals.$cname $!";
	print FILE <<"END";
set my_slurm_base "$REMOTE_PATH"
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

sub make_slurm_conf
{
	my $cname    = shift;
	my $loc_port = shift;

	my $sched_port = $loc_port++;
	my $ctld_port  = $loc_port++;
	my $host_ports = $loc_port . "-" . ($loc_port+9);

	my $dbd_host = get_cluster_name(1);

	my $conf =<<"END";
ClusterName=$cname
ControlMachine=$cname
AuthType=auth/munge
CacheGroups=0
CryptoType=crypto/munge
MpiDefault=none
ProctrackType=proctrack/pgid
SlurmctldPidFile=$REMOTE_PATH/$cname/run/slurmctld.pid
SlurmctldPort=$ctld_port
SlurmdPidFile=$REMOTE_PATH/$cname/run/slurmd-%n.pid
SlurmdSpoolDir=$REMOTE_PATH/$cname/spool/slurmd-%n
SlurmUser=$SLURM_USER
SlurmdUser=$SLURM_USER
StateSaveLocation=$REMOTE_PATH/$cname/state
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
SchedulerPort=$sched_port
SelectType=select/cons_res
SelectTypeParameters=CR_CORE_Memory
PriorityType=priority/multifactor
AccountingStorageEnforce=associations,limits,qos,safe
AccountingStorageHost=$dbd_host
AccountingStoragePort=$ACCT_PORT
AccountingStorageType=accounting_storage/slurmdbd
AccountingStoreJobComment=YES

JobAcctGatherType=jobacct_gather/linux

SlurmctldDebug=info
SlurmctldLogFile=$REMOTE_PATH/$cname/log/slurmctld.log
SlurmdDebug=debug
SlurmdLogFile=$REMOTE_PATH/$cname/log/slurmd-%n.log
DebugFlags=protocol,federation
LogTimeFormat=thread_id

NodeName=DEFAULT CPUs=8 Sockets=1 CoresPerSocket=4 ThreadsPerCore=2 State=UNKNOWN RealMemory=7830
NodeName=${cname}_[1-10] NodeAddr=$cname Port=$host_ports

PartitionName=debug Nodes=${cname}_[1-10] Default=YES MaxTime=INFINITE State=UP
END

	return $conf
}

sub make_slurmdbd_conf
{
	my $cname = shift;

	my $conf =<<"END";
AuthType=auth/munge
DbdHost=$cname
DbdPort=$ACCT_PORT

DebugFlags=FEDERATION
DebugLevel=info
LogFile=$REMOTE_PATH/$cname/log/slurmdbd.log
PidFile=$REMOTE_PATH/$cname/run/slurmdbd.pid

SlurmUser=$SLURM_USER
StorageUser=$SLURM_USER
StoragePass=$DB_PASSWD

StorageType=accounting_storage/mysql
StorageLoc=$SLURM_DB_NAME
StorageHost=$DB_HOST
END

	return $conf;
}
