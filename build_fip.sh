#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later

arm_mirror="https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-linux-gnueabihf.tar.xz"
toolchain_vendor="arm-gnu-toolchain-14.2.rel1-x86_64-arm-none-linux-gnueabihf"

gpt_mainline_mmc='label: gpt
first-lba: 64
start=64, size=8000, type=8DA63339-0007-60C0-C436-083AC8230908, name="idbloader"
start=16384, size=8192, type=8DA63339-0007-60C0-C436-083AC8230908, name="uboot"'

uboot_repo_url=${uboot_mainline_repo_url:-https://github.com/u-boot/u-boot}
uboot_branch=${uboot_mainline_branch:-master}

tfa_repo_url=${tfa_repo_url:-https://review.trustedfirmware.org/TF-A/trusted-firmware-a.git}
tfa_branch=${tfa_branch:-master}

configs_mainline=(${configs_mainline:-stm32mp15_trusted stm32mp15_basic stm32mp15})

mainline_artifacts=(u-boot-nodtb.bin u-boot.dtb u-boot.stm32 u-boot.img tf-a.stm32)
bootmode="sdcard"
interface="mmcblk0"
DL_DIR="$(pwd)/dl"
SDK_DIR="$(pwd)/sdk"
SRC_DIR="$(pwd)/src"
upstream=0
clean=0
force=0

usage="
Usage:
	$0 [options] <device-tree> [extra-uboot-params]

Examples:
	$0 stm32mp157c-dk2
	$0 stm32mp135f-dk
	$0 stm32mp257f-ev1

Common options:
	-b		bootmode (SDCard or eMMC) [default : $bootmode]
	-c		clean temporary files after the build
	-f		force rebuild
	-h		print this help, then exit successfully
	-i <interface>	use this specific interface (IPv4 or device)
			[default : $interface]
	-o <path>	specify output build directory [default : $(basename "$SRC_DIR")]
	-s <path>	specify SDK path [default : $(basename "$SDK_DIR")]
	-u		upstream mode
	-v		verbose mode
"

if [ "$#" == 0 ]; then
	echo "$usage"
	exit 0
fi

while [ $OPTIND -le "$#" ]
do
	if getopts "b:cfhi:o:s:uv" opt
	then
		# shellcheck disable=SC2034
		case $opt in
		b)
			bootmode="$OPTARG"
			;;
		c)
			clean=1
			;;
		f)
			force=1
			;;
		h)
			echo "$usage"
			exit 0
			;;
		i)
			interface="$OPTARG"
			;;
		o)
			KBUILD_OUTPUT=$(readlink -f "$OPTARG")
			echo "$KBUILD_OUTPUT"
			;;
		s)
			SDK_DIR="$OPTARG"
			;;
		u)
			upstream=1
			;;
		v)
			verbose="--verbose"
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			exit 1
			;;
		esac
	else
		script_args+=("${!OPTIND}")
		((OPTIND++))
	fi
done

# Get device-tree and delete from script_args
devicetree=${script_args[0]:-}
script_args=("${script_args[@]:1}")

if [ "$verbose" = "--verbose" ]; then
	echo "Devicetree = $devicetree"
	echo "upstream = $upstream"
	echo "bootmode = $bootmode"
fi

