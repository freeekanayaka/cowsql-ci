setup_nvme() {
    device=$1
    disk=$(echo "${device}" | sed -e 's|p1$||')

    if [ -e "${device}" ]; then
        return
    fi

    lbaf=$(get nvme lbaf)
    if [ -n "${lbaf}" ]; then
        sudo nvme format --force --lbaf="${lbaf}" "${disk}"
    fi

    sudo parted "${disk}" --script mklabel gpt
    sudo parted -a optimal "${disk}" --script mkpart primary ext4 2048 15GB
    sudo partprobe
}

setup_null_blk() {
    device=$1
    if ! [ -e "${device}" ]; then
        sudo modprobe null_blk bs=4096 memory_backed=1 gb=1
    fi
}

setup_device() {
    device=$1
    case $device in
        /dev/nvme*)
            setup_nvme "${device}"
            ;;
        /dev/nullb*)
            setup_null_blk "${device}"
            ;;
        *)
            echo "unknown driver type for $device"
            exit 1
            ;;
    esac
}

setup_filesystem() {
    device=$1
    filesystem=$2
    mountpoint=$3

    case $filesystem in
        ext4)
	    sudo mkfs.ext4 -F "${device}"
            sudo tune2fs -O ^has_journal "${device}"
	    sudo mount "${device}" "${mountpoint}"
            ;;
        btrfs)
	    sudo mkfs.btrfs -f "${device}"
	    sudo mount "${device}" "${mountpoint}"
            ;;
        xfs)
	    sudo mkfs.xfs -f "${device}"
	    sudo mount "${device}" "${mountpoint}"
            ;;
        zfs)
            sudo zpool destroy -f cowsql > /dev/null 2>&1 || true
	    sudo zpool create -f cowsql "${device}"
	    sudo zfs create -o mountpoint="${mountpoint}" cowsql/zfs
            ;;
        *)
            echo "error: unknown filesystem $filesystem"
            exit 1
            ;;
    esac
}