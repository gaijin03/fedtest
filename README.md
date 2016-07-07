# Fedtest
Provides a dockerized environment for running Slurm federation regression tests.

## Setup
After cloning this repo, just run ./setup.pl. The setup script will:

1. check that docker is installed and is reachable in the path. If it's not installed please consult:
https://docs.docker.com/engine/installation/

   "docker run" also needs to be executable by the the user running setup.pl. Either run setup.pl with sudo or add your user to the docker group.
1. clone, or pull the latest, the federation slurm branch into ./slurm
1. configure slurm.conf and slurmdbd.conf for three clusters -- fed1, fed2 and fed3.
1. compile source for respective clusters.
1. start a separate mysql docker container for the slurmdbd to talk to
1. start slurmdbd on the fed1 cluster.
1. start slurmctld and ten virtual slurmds on each cluster.
1. run respective federation expect tests.

## Interacting With Setup
Once setup.pl has completed successfully, a complete slurm setup with three separate clusters and a dbd will be in place. The regression tests tear down any federation setup, so that is left as an exercise to the user to setup.

Slurm and mysql data are stored persistently in the cloned fedtest directory in the fed{1|2|3} directories and the mysql_p directory.

To interact with the clusters, you can run the following commands:

`docker exec -ti fed1 bash` will put you in a shell on the fed1 cluster.
e.g.
```
brian@lappy:/tmp/fedtest$ docker exec -ti fed1 bash
root@fed1:/slurm/fed1#
```

Each cluster has its PATH configured to find the binaries corresponding to the given cluster. For example, if you are on the fed2 cluster, the binaries in /slurm/fed2/{bin|sbin} will be found.
e.g.
```
brian@lappy:/tmp/fedtest$ docker exec -ti fed2 bash
root@fed2:/slurm/fed2# which sinfo
/slurm/fed2/bin/sinfo
root@fed2:/slurm/fed2# sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite     10   idle fed2_[1-10]
```

From any cluster, you can can contact the other clusters by running the specific binaries for a given cluster.
e.g.
```
root@fed2:/slurm/fed2# /slurm/fed3/bin/sinfo
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
debug*       up   infinite     10   idle fed3_[1-10]
```


Example federation commands:
```
brian@lappy:~/fedtest$ docker exec -ti fed1 bash
root@fed1:/slurm/fed1# sacctmgr show fed
Federation      Flags    Cluster  Index     Weight     FedState FedStateRaw
---------- ---------- ---------- ------ ---------- ------------ -----------

root@fed1:/slurm/fed1# sacctmgr add federation fed clusters=fed1,fed2,fed3
 Adding Federation(s)
  fed
 Settings
  Cluster       = fed1
  Cluster       = fed2
  Cluster       = fed3
Would you like to commit changes? (You have 30 seconds to decide)
(N/y): y

root@fed1:/slurm/fed1# sacctmgr show federation
Federation      Flags    Cluster  Index     Weight     FedState FedStateRaw
---------- ---------- ---------- ------ ---------- ------------ -----------
       fed                  fed1      1          0                        0
       fed                  fed2      2          0                        0
       fed                  fed3      3          0                        0

root@fed1:/slurm/fed1# sacctmgr show clusters format=federation,cluster
Federation    Cluster
---------- ----------
       fed       fed1
       fed       fed2
       fed       fed3

root@fed1:/slurm/fed1# scontrol show fed
Federation: fed
Sibling:    fed1:172.18.0.3:30002 Index:1 FedState: Weight:0 PersistConn:Self
Sibling:    fed2:172.18.0.4:30002 Index:2 FedState: Weight:0 PersistConn:Connected
Sibling:    fed3:172.18.0.5:30002 Index:3 FedState: Weight:0 PersistConn:Connected
```
