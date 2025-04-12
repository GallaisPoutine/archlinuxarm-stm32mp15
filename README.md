ArchlinuxARM for the STM32MP157C-DK2
====================================

[https://github.com/kzyapkov/archlinuxarm-olinuxino]: #

[https://github.com/7Ji/orangepi5-archlinuxarm]: #

[https://archlinuxarm.org/platforms/armv7/broadcom/raspberry-pi-2]: #

Installation
------------

The easiest way to install ArchlinuxARM on STM32MP157C-DK2 is to use the
prebuilt Buildroot boot image and root file system.

Instructions to build the image can be found
[here](https://gitlab.com/buildroot.org/buildroot/-/blob/master/board/stmicroelectronics/stm32mp157c-dk2/readme.txt).

Above steps describes the following:

  * Download Buildroot source code.
  * Build the sdcard.img
  * Flash the SDCard with the image file.

From then, the sdcard will have the following partition layout:
  ```
  Disque /dev/mmcblk0 : 14,84 GiB, 15931539456 octets, 31116288 secteurs
  Unités : secteur de 1 × 512 = 512 octets
  Taille de secteur (logique / physique) : 512 octets / 512 octets
  taille d'E/S (minimale / optimale) : 512 octets / 512 octets
  Type d'étiquette de disque : gpt
  Identifiant de disque : C354E9B0-3DB0-490D-ABDE-042633C12BA7

  Périphérique   Début     Fin Secteurs Taille Type
  /dev/mmcblk0p1    34     442      409 204,5K Système de fichiers Linux
  /dev/mmcblk0p2   443     851      409 204,5K Système de fichiers Linux
  /dev/mmcblk0p3   852    4947     4096     2M Système de fichiers Linux
  /dev/mmcblk0p4  4948 7720959  7716012   3,7G Système de fichiers Linux
  ```
The SD card has to be partitioned with GPT format in order to be recognized by
the [STM32MP1 ROM
code](https://wiki.st.com/stm32mpu/wiki/STM32_MPU_ROM_code_overview).  The
first and second partitions need to be labeled "fsbl" so that the ROM code can
recognise the GPT partition entries.  The
[flashmap](https://wiki.st.com/stm32mpu/wiki/STM32_MPU_Flash_mapping#SD_card_memory_mapping)
needs to have at least 4 partitions, including the rootfs.  Bootfs partition is
optional if the rootfs partition has been flagged `legacy_boot`.

In order to install Archlinux ARM, the rootfs partition needs to be wiped out,
with respect for its flags and labels.

From then, the now empty rootfs partition can be populated with the same
procedure as Raspberry Pi's:

  * Download the generic ARMv7 image.

    [ArchLinuxARM-armv7-latest.tar.gz](http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz)
    [MD5sum](http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz.md5)

  * Mount the root filesystem.

    `udisksctl mount -b /dev/mmcblk0p4`

  * Extract the root filesystem (as root, not via sudo).

    `bsdtar -xpf ArchLinuxARM-rpi-armv7-latest.tar.gz -C /media/rootfs`

Since the generic image does not include the STM32MP157C-DK2 device-tree and
kernel, it must be compiled:

  * Download the linux kernel.

    `git clone git://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git`

  * Download and install latest ARM hf toolchain
  * Build the Linux kernel and its related modules.
    ```
    make multi_v7_defconfig
    make zImage dtbs modules -j$(nproc)
    make modules_install INSTALL_MOD_STRIP=1 INSTALL_MOD_PATH=. -j$(nproc)
    ```
  * Copy the modules, device-tree and kernel image onto the target.
    ```
    sudo cp arch/arm/boot/dts/st/stm32mp157c-dk2.dtb /media/rootfs/boot/dtbs/
    sudo cp arch/arm/boot/zImage /media/rootfs/boot/
    sudo cp -rv lib/modules/$(make kernelrelease) /media/rootfs/lib/modules/
    ```

Now ArchlinuxARM should boot, at least to the bootloader.

Setup
-----

When power on the board, logs should look like this:
  ```
  NOTICE:  CPU: STM32MP157CAC Rev.B
  NOTICE:  Model: STMicroelectronics STM32MP157C-DK2 Discovery Board
  NOTICE:  Board: MB1272 Var2.0 Rev.C-01
  NOTICE:  BL2: v2.10.5(release):lts-v2.10.5
  NOTICE:  BL2: Built : 13:39:07, Apr 11 2025
  NOTICE:  BL2: Booting BL32
  NOTICE:  SP_MIN: v2.10.5(release):lts-v2.10.5
  NOTICE:  SP_MIN: Built : 13:39:07, Apr 11 2025


  U-Boot 2025.04 (Apr 11 2025 - 13:38:54 +0200)

  CPU: STM32MP157CAC Rev.B
  Model: STMicroelectronics STM32MP157C-DK2 Discovery Board
  Board: stm32mp1 in trusted - stm32image mode (st,stm32mp157c-dk2)
  Board: MB1272 Var2.0 Rev.C-01
  DRAM:  512 MiB
  Clocks:
  - MPU : 650 MHz
  - MCU : 208.878 MHz
  - AXI : 266.500 MHz
  - PER : 24 MHz
  - DDR : 533 MHz
  optee optee: OP-TEE api uid mismatch
  Core:  315 devices, 41 uclasses, devicetree: board
  WDT:   Started watchdog@5a002000 with servicing every 1000ms (32s timeout)
  NAND:  0 MiB
  MMC:   STM32 SD/MMC: 0
  Loading Environment from MMC... Invalid ENV offset in MMC, copy=0
  In:    serial
  Out:   serial
  Err:   serial
  optee optee: OP-TEE api uid mismatch
  Previous ADC measurements was not the one expected, retry in 20ms
  ****************************************************
  *        WARNING 500mA power supply detected       *
  *     Current too low, use a 3A power supply!      *
  ****************************************************

  Net:   eth0: ethernet@5800a000

  Hit any key to stop autoboot:  0 
  Boot over mmc0!
  Saving Environment to MMC... Invalid ENV offset in MMC, copy=1
  Failed (1)
  switch to partitions #0, OK
  mmc0 is current device
  Scanning mmc 0:4...
  Cannot persist EFI variables without system partition
  Loading Boot0000 'mmc 0' failed
  EFI boot manager: Cannot load any image
  STM32MP> 
  ```

Since we used the Buildroot trusted bootchain, U-Boot seeks a uImage, but does
not find it.  The U-Boot script fails saying that it cannot load the image.

We need to load it by hand using those commands:
  ```
  mmc rescan
  ext4load mmc 0:4 $kernel_addr_r boot/zImage
  ext4load mmc 0:4 $fdt_addr_r boot/dtbs/stm32mp157c-dk2.dtb
  ext4load mmc 0:4 $ramdisk_addr_r boot/initramfs-linux.img
  setenv bootargs loglevel=8 earlyprintk console=ttySTM0,115200 rw root=UUID=0cdf51d1-512b-4a02-beae-b2d9c214a545
  bootz $kernel_addr_r $ramdisk_addr_r:$filesize $fdt_addr_r
  ```

Finally, U-Boot reads and loads the Linux kernel.  Logs look like this:
  ```
  STM32MP> mmc rescan
  STM32MP> ext4load mmc 0:4 $kernel_addr_r boot/zImage
  11608576 bytes read in 489 ms (22.6 MiB/s)
  STM32MP> ext4load mmc 0:4 $fdt_addr_r boot/dtbs/stm32mp157c-dk2.dtb
  54117 bytes read in 34 ms (1.5 MiB/s)
  STM32MP> ext4load mmc 0:4 $ramdisk_addr_r boot/initramfs-linux.img
  7163492 bytes read in 303 ms (22.5 MiB/s)
  STM32MP> setenv bootargs loglevel=8 earlyprintk console=ttySTM0,115200 rw root=UUID=0cdf51d1-512b-4a02-beae-b2d9c214a545
  STM32MP> bootz $kernel_addr_r $ramdisk_addr_r:$filesize $fdt_addr_r
  Kernel image @ 0xc2000000 [ 0x000000 - 0xb12200 ]
  ## Flattened Device Tree blob at c4000000
     Booting using the fdt blob at 0xc4000000
  Working FDT set to c4000000
     Loading Ramdisk to cf92b000, end cffffe64 ... OK
     Loading Device Tree to cf91a000, end cf92a364 ... OK
  Working FDT set to cf91a000
  optee optee: OP-TEE api uid mismatch

  Starting kernel ...
  ```

Doing all those steps should bring to the userland prompt.  Login as the
default user alarm with the password alarm.  The default root password is root.
Login as root and plug an ethernet cable to the board in order to give it
access to the www.

Initialize the pacman keyring and populate the Arch Linux ARM package signing keys:
  ```
  pacman-key --init
  pacman-key --populate archlinuxarm
  ```

You are now good to go.

### Welcome to Arch Linux ARM!

Tips
----

### Upgrade system without upgrading the kernel

`pacman -Suy --ignore=linux-armv7 --ignore=linux-api-headers`

### Upgrade glibc

On the generic ARMv7 image, the glibc used is old (`GLIBC_2.38` at the time
being).  This cause pretty much every program to crash because the glibc used
is older than the glibc used to compile the package.  Update it in order to
solve this issue.

`pacman -Sy glibc`


### Setup WiFi

https://wiki.st.com/stm32mpu/wiki/WLAN_overview
https://wiki.st.com/stm32mpu/index.php?title=How_to_setup_a_WLAN_connection
https://forum.digikey.com/t/stm32mp157c-dk2-debian-wifi-struggle/5414


The default rootfs misses the firmware needed for the `brcmfmac` driver to
work.

  ```
  # dmesg | grep brcmfmac
  [   25.919894] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
  [   25.932212] brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43430-sdio.st,stm32mp157c-dk2.bin failed with error -2
  [   26.230340] brcmfmac mmc1:0001:1: Direct firmware load for brcm/brcmfmac43430-sdio.txt failed with error -2
  [   27.254298] brcmfmac: brcmf_sdio_htclk: HT Avail timeout (1000000): clkctl 0x50
  ```

Download and copy firmwares to get it working.

  ```
  curl https://raw.githubusercontent.com/STMicroelectronics/meta-st-stm32mp/refs/heads/scarthgap/recipes-kernel/linux-firmware/linux-firmware/brcmfmac43430-sdio.txt > /lib/firmware/brcm/brcmfmac43430-sdio.txt

  wget https://raw.githubusercontent.com/murata-wireless/cyw-fmac-fw/master/brcmfmac43430-sdio.bin
  mv ./brcmfmac43430-sdio.bin /lib/firmware/brcm/

  wget https://raw.githubusercontent.com/murata-wireless/cyw-fmac-fw/master/cyfmac43430-sdio.1DX.clm_blob
  mv cyfmac43430-sdio.1DX.clm_blob /lib/firmware/brcm/brcmfmac43430-sdio.1DX.clm_blob
  ```

Reload the modules.

  ```
  cp /lib/firmware/brcm/brcmfmac43430-sdio.bin /lib/firmware/brcm/brcmfmac43430-sdio.st,stm32mp157c-dk2.bin
  rmmod brcmfmac_wcc
  rmmod brcmfmac
  modprobe brcmfmac
  [ 5949.679592] stm32_rtc 5c004000.rtc: error -EEXIST: failed to register clk 'rtc_lsco' (0xc4519800)
  [ 5949.687131] brcmfmac mmc1:0001:1: Error applying setting, reverse things back
  [ 5949.708751] brcmfmac: brcmf_fw_alloc_request: using brcm/brcmfmac43430-sdio for chip BCM43430/1
  [root@alarm ~]# [ 5949.873349] brcmfmac: brcmf_c_process_txcap_blob: no txcap_blob available (err=-2)
  [ 5949.880451] brcmfmac: brcmf_c_preinit_dcmds: Firmware: BCM43430/1 wl0: Mar 30 2021 01:12:21 version 7.45.98.118 (7d96287 CY) FWID 01-32059766
  ```

Setup wpa_supplicant.

`wpa_supplicant -B -iwlan0 -c /etc/wpa_supplicant.conf`


TODO
----

* Explain manual partition layout with examples
* Build FIP from scratch and `dd` onto `fsbl` partitions
* Build from scratch via script
* Automate with GitHub CI ?