# Init a repo, we do this in Bash world because we only need minimum config
init_repo() { # 1: git dir, 2: url, 3: branch
	if [[  -z "$1$2" ]]; then
		echo "Dir and URL not set"
		return 1
	fi
	if [[ -z "$3" ]]; then
		local git_head='*'
	else
		local git_head="$3"
	fi
	rm -rf "$1"
	mkdir -p "$1"
	mkdir -p "$1"/{objects,refs}
	echo 'ref: refs/heads/'"${git_head}" > "$1"/HEAD
	printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = true\n[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/%s:refs/heads/%s\n' \
		"$2" "${git_head}" "${git_head}" > "$1"/config
}

# Update a repo, init first if it could not be found
update_repo() { # 1: git dir, 2: url, 3: branch
	if [[ ! -d "$1" ]]; then
		init_repo "$1" "$2" "$3"
	fi
	if [[ ! -d "$1" ]]; then
		echo "Failed to prepare local git dir $1 from $2"
		return 1
	fi
	echo "Updating '$1' <= '$2'"
	git --git-dir "$1" remote update --prune
}

# Update all repos
update_repos() {
	update_repo "$SRC_DIR/u-boot.git" "${uboot_repo_url}" "${uboot_branch}"
	update_repo "$SRC_DIR/tfa.git" "${tfa_repo_url}" "${tfa_branch}"
}

deploy_toolchain() {
	if [[ -d "$SDK_DIR/${toolchain_vendor}" ]]; then
		echo "SDK already exists ${toolchain_vendor}"
		return
	fi

	if [[ ! -f "$DL_DIR/${toolchain_vendor}.tar.xz" ]]; then
		echo "Deploying toolchain ${toolchain_vendor}"
		wget "${arm_mirror}" -P "$DL_DIR"
		wget "${arm_mirror}.sha256asc" -P "$DL_DIR"

		# Check downloaded data and exit early if it fails
		cd $DL_DIR
		if ! sha256sum -c "${toolchain_vendor}.tar.xz.sha256asc"; then
			echo "Corrupted files" >&2
			exit 1
		fi
		cd $DL_DIR/..
	fi

	# Create sdk folder if it does not exists
	if [[ ! -d "$SDK_DIR" ]]; then
		mkdir -p "$SDK_DIR"
	fi

	if ! tar xvf "$DL_DIR/${toolchain_vendor}.tar.xz" -C "$SDK_DIR"; then
		echo "$SDK_DIR"
		echo "Could not extract $DL_DIR/${toolchain_vendor}.tar.xz" >&2
		exit 1
	fi
}

dt_from_defconfig() { #1 defconfig
	case $devicetree in
		*"stm32mp1"*)
			printf "%s" "Hello, world"
			;;
		*"stm32mp2"*)
			printf "%s" "Hello, world"
			;;
		\?)
			echo "Invalid devicetree: $devicetree" >&2
			;;
	esac
}

prepare_tfa() { #1 git branch #2 config #3 device-tree
	local TFA_DIR="$SRC_DIR/tfa"
	local CROSS_COMPILE="arm-none-linux-gnueabihf-"
	local PATH="$SDK_DIR/$toolchain_vendor/bin:$PATH"

	if [[ $force -eq 1 ]]; then
		rm -rf "$TFA_DIR"
		mkdir -p "$TFA_DIR"
		git --git-dir "$SRC_DIR/tfa.git" --work-tree "$TFA_DIR" checkout -f "$1"
	fi

	# Check for valid devicetree
	if [[ ! -f "$TFA_DIR"/fdts/"$3".dts ]]; then
		echo "Devicetree not found: $3" >&2
		exit 1
	fi

	# Override only if KBUILD_OUTPUT does not exist
	if [[ ! -v "$KBUILD_OUTPUT" ]]; then
		KBUILD_OUTPUT="$TFA_DIR/build/$2"
	fi

	echo "KBUILD_OUTPUT: $KBUILD_OUTPUT"
	echo "CROSS_COMPILE: $CROSS_COMPILE"
	echo "PATH: $PATH"

	if [[ $2 == "stm32mp15_trusted" ]]; then
		# Build BL32 SP_min
		# BUILD_DIR=$KBUILD_OUTPUT \ Bug when using BUILD_DIR
		make -C "$TFA_DIR" -j$(nproc) \
			CROSS_COMPILE=$CROSS_COMPILE \
			PATH=$PATH \
			CFLAGS=-mfloat-abi=hard \
			PLAT=stm32mp1 \
			ARCH=aarch32 \
			ARM_ARCH_MAJOR=7 \
			AARCH32_SP=sp_min \
			DTB_FILE_NAME="$3.dtb" \
			bl32 dtbs
		# Build BL2 with its STM32 header for SD-card boot:
		# This BL2 is independent of the BL32 used (SP_min or OP-TEE).
		make -C "$TFA_DIR" -j$(nproc) \
			CROSS_COMPILE=$CROSS_COMPILE \
			PATH=$PATH \
			CFLAGS=-mfloat-abi=hard \
			PLAT=stm32mp1 \
			ARCH=aarch32 \
			ARM_ARCH_MAJOR=7 \
			DTB_FILE_NAME="$3.dtb" \
			STM32MP_SDMMC=1
	elif [[ $2 == "stm32mp15_basic" ]]; then
		echo "Not implemented yet"
		return
	elif [[ $2 == "stm32mp15"  ]]; then
		echo "Not implemented yet"
		return
	else
		echo "Config not supported"
		exit 1
	fi

	# Copy and prepare output files
	cp $TFA_DIR/build/stm32mp1/release/tf-a-$3.stm32 "${out_prefix}"/tf-a-$3.stm32
	cp $TFA_DIR/build/stm32mp1/release/tf-a-$3.bin "${out_prefix}"/tf-a-$3.bin
	cp $TFA_DIR/build/stm32mp1/release/bl32.bin "${out_prefix}"/bl32.bin
}

