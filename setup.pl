#!/usr/bin/perl -w
#######################################################################
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
#######################################################################
use strict;
use Getopt::Long;
use File::Basename;

my $CLUSTER_PREFIX  = "c";
my $DOCKER_NETWORK  = "federation";

# ubuntu1604 settings:
#my $DOCKER_IMAGE    = "gaijin03/slurm_build_ubuntu1604";
#my $DOCKER_DB_IMAGE = "mysql:5";
#my $MUNGE_START_CMD = "service munge start";

# centos7 settings:
my $DOCKER_IMAGE    = "gaijin03/slurm_build_centos7";
my $DOCKER_DB_IMAGE = "mariadb:5.5";
my $MUNGE_START_CMD = "runuser -u munge /usr/sbin/munged";

my $GIT_BRANCH      = "master";
my $GIT_REPO        = "https://github.com/SchedMD/slurm.git";
my $DB_HOST         = "dbhost";
my $DB_PASSWD       = "12345";
my $DB_PERSIST      = "db_persist";
my $NUM_CLUSTERS    = 3;
my $NUM_NODES       = 10;
my $REMOTE_PATH     = "/fedtest";
my $SLURM_DB_NAME   = "slurm_fed";
my $SLURM_USER      = "slurm";
my $SLURM_UID       = 992;
my $RUN_TESTS       = 0;
my $help            = 0;
my $usage           = "Usage: $0 [--branch=<name>] [--runtests]\n";

GetOptions("branch=s"  => \$GIT_BRANCH,
	   "runtests"  => \$RUN_TESTS,
	   "help"      => \$help)
or die($usage);

die $usage if $help;

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
my @conts = "$DB_HOST";
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	push @conts, "${cname}_controller";

	for (1..$NUM_NODES) {
		push @conts, "${cname}_$_";
	}
}
my $all_conts = join ' ', @conts;
run_cmd("docker stop $all_conts", 1);
run_cmd("docker rm -f $all_conts", 1);

#create docker network for federation
run_cmd("docker network rm $DOCKER_NETWORK", 1);
run_cmd("docker network create --driver bridge $DOCKER_NETWORK", 0);


# setup environments
print "Creating Slurm Environments\n";
`mkdir -p env`;
$CWD .= "/env";
chdir $CWD or die "Couldn't chdir to $CWD: $!";

# clone federation repo
if (-d "slurm") {
	print "get latest from $GIT_BRANCH branch\n";
	run_cmd("git -C slurm pull", 0);
} else {
	print "cloning $GIT_BRANCH\n";
	run_cmd("git clone -b $GIT_BRANCH $GIT_REPO", 0);
}

for (1..$NUM_CLUSTERS) {
	setup_env($_);
}

print "Done done setting up Slurm Environments\n";

# pull docker image now so that it doesn't get pulled multiple times before
# the forks happen to build the source.
print "Pulling docker image to run slurm in\n";
run_cmd("docker pull $DOCKER_IMAGE", 0);

# create containers and build slurm into environments
print "Configuring source\n";
`mkdir -p slurm/build`;
run_cmd("docker run -P " .			#make ports available to localhost
		"--net=$DOCKER_NETWORK " .	#docker user network
		"-v $CWD:$REMOTE_PATH " .	#mount current directory
		"-w $REMOTE_PATH/slurm/build " . #working directory
		"--rm " .			#remove container after done
		"$DOCKER_IMAGE " .		#docker image
		"bash -c '$REMOTE_PATH/slurm/configure " .
			 "--prefix=$REMOTE_PATH/current " .
			 "--sysconfdir=/etc/slurm " .
			 "--enable-developer " .
			 "--disable-optimizations" .
			 ">/dev/null " .
			 "&& make -j install > /dev/null'");

# Setup environment to run federation tests.
open FILE, ">$CWD/cmd_wrap.sh" or die "Couldn't open cmd_wrap.sh: $!";
my $script = sprintf <<'END', $REMOTE_PATH;
#!/bin/sh

dir=`realpath -s $0`
cluster=`dirname $dir`
cluster=`dirname $cluster`
cluster=`basename $cluster`
export SLURM_CONF=%s/$cluster/etc/slurm.conf

cmd=`basename $0`
$cmd "$@"
END
print FILE $script;
close FILE;
run_cmd("chmod +x $CWD/cmd_wrap.sh", 0);

