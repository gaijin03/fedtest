# Fedtest
Provides a dockerized environment for running Slurm federation regression tests.

## Usage
Usage: ./setup.pl [--branch=<name>] [--runtests]

## Setup
After cloning this repo, just run ./setup.pl. The setup script will:

1. check that docker is installed and is reachable in the path. If it's not installed please consult:
https://docs.docker.com/engine/installation/

   "docker run" also needs to be executable by the the user running setup.pl.
   Either run setup.pl with sudo or add your user to the docker group.
1. clone, or pull the latest, the slurm 'master' branch into ./env/slurm (use
   --branch to clone a different branch).
1. configure slurm.conf and slurmdbd.conf for three clusters -- c1, c2 and c3.
1. compile source.
1. start a separate MySQL docker container for the slurmdbd to talk to
1. start a controller and slurmd containers for each cluster.
1. start slurmdbd on the first cluster.
1. run respective federation expect tests.

## Interacting With Setup
Once setup.pl has completed successfully, a complete slurm setup with three separate clusters and a dbd will be in place. The regression tests tear down any federation setup, so that is left as an exercise to the user to setup.

Slurm and MySQL data are stored persistently in the cloned fedtest directory in the c{1|2|3} directories and the db_persist directory. The env directory is mounted at /fedtest on each of the containers and the db_persist directory is mounted at /var/lib/mysql on the dbhost.

To interact with the clusters, you can run the following commands:

`docker exec -ti c1_controller bash` will put you in a shell on the c1 cluster.

e.g.
```
brian@lappy:/tmp/fedtest$ docker exec -ti fed1 bash
[root@c1_controller fedtest]#
```

Each cluster has its PATH configured to find the Slurm binaries. The federation
expect tests expect to be able to contact the other clusters for the cluster
they are being run on. In order to do this a wrapper script is linked to for
each cluster that exports the SLURM_CONF variable to point to the corresponding
cluster's slurm.conf.

e.g.
```
[root@c1_controller fedtest]# echo $PATH
/fedtest/current/sbin:/fedtest/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[root@c1_controller fedtest]# which sinfo
/fedtest/current/bin/sinfo

[root@c1_controller fedtest]# /fedtest/c1/bin/sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite     10   idle c1_[1-10]

[root@c1_controller fedtest]# /fedtest/c2/bin/sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite     10   idle c2_[1-10]

[root@c1_controller fedtest]# /fedtest/c3/bin/sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite     10   idle c3_[1-10]
```


Example federation commands:
```
brian@lappy:~/fedtest$ docker exec -ti c1_controller bash
[root@c1_controller fedtest]# sacctmgr show fed
Federation      Flags    Cluster  Index     Weight     FedState FedStateRaw
---------- ---------- ---------- ------ ---------- ------------ -----------

[root@fed1 fedtest]# sacctmgr add federation fed clusters=c1,c2,c3
 Adding Federation(s)
  fed
 Settings
  Cluster       = c1
  Cluster       = c2
  Cluster       = c3
Would you like to commit changes? (You have 30 seconds to decide)
(N/y): y

[root@c1_controller fedtest]# sacctmgr show federation
Federation      Flags    Cluster ID     Weight     FedState
---------- ---------- ---------- -- ---------- ------------
       fed                    c1  1          0       ACTIVE
       fed                    c2  2          0       ACTIVE
       fed                    c3  3          0       ACTIVE

[root@c1_controller fedtest]# sacctmgr show clusters format=federation,cluster
Federation    Cluster
---------- ----------
       fed         c1
       fed         c2
       fed         c3

[root@c1_controller fedtest]# scontrol show fed
Federation: fed
Self:       c1:172.18.0.3:30002 ID:1 FedState:ACTIVE Weight:0
Sibling:    c2:172.18.0.4:30002 ID:2 FedState:ACTIVE Weight:0 PersistConn:Connected
Sibling:    c3:172.18.0.5:30002 ID:3 FedState:ACTIVE Weight:0 PersistConn:Connected
```

You can connect to the database by either getting a shell on the dbhost container or
connecting to the dbhost from one of the cluster containers.

e.g.
```
brian@lappy:~/fedtest$ docker exec -ti dbhost bash
root@dbhost:/# mysql -p12345 slurm_fed
Reading table information for completion of table and column names
You can turn off this feature to get a quicker startup with -A

Welcome to the MariaDB monitor.  Commands end with ; or \g.
Your MariaDB connection id is 190
Server version: 5.5.50-MariaDB-1~wheezy mariadb.org binary distribution

Copyright (c) 2000, 2016, Oracle, MariaDB Corporation Ab and others.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

MariaDB [slurm_fed]>

```
or
```
brian@lappy:~/fedtest$ docker exec -ti c1_controller bash
[root@c1_controller fedtest1]# mysql -h dbhost -p12345 slurm_fed
Reading table information for completion of table and column names
You can turn off this feature to get a quicker startup with -A

Welcome to the MariaDB monitor.  Commands end with ; or \g.
Your MariaDB connection id is 192
Server version: 5.5.50-MariaDB-1~wheezy mariadb.org binary distribution

Copyright (c) 2000, 2015, Oracle, MariaDB Corporation Ab and others.

Type 'help;' or '\h' for help. Type '\c' to clear the current input statement.

MariaDB [slurm_fed]>

```

You can run the expect regression tests by connecting to a cluster container and
then navigating to the test directory and running individual test files.

e.g.
```
brian@lappy:~/fedtest$ docker exec -ti c1_controller bash
[root@c1_controller1 fedtest]# cd /fedtest/slurm/testsuite/expect/
[root@c1_controller1 expect]# ./regression.py --include=test22.1,test37.*
```