# U-Boot Output files
#
# In the output directory (selected by KBUILD_OUTPUT), you can found the needed U-Boot files:
#         stm32mp13_defconfig = u-boot-nodtb.bin and u-boot.dtb
#         stm32mp15_defconfig = u-boot-nodtb.bin and u-boot.dtb
#         stm32mp15_trusted_defconfig = u-boot.stm32
#         stm32mp15_basic_defconfig
#             FSBL = spl/u-boot-spl.stm32
#             SSBL = u-boot.img (without CONFIG_SPL_LOAD_FIT) or
#                 u-boot.itb (with CONFIG_SPL_LOAD_FIT=y)
#
# https://docs.u-boot.org/en/latest/board/st/stm32mp1.html
# stm32mp15_defconfig and stm32mp13_defconfig (for TF-A with FIP support)
# stm32mp15_trusted_defconfig (for TF-A without FIP support)
#
# https://docs.u-boot.org/en/latest/board/st/stm32mp1.html#the-basic-boot-chain-with-spl-for-stm32mp15x
# stm32mp15_basic_defconfig (for SPL support)

prepare_uboot() { #1 git branch #2 config #3 device-tree
	local UBOOT_DIR="$SRC_DIR/u-boot"
	local CROSS_COMPILE="arm-none-linux-gnueabihf-"
	local PATH="$SDK_DIR/$toolchain_vendor/bin:$PATH"

	# Skip build if artifacts exist
	local report_name="u-boot (mainline) for $1"
	if [[ "${out_prefix}" ]]; then
		echo "Skipped building ${report_name}"
		return 0
	fi

	if [[ $force -eq 1 ]]; then
		rm -rf "$UBOOT_DIR"
		mkdir -p "$UBOOT_DIR"
		git --git-dir "$SRC_DIR/u-boot.git" --work-tree "$UBOOT_DIR" checkout -f "$1"
	fi

	# STM32MP boards are under OF_UPSTREAM flag.  This means that U-Boot
	# uses Linux upstream device-tree.
	# Check for valid devicetree and config
	if [[ ! -f "$UBOOT_DIR"/dts/upstream/src/arm/st/"$3".dts ]]; then
		echo "Devicetree not found: $3" >&2
		exit 1
	fi
	if [[ ! -f "$UBOOT_DIR/configs/$2_defconfig" ]]; then
		echo "Config file not found: $2" >&2
		exit 1
	fi

	# Override only if KBUILD_OUTPUT does not exist
	if [[ ! -v "$KBUILD_OUTPUT" ]]; then
		KBUILD_OUTPUT="$UBOOT_DIR/build/$2"
	fi

	echo "KBUILD_OUTPUT: $KBUILD_OUTPUT"
	echo "CROSS_COMPILE: $CROSS_COMPILE"
	echo "PATH: $PATH"

	# Prepare U-Boot config
	make -C "$UBOOT_DIR" "$2"_defconfig O="$KBUILD_OUTPUT"

	# Building U-Boot and exit early if make fails
	if ! make -C "$UBOOT_DIR" -j$(nproc) \
		DEVICETREE="$3" \
		O="$KBUILD_OUTPUT" \
		CROSS_COMPILE=$CROSS_COMPILE \
		PATH=$PATH \
		all W=1
	then
		echo "Failed to build U-Boot" >&2
		exit 1
	fi

	# Copy and prepare output files
	cp "$KBUILD_OUTPUT"/u-boot.stm32 "${out_prefix}"/u-boot.stm32
	cp "$KBUILD_OUTPUT"/u-boot-nodtb.bin "${out_prefix}"/u-boot-nodtb.bin
	cp "$KBUILD_OUTPUT"/u-boot.dtb "${out_prefix}"/u-boot.dtb
}

generate_git_version() { #1 git dir, #2 branch
	printf 'g%s' $(git --git-dir "$1" rev-parse --short "$2")
}

