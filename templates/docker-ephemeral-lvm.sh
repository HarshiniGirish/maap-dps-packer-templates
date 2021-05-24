#!/bin/sh -e
# This script will DESTROY the first ephemeral/EBS volume and remount it for HySDS work dir and move docker to this space.  
# If this volume already has docker configured, it just mounts it
# If none exists, it will just set up on local disk

# update system first

# get user/group
if [[ -d "/home/ops" ]]; then
  user="ops"
  group="ops"
elif [[ -d "/home/ec2-user" ]]; then
  user="ec2-user"
  group="ec2-user"
else
  user="ops"
  group="ops"
fi

sed -i '/cloudconfig/d' /etc/fstab
# get docker daemon start/stop commands
if [[ -e "/bin/systemctl" ]]; then
  reset_docker="systemctl reset-failed docker"
  start_docker="systemctl start docker"
  stop_docker="systemctl stop docker"
else
  reset_docker=""
  start_docker="service docker start"
  stop_docker="service docker stop"
fi

$stop_docker

# get EBS block devices
if [[ $(lsblk -l -n -o NAME | grep xvda) ]]; then
   EBS_BLK_DEVS=`lsblk -l -n -o NAME | grep -v xvda`
   EBS_BLK_DEVS_CNT=${#EBS_BLK_DEVS[@]}
   echo "Number of EBS block devices: $EBS_BLK_DEVS_CNT"
   if [[ $EBS_BLK_DEVS =~ "xvdf" ]]; then DEV1="/dev/xvdf"; else DEV1="/dev/`echo $EBS_BLK_DEVS | head -n1 | awk '{print $1;}'`"; fi
fi

# resolve NVMe devices
if [[ ! -e "$DEV1" ]]; then
  NVME_NODES=( `nvme list | grep '^/dev/' | awk '{print $1}' | sort` )
  NVME_NODES_CNT=${#NVME_NODES[@]}
  if [[ "${NVME_NODES_CNT}" -gt 0 ]]; then
    # get root device and node
    ROOT_DEV=$(df -hv / | grep '^/dev' | awk '{print $1}')
    for nvme_dev in `nvme list | grep -v ${ROOT_DEV} | grep '^/dev/' | awk '{print $1}' | sort`; do
      if [[ $ROOT_DEV = ${nvme_dev}* ]]; then
        ROOT_NODE=$nvme_dev
      fi
    done

    # get instance storage devices
    if [ -z ${ROOT_NODE+x} ]; then
        NVME_EPH_BLK_DEVS=( `nvme list |  grep '^/dev/' | grep -i 'Instance Storage' | awk '{print $1}' | sort` )
    else
        NVME_EPH_BLK_DEVS=( `nvme list | grep -v ${ROOT_NODE} | grep '^/dev/' | grep -i 'Instance Storage' | awk '{print $1}' | sort` )
    fi
    NVME_EPH_BLK_DEVS_CNT=${#NVME_EPH_BLK_DEVS[@]}
    echo "Number of NVMe local storage block devices: $NVME_EPH_BLK_DEVS_CNT"

    # get EBS devices
    if [ -z ${ROOT_NODE+x} ]; then
        NVME_EBS_BLK_DEVS=( `nvme list |  grep '^/dev/' | grep 'Elastic Block Store' | awk '{print $1}' | sort` )
    else
        NVME_EBS_BLK_DEVS=( `nvme list | grep -v ${ROOT_NODE} | grep '^/dev/' | grep 'Elastic Block Store' | awk '{print $1}' | sort` )
    fi
    NVME_EBS_BLK_DEVS_CNT=${#NVME_EBS_BLK_DEVS[@]}
    echo "Number of NVMe EBS block devices: $NVME_EBS_BLK_DEVS_CNT"
  
    # assign devices
    if [ "$NVME_EBS_BLK_DEVS_CNT" -ge 1 ]; then
        DEV1=${NVME_EBS_BLK_DEVS[0]}; 
     elif [ "$NVME_EPH_BLK_DEVS_CNT" -ge 1 ]; then
      DEV1=${NVME_EPH_BLK_DEVS[0]}
    fi
  fi 
fi

# log devices
echo "DATA_DEV: $DEV1"

if [[ ! -e "$DEV1" ]]; then
# no external devices, set up on root partition
   DATA_DIR="/data"
      # clean out /mnt, ${DATA_DIR} and ${DATA_DIR}.orig
      rm -rf ${DATA_DIR}/work/cache ${DATA_DIR}/work/jobs ${DATA_DIR}/work/tasks
      rm -rf ${DATA_DIR}.orig

      # backup ${DATA_DIR}/work and index style
      cp -rp ${DATA_DIR} ${DATA_DIR}.orig || true

      # create work and unpack index style
       mkdir -p ${DATA_DIR}/work || true
       tar xvfj $(eval echo "~${user}/verdi/src/beefed-autoindex-open_in_new_win.tbz2") -C ${DATA_DIR}/work || true

      # set permissions
      chown -R ${user}:${group} ${DATA_DIR} || true

      # create docker dir
      mkdir -p ${DATA_DIR}/var/lib/docker
      rm -rf /var/lib/docker || mv -f /var/lib/docker /var/lib/docker.orig
      ln -sf ${DATA_DIR}/var/lib/docker /var/lib/docker
$start_docker
exit 0
fi

# Setup HySDS work dir (/data) if mounted as /mnt
DATA_DIR="/data"
  # clean out /mnt, ${DATA_DIR} and ${DATA_DIR}.orig
rm -rf /mnt/cache /mnt/jobs /mnt/tasks
rm -rf ${DATA_DIR}/work/cache ${DATA_DIR}/work/jobs ${DATA_DIR}/work/tasks
rm -rf ${DATA_DIR}.orig

# backup ${DATA_DIR}/work and index style
cp -rp ${DATA_DIR} ${DATA_DIR}.orig || true

# unmount block device if not already
umount $DEV1 2>/dev/null || true
mkdir -p $DATA_DIR || true

if [ ! "`blkid $DEV1 | grep xfs`" ]; then mkfs.xfs -f $DEV1; fi

mount $DEV1 $DATA_DIR

if [[ ! -e "${DATA_DIR}/var/lib/docker" ]]; then
    mkdir -p ${DATA_DIR}/var/lib/docker;
else 
    /usr/sbin/xfs_growfs -d ${DATA_DIR}
fi

mkdir -p ${DATA_DIR}/work || true
tar xvfj $(eval echo "~${user}/verdi/src/beefed-autoindex-open_in_new_win.tbz2") -C ${DATA_DIR}/work || true
rm -rf /var/lib/docker || mv -f /var/lib/docker /var/lib/docker.orig
ln -sf ${DATA_DIR}/var/lib/docker /var/lib/docker
chown -R ${user}:${group} ${DATA_DIR}/work || true
$reset_docker || echo "No need to reset, carry on"
$start_docker
