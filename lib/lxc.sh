export DEBIAN_FRONTEND=noninteractive
DIR=$(pwd)
DATA_DIR=$DIR/cowsql-benchmark

# List of Debian packages to install.
PACKAGES="\
        e2fsprogs \
        libraft-tools \
        parted \
        xfsprogs \
"

# Bencher API token, used to send benchmark results to https://bencher.dev
BENCHER_RAFT_TOKEN=$(curl http://lab.linuxcontainers.org/config/cowsql-bencher-raft.token)

# Bencher Debian packages are published on GitHub
BENCHER_RELEASES_URL=https://api.github.com/repos/bencherdev/bencher/releases/latest

# List of **unused** devices that will be repartitioned and used as storage
DEVICES="/dev/nvme0n1 /dev/sdd"

# Run the benchmarks against these file systems. The "raw" file system means
# using directly the block device.
FILESYSTEMS="ext4 xfs raw"

# Run raft disk benchmarks with these buffer sizes.
RAFT_DISK_BUFSIZES="4096,8192,65536,262144"

cleanup() {
    set +e

    sudo umount "${DATA_DIR}" > /dev/null 2>&1 || true
    rm -rf "${DATA_DIR}"

    if [ "${FAIL}" = "1" ]; then
        echo ""
        echo "Benchmark failed"
        exit 1
    fi

    exit 0
}

# Create an empty partition table on the given device, then add a new partition
# with the given file system, and finally mount it under "${DATA_DIR}".
setup_data_dir() {
    device=$1
    filesystem=$2
    storage="${DATA_DIR}"
    sudo parted "${device}" --script mklabel gpt
    sudo parted -a optimal "${device}" --script mkpart primary ext4 2048 15GB
    sudo partprobe

    if case "${device}" in  /dev/nvme*) true;; *) false;; esac; then
        partition=${device}p1
    else
        partition=${device}1
    fi

    echo "create $filesystem file system on $partition"

    case $filesystem in
        ext4)
	    sudo mkfs.ext4 -F "${partition}"
	    sudo mount "${partition}" "${DATA_DIR}"
            ;;
        btrfs)
	    sudo mkfs.btrfs -f "${partition}"
	    sudo mount "${partition}" "${DATA_DIR}"
            ;;
        xfs)
	    sudo mkfs.xfs -f "${partition}"
	    sudo mount "${partition}" "${DATA_DIR}"
            ;;
        zfs)
            sudo zpool destroy -f cowsql > /dev/null 2>&1 || true
	    sudo zpool create -f cowsql "${partition}"
	    sudo zfs create -o mountpoint="${DATA_DIR}" cowsql/zfs
            ;;
        raw)
            storage="${device}"
            ;;
        *)
            echo "error: unknown filesystem $filesystem"
            exit 1
            ;;
    esac

    sudo chown "${USER}" "${storage}"
}

tear_down_data_dir() {
    filesystem=$1

    if [ "${filesystem}" = "raw" ]; then
        return
    fi

    echo "umount $filesystem file system from ${DATA_DIR}"
    sudo umount "${DATA_DIR}"

    case $filesystem in
        zfs)
            sudo zpool destroy -f cowsql
            ;;
        *)
            ;;
    esac
}

run_benchmarks() {
    device=$1
    filesystem=$2
    testbed=lxc-$(hostname)-$(basename "${device}")-$filesystem
    storage="${DATA_DIR}"

    if [ "${filesystem}" = "raw" ]; then
        storage="${device}"
    fi

    echo "run raft-benchmark disk on $testbed"
    export BENCHER_API_TOKEN="${BENCHER_RAFT_TOKEN}"

    bencher run --project raft --testbed "${testbed}" \
      "raft-benchmark disk -d ${storage} -b $RAFT_DISK_BUFSIZES"

    if [ "${filesystem}" != "raw" ]; then
        bencher run --project raft --testbed "${testbed}" \
          "raft-benchmark submit -d $storage"
    fi
}

FAIL=1
trap cleanup EXIT HUP INT TERM

# Make sure we're up to date
while :; do
    sudo add-apt-repository ppa:cowsql/main -y && break
    sudo apt-get update && break
    sleep 10
done

while :; do
    sudo apt-get dist-upgrade --yes && break
    sleep 10
done

# Setup dependencies
# shellcheck disable=SC2086
sudo apt-get install -y ${PACKAGES}

curl -s $BENCHER_RELEASES_URL | \
    grep "browser_download_url.*_$(dpkg --print-architecture).deb" | \
    cut -d : -f 2,3 | tr -d \" | wget -qi - -O /tmp/bencher.deb

sudo dpkg -i /tmp/bencher.deb

# Run the benchmarks
mkdir -p "${DATA_DIR}"
for device in ${DEVICES}; do
    for filesystem in ${FILESYSTEMS}; do
        setup_data_dir "${device}" "${filesystem}"
        run_benchmarks "${device}" "${filesystem}"
        tear_down_data_dir "${filesystem}"
    done
done

FAIL=0