run_cmd("mkdir -p $CWD/testbin", 0);
my $tmp_cname = get_cluster_name(1);
foreach my $file_path (<$CWD/current/bin/*>) {
	my $file = basename($file_path);
	run_cmd("ln -s -f $REMOTE_PATH/cmd_wrap.sh testbin/$file", 0);
}
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	run_cmd("ln -s -f $REMOTE_PATH/testbin $cname/bin", 0);
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
		   "-e MYSQL_USER=$SLURM_USER " .		#user
		   "-e MYSQL_PASSWORD=$DB_PASSWD " .		#passwd
		   "-e MYSQL_DATABASE=$SLURM_DB_NAME " .	#db name
		   "-v $CWD/$DB_PERSIST:/var/lib/mysql " .	#mount mysql persist directory
		   "-d " .			#daemonize
		   $DOCKER_DB_IMAGE);		#docker image

print "Start slurm daemons\n";


# Get current users ids and to create the user in the container
my $id = `id`;
$id =~ m/uid=(\d+)\((\S+)\) gid=(\d+)\((\S+)\)/ or die "Couldn't match uid/gid: $!";
my $uid   = $1;
my $user  = $2;
my $gid   = $3;
my $group = $4;

#grab the current PATH from the container since it can't be set globally with -e
#because it won't take the $PATH of the container -- takes $PATH from the
#localhost.
my $path_cmd = "docker run --rm $DOCKER_IMAGE bash -c 'echo \$PATH'";
my $cont_path = `$path_cmd`;
die "ERROR: running $path_cmd: $!" if ($?);
chomp($cont_path);


# Create default bash profile with Slurm PATHS.
open FILE, ">slurm_profile.sh" or die "Couldn't open slurm_profile.sh: $!";
print FILE <<"EOF";
S_PATH=$REMOTE_PATH/current
PATH=\$PATH:\$S_PATH/bin:\$S_PATH/sbin
SLURM_LOCAL_GLOBALS_FILE=globals.fedtest
MANPATH=$REMOTE_PATH/current/share/man
EOF
close FILE;

for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	my $path_env = "PATH=$REMOTE_PATH/current/sbin:$REMOTE_PATH/current/bin:$cont_path";
	my $man_path_env = "MANPATH=$REMOTE_PATH/current/share/man";
	my $testsuite_env = "SLURM_LOCAL_GLOBALS_FILE=globals.fedtest";

	my $docker_cmd_fmt = "docker run -P " .			#make ports available to localhost
				   "-h %s " .			#hostname
				   "--name=%s " .		#container name
				   "--net=$DOCKER_NETWORK " .	#docker user network
				   "-v $CWD:$REMOTE_PATH " .	#mount current directory
				   "-v $ENV{'HOME'}:/home/$user " . #mount /home
				   "-w $REMOTE_PATH " .		#working directory
				   "-d " .			#detach run in background
				   "-e $path_env " .		#set PATH env variable
				   "-e $man_path_env " . 	#set MANPATH env variable
				   "-e $testsuite_env " .	#set testsuite env variable
				   "-t " .			#allocate a tty.
				   "--security-opt='seccomp=unconfined' " . #allows gdb to work
				   "$DOCKER_IMAGE " .		#docker image
				   "tail -f /dev/null";		#keep container running

	#start compute nodes
	for (1..$NUM_NODES) {
		my $cont_name = "${cname}_$_";
		my $docker_cmd = sprintf $docker_cmd_fmt, $cont_name, $cont_name;
		run_cmd($docker_cmd);
		run_cmd("docker exec $cont_name $MUNGE_START_CMD");
		run_cmd("docker exec $cont_name ln -s $REMOTE_PATH/$cname/etc /etc/slurm");
		run_cmd("docker exec $cont_name ln -s $REMOTE_PATH/slurm_profile.sh /etc/profile.d/slurm.sh");
		run_cmd("docker exec $cont_name groupadd -g $SLURM_UID slurm");
		run_cmd("docker exec $cont_name useradd -m -d /home/slurm -u $SLURM_UID -g slurm -s /bin/bash slurm");
		run_cmd("docker exec $cont_name chown -R $SLURM_USER: $REMOTE_PATH/$cname", 0);
		run_cmd("docker exec $cont_name groupadd -g $gid $group");
		run_cmd("docker exec $cont_name useradd -M -u $uid -g $group $user");
		run_cmd("docker exec $cont_name slurmd");

	}

	my $cont_name = "${cname}_controller";
	my $docker_cmd = sprintf $docker_cmd_fmt, $cont_name, $cont_name;
	run_cmd($docker_cmd);

	run_cmd("docker exec $cont_name $MUNGE_START_CMD");
	run_cmd("docker exec $cont_name ln -s $REMOTE_PATH/$cname/etc /etc/slurm");
	run_cmd("docker exec $cont_name ln -s $REMOTE_PATH/slurm_profile.sh /etc/profile.d/slurm.sh");
	run_cmd("docker exec $cont_name groupadd -g $SLURM_UID slurm");
	run_cmd("docker exec $cont_name useradd -m -d /home/slurm -u $SLURM_UID -g slurm -s /bin/bash slurm");
	run_cmd("docker exec $cont_name chown -R $SLURM_USER: $REMOTE_PATH/$cname", 0);
	run_cmd("docker exec $cont_name groupadd -g $gid $group");
	run_cmd("docker exec $cont_name useradd -M -u $uid -g $group $user");

	if ($_ == 1) {
		run_cmd("docker exec -u$SLURM_USER $cont_name slurmdbd");
		sleep 5;
	}
	run_cmd_expect_error("docker exec $cont_name sacctmgr -i add cluster $cname",
			     "This cluster $cname already exists.  Not adding.");
	run_cmd_expect_error("docker exec $cont_name sacctmgr -i add account acct", 1);
	run_cmd_expect_error("docker exec $cont_name sacctmgr -i add user $user account=acct admin=admin", 1);
	sleep 5;
	run_cmd("docker exec -u$SLURM_USER $cont_name slurmctld -c");
}

#print sinfo for each cluster
print "Making sure everything is responding:\n";
sleep 3; #Give time for last slurmds to come up.
for (1..$NUM_CLUSTERS) {
	my $cname = get_cluster_name($_);
	run_cmd("docker exec ${cname}_controller sinfo");
}

#Now run the relevant federation expect tests
my $exit_code = 0;
my $cname = get_cluster_name(1);
my $test_cmd = "docker exec -u$user ${cname}_controller bash -l -c 'cd $REMOTE_PATH/slurm/testsuite/expect && ./regression.py -k --include=test22.1,test37.*'";
if ($RUN_TESTS) {
	print "Running federation tests.\n";
	$exit_code = run_cmd($test_cmd, 1);

	print "\nDone running tests!\n";
	print "But some tests failed\n" if $exit_code;
	print "\n\n";
} else {
	print "Run the expect tests using:\n$test_cmd\n";
}

print <<"END";
You can now interact with the setup.
See the README for information and examples on how to interact with the setup.

END

exit $exit_code;


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
	return $rc >> 8;
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
	run_cmd("mkdir -p $cname/etc",   0);

	# slurm.conf
	open FILE, ">$cname/etc/slurm.conf" or die "Couldn't create slurm.conf: $!";
	print FILE make_slurm_conf($cname);
	close FILE;

	# slurmdbd.conf
	open FILE, ">$cname/etc/slurmdbd.conf" or die "Couldn't create slurmdbd.conf: $!";
	print FILE make_slurmdbd_conf($cname);
	close FILE;
	run_cmd("chmod 600 $cname/etc/slurmdbd.conf", 0);

	if ($index == 1) {
		# globals.local
		open FILE, ">$CWD/slurm/testsuite/expect/globals.fedtest" or die "Couldn't create globals.fedtest $!";
		print FILE <<"END";
set my_slurm_base "$REMOTE_PATH"
set src_dir "\$my_slurm_base/slurm"
set slurm_dir "\$my_slurm_base/current"
set build_dir "\$src_dir/build"
set partition "debug"

set fed_slurm_base "\$my_slurm_base"
set fedc1 ${CLUSTER_PREFIX}1
set fedc2 ${CLUSTER_PREFIX}2
set fedc3 ${CLUSTER_PREFIX}3
END

		close FILE;
	}
}

sub get_cluster_name
{
	my $index = shift;
	return "$CLUSTER_PREFIX$index";
}

sub make_slurm_conf
{
	my $cname    = shift;
	my $dbd_host = get_cluster_name(1) . "_controller";

	my $conf =<<"END";
ClusterName=$cname
ControlMachine=${cname}_controller
AuthType=auth/munge
AuthInfo=cred_expire=30 #quicker requeue time
CryptoType=crypto/munge
MpiDefault=none
#ProctrackType=proctrack/pgid
ProctrackType=proctrack/linuxproc
SlurmctldPidFile=$REMOTE_PATH/$cname/run/slurmctld.pid
#SlurmctldPort=
SlurmdPidFile=$REMOTE_PATH/$cname/run/slurmd-%n.pid
SlurmdSpoolDir=$REMOTE_PATH/$cname/spool/slurmd-%n
SlurmUser=$SLURM_USER
SlurmdUser=root
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
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CORE_Memory
PriorityType=priority/multifactor
AccountingStorageEnforce=associations,limits,qos,safe
AccountingStorageHost=$dbd_host
#AccountingStoragePort=
AccountingStorageType=accounting_storage/slurmdbd
AccountingStoreFlags=job_comment
SlurmdParameters=config_overrides

JobAcctGatherType=jobacct_gather/linux

SlurmctldDebug=info
SlurmctldLogFile=$REMOTE_PATH/$cname/log/slurmctld.log
SlurmdDebug=debug
SlurmdLogFile=$REMOTE_PATH/$cname/log/slurmd-%n.log
DebugFlags=federation
LogTimeFormat=thread_id

NodeName=DEFAULT CPUs=8 Sockets=1 CoresPerSocket=4 ThreadsPerCore=2 State=UNKNOWN RealMemory=7830
NodeName=${cname}_[1-$NUM_NODES]

PartitionName=debug Nodes=${cname}_[1-$NUM_NODES] Default=YES MaxTime=INFINITE State=UP

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
DbdHost=${cname}_controller
#DbdPort=

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

TrackWCKey=yes
END

	return $conf;
}