# Needs to be executed before all operations to create global var $version
# 
generate_version() {
	local tfa_ver=$(generate_git_version "$SRC_DIR/tfa.git" "${tfa_branch}")
	local uboot_ver=$(generate_git_version "$SRC_DIR/u-boot.git" "${uboot_branch}")
	version="${tfa_ver}-${uboot_ver}"
	echo "**TF-A version (mainline)**: \`${tfa_ver}\`

**U-Boot version (mainline)**: \`${uboot_ver}\`

---

sha256sums
\`\`\`" > release_notes.md
}

build_fip() { #1 config #2 device-tree
	prefix="fip-$1-${version}"
	out_prefix="out/${prefix}"
	local suffix=
	local existing='yes'

	local UBOOT_DIR="$SRC_DIR/u-boot"
	local UBOOT_BUILD_DIR="$UBOOT_DIR/build/$1"
	local TFA_DIR="$SRC_DIR/tfa"
	local CROSS_COMPILE="arm-none-linux-gnueabihf-"
	local PATH="$SDK_DIR/$toolchain_vendor/bin:$PATH"

	# Create outpur dir
	if [[ ! -d "$out_prefix" ]]; then
		mkdir -p "$out_prefix"
	fi

	# Override only if KBUILD_OUTPUT does not exist
	if [[ ! -v "$KBUILD_OUTPUT" ]]; then
		KBUILD_OUTPUT="$TFA_DIR/build/$1"
	fi

	echo "KBUILD_OUTPUT: $KBUILD_OUTPUT"
	echo "CROSS_COMPILE: $CROSS_COMPILE"
	echo "PATH: $PATH"

	# Check for existing artifacts
	for suffix in "${mainline_artifacts[@]}"; do
		local name="${prefix}-${suffix}"
		echo "mainline:$1:${name}.gz" >> out/list
		local out="${out_prefix}-${suffix}".gz
		outs+=("${out}")
		if [[ ! -f "${out}" ]]; then
			existing=''
		fi
	done

	#for suffix in "${mainline_artifacts[@]}"; do
		#prepare_tfa
		#prepare_uboot
	#done

	prepare_uboot "$uboot_branch" stm32mp15_trusted "$devicetree"
	prepare_tfa "$tfa_branch" stm32mp15_trusted "$devicetree"


	if [[ $1 == "stm32mp15_trusted" ]]; then
		make -C "$TFA_DIR" -j$(nproc) \
			O=$KBUILD_OUTPUT \
			CROSS_COMPILE=$CROSS_COMPILE \
			PATH=$PATH \
			PLAT=stm32mp1 \
			ARCH=aarch32 \
			ARM_ARCH_MAJOR=7 \
			AARCH32_SP=sp_min \
			DTB_FILE_NAME="$2.dtb" \
			BL33="$UBOOT_BUILD_DIR"/u-boot-nodtb.bin \
			BL33_CFG="$UBOOT_BUILD_DIR"/u-boot.dtb \
			fip

			cp $TFA_DIR/build/stm32mp1/release/fip.bin "${out_prefix}"/fip.bin
	elif [[ $1 == "stm32mp15"  ]]; then
		echo "Not implemented yet"
		#make -C "$TFA_DIR" -j$(nproc) \
		#	O=$KBUILD_OUTPUT \
		#	CROSS_COMPILE=$CROSS_COMPILE \
		#	PATH=$PATH \
		#make CROSS_COMPILE=arm-none-eabi- PLAT=stm32mp1 ARCH=aarch32 ARM_ARCH_MAJOR=7 \
		#	AARCH32_SP=optee \
		#	DTB_FILE_NAME=stm32mp157c-ev1.dtb \
		#	BL33=<u-boot_directory>/u-boot-nodtb.bin \
		#	BL33_CFG=<u-boot_directory>/u-boot.dtb \
		#	BL32=<optee_directory>/tee-header_v2.bin \
		#	BL32_EXTRA1=<optee_directory>/tee-pager_v2.bin
		#	BL32_EXTRA2=<optee_directory>/tee-pageable_v2.bin
		#	fip
		return
	elif [[ $1 == "stm32mp15_basic" ]]; then
		echo "No need to build Tf-A for basic configuration"
		return
	else
		echo "Config not supported"
		exit 1
	fi

	# Cleanup old artifacts
	echo "Building ${report_name}..."
	for suffix in "${mainline_artifacts[@]}"; do
		rm -f "${out_prefix}-${suffix}".gz
	done

	# Prepare MMC image
	#local out_mmc="${out_prefix}"sd-emmc.img
	#truncate -s 13M "${out_mmc}"
	#sfdisk "${out_mmc}" <<< "${gpt_mainline_mmc}"
	#dd if=build/u-boot-rockchip.bin of="${out_mmc}" seek=64 conv=notrunc

	# Prepare SPI image
	#local out_spi="${out_prefix}"spi.img
	#cp build/u-boot-rockchip-spi.bin "${out_spi}"
	#truncate -s 4M "${out_spi}"
	#sfdisk "${out_spi}" <<< "${gpt_spi}"

	# Compress output files
	#for suffix in "${mainline_artifacts[@]}"; do
	#	gzip -9 --force --suffix '.gz.temp' "${out_prefix}-${suffix}" &
	#	pids_gzip+=($!)
	#done
}

build_all() {
	outs=()
	pids_gzip=()
	rm -rf out/list
	mkdir -p out

	for config in "${configs_mainline[@]}"; do
		build_fip "${config}" 
	done
}

finish() {
	wait ${pids_gzip[@]}
	local out
	for out in "${outs[@]}"; do
		if [[ -e "${out}".temp ]]; then
			mv "${out}"{.temp,}
		fi
	done
	local temp_archive=$(mktemp)
	tar -cf "${temp_archive}" "${outs[@]}" out/list
	rm -rf out
	tar -xf "${temp_archive}"
	rm -f "${temp_archive}"

	cd out
	sha256sum * > sha256sums
	cd ..
	cat out/sha256sums >> release_notes.md
	echo '```' >> release_notes.md
}

set_parts() {
    spart_label='gpt'
    spart_firstlba='34'
    spart_idbloader='start=64, size=960, type=8DA63339-0007-60C0-C436-083AC8230908, name="idbloader"'
    spart_uboot='start=1024, size=6144, type=8DA63339-0007-60C0-C436-083AC8230908, name="uboot"'
    spart_size_all=3072
    spart_off_boot=4
    spart_size_boot=512
    local skt_off_boot=$(( ${spart_off_boot} * 2048 ))
    local skt_size_boot=$(( ${spart_size_boot} * 2048 ))
    spart_boot='start='"${skt_off_boot}"', size='"${skt_size_boot}"', type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="alarmboot"'
    spart_off_root=$(( ${spart_off_boot} + ${spart_size_boot} ))
    spart_size_root=$((  ${spart_size_all} - 1 - ${spart_off_root} ))
    local skt_off_root=$(( ${spart_off_root} * 2048 ))
    local skt_size_root=$(( ${spart_size_root} * 2048 ))
    spart_root='start='"${skt_off_root}"', size='"${skt_size_root}"', type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE, name="alarmroot"'
}


gpt_table_trusted=(34 546 1058 5154)
#gpt_table_trusted_dict( ["fsbl1"]=34 ["fsbl2"]=546 ["ssbl"]=1058 ["rootfs"]=5154 )

create_image_disk() { #1 image name #partitions
	echo "Creating image disk $1"
	# 4G image
	dd if=/dev/zero of="$OUT_DIR"/"$1" bs=1M count=4096 conv=fdatasync status=progress
	local loop_device=$(losetup --find --show "$OUT_DIR"/"$1")
 	sgdisk --clear ${loop_device}
 	sgdisk -p ${loop_device}
 	sgdisk --resize-table=128 -a 1 \
		-n 1:34:545	-c 1:fsbl1 \
		-n 2:546:1057	-c 2:fsbl2 \
		-n 3:1058:5153	-c 3:ssbl \
		-n 4:5154:	-c 4:rootfs \
		-A 4:set:2 \
		-p ${loop_device}
	losetup -d ${loop_device}


	dd if=out/tf-a-stm32mp157c-dk2.stm32 of="$OUT_DIR"/"$1" seek= bs=1M conv=fdatasync
	dd if=out/tf-a-stm32mp157c-dk2.stm32 of="$OUT_DIR"/"$1" seek=$ bs=1M conv=fdatasync

	losetup --find --show --partscan "$OUT_DIR"/"$1"out/disk.img
	dd if=out/tf-a-stm32mp157c-dk2.stm32 of=/dev/loop0p1 bs=1M conv=fdatasync
	dd if=out/tf-a-stm32mp157c-dk2.stm32 of=/dev/loop0p2 bs=1M conv=fdatasync
	dd if=out/u-boot.stm32 of=/dev/loop0p3 bs=1M conv=fdatasync
	mkfs.ext4 /dev/loop0p4
	sgdisk -p ${loop_device}
	sudo mkdir /mnt/rootfs
	udisksctl mount -b /dev/loop0p4
	ls /media/182dc0d6-d5f6-459b-b489-9dfb5d7ccec3
}

update_repos
deploy_toolchain
generate_version
build_fip stm32mp15_trusted "$devicetree"

#build_all
#finish

# TF-A dependencies: https://trustedfirmware-a.readthedocs.io/en/latest/getting_started/prerequisites.html#requirements
# U-Boot dependencies : swig

# Check for environment validity
#case $devicetree in
#	*"stm32mp1"*)
#		if [ "$ARCH" != "arm" ]; then
#			echo "Bad environment. You sould check it" >&2
#			exit 1
#		fi
#		;;
#	*"stm32mp2"*)
#		if [ "$ARCH" != "arm64" ]; then
#			echo "Bad environment. You sould check it" >&2
#			exit 1
#		fi
#		;;
#	\?)
#		echo "Invalid devicetree: $devicetree" >&2
#		exit 1
#		;;
#esac